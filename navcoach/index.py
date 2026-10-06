"""Hybrid retrieval index: SQLite FTS5 (BM25 keywords) + dense vectors.

Kept separate from ingestion and from the AI layer so either side can be
replaced (e.g. by ChromaDB/pgvector) without touching the rest.
"""
from __future__ import annotations

import json
import math
import threading
from dataclasses import dataclass, field

import numpy as np

from . import db
from .config import Settings, get_settings
from .embeddings import get_embedder, normalise_for_embedding
from .textutil import concept_coverage, query_concepts, search_text, tokens


# Bump when tokenisation/stemming changes so existing indexes are flagged for a rebuild.
TEXT_VERSION = "2"


@dataclass
class Hit:
    chunk_id: str
    doc_id: str
    text: str
    page: int | None
    printed_page: str | None
    location: str | None
    section: str | None
    quality: str
    flags: list[str]
    filename: str
    title: str | None
    authors: str | None
    year: int | None
    doc_type: str | None
    bm25_rank: int | None = None
    vector_rank: int | None = None
    vector_sim: float = 0.0
    coverage: float = 0.0
    score: float = 0.0
    matched_concepts: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return dict(self.__dict__)


class VectorCache:
    """In-memory matrix of all vectors; rebuilt lazily after any change."""

    def __init__(self):
        self._lock = threading.Lock()
        self._dirty = True
        self.ids: list[str] = []
        self.doc_ids: list[str] = []
        self.matrix = np.zeros((0, 1), dtype=np.float32)

    def invalidate(self):
        with self._lock:
            self._dirty = True

    def load(self, conn):
        with self._lock:
            if not self._dirty:
                return
            rows = conn.execute("SELECT chunk_id, doc_id, dim, vec FROM vectors").fetchall()
            if rows:
                dim = rows[0]["dim"]
                rows = [r for r in rows if r["dim"] == dim]
                self.matrix = np.vstack([np.frombuffer(r["vec"], dtype=np.float32) for r in rows])
            else:
                self.matrix = np.zeros((0, 1), dtype=np.float32)
            self.ids = [r["chunk_id"] for r in rows]
            self.doc_ids = [r["doc_id"] for r in rows]
            self._dirty = False


vector_cache = VectorCache()


def add_chunks(conn, doc_id: str, chunks: list, settings: Settings | None = None) -> int:
    settings = settings or get_settings()
    emb = get_embedder(settings)
    ids = []
    for ch in chunks:
        cid = f"{doc_id}-{ch.ordinal:05d}"
        ids.append(cid)
        conn.execute(
            "INSERT INTO chunks(id,doc_id,ordinal,page,printed_page,location,section,text,quality,flags) "
            "VALUES(?,?,?,?,?,?,?,?,?,?)",
            (cid, doc_id, ch.ordinal, ch.page, ch.printed_page, ch.location, ch.section, ch.text, ch.quality,
             json.dumps(ch.flags)),
        )
        conn.execute("INSERT INTO chunks_fts(chunk_id, body) VALUES(?,?)",
                     (cid, search_text((ch.section or "") + "\n" + ch.text)))
    if chunks:
        vecs = emb.embed([normalise_for_embedding((c.section or "") + "\n" + c.text) for c in chunks])
        for cid, v in zip(ids, vecs):
            conn.execute("INSERT INTO vectors(chunk_id,doc_id,dim,vec) VALUES(?,?,?,?)",
                         (cid, doc_id, int(v.shape[0]), v.astype(np.float32).tobytes()))
    db.set_meta(conn, "embedder", emb.name)
    db.set_meta(conn, "text_version", TEXT_VERSION)
    vector_cache.invalidate()
    return len(chunks)


def delete_doc(conn, doc_id: str) -> None:
    ids = [r["id"] for r in conn.execute("SELECT id FROM chunks WHERE doc_id=?", (doc_id,))]
    for i in range(0, len(ids), 500):
        part = ids[i:i + 500]
        q = ",".join("?" * len(part))
        conn.execute(f"DELETE FROM chunks_fts WHERE chunk_id IN ({q})", part)
    conn.execute("DELETE FROM vectors WHERE doc_id=?", (doc_id,))
    conn.execute("DELETE FROM chunks WHERE doc_id=?", (doc_id,))
    vector_cache.invalidate()


def clear_all(conn) -> None:
    conn.execute("DELETE FROM chunks_fts")
    conn.execute("DELETE FROM vectors")
    conn.execute("DELETE FROM chunks")
    vector_cache.invalidate()


def index_status(conn, settings: Settings | None = None) -> dict:
    settings = settings or get_settings()
    stored = db.get_meta(conn, "embedder")
    try:
        current = get_embedder(settings).name
    except Exception as exc:  # provider not reachable / not installed
        current = f"unavailable ({type(exc).__name__})"
    n = conn.execute("SELECT COUNT(*) c FROM chunks").fetchone()["c"]
    text_ok = db.get_meta(conn, "text_version") == TEXT_VERSION
    return {"chunks": n, "embedder_indexed": stored, "embedder_configured": current, "text_version_ok": text_ok,
            "needs_rebuild": bool(n) and ((stored is not None and stored != current) or not text_ok)}


def _fts_query(concepts: list[set[str]]) -> str | None:
    terms = sorted({t for g in concepts for t in g if t})
    if not terms:
        return None
    return " OR ".join('"' + t.replace('"', "") + '"' for t in terms)


def search(question: str, k: int | None = None, doc_ids: list[str] | None = None,
           collection_id: str | None = None, settings: Settings | None = None) -> tuple[list[Hit], dict]:
    """Hybrid search. Returns (ranked hits, diagnostics)."""
    settings = settings or get_settings()
    k = k or settings.top_k
    concepts = query_concepts(question)
    diag: dict = {"concepts": [sorted(g) for g in concepts]}
    with db.session() as conn:
        allowed = allowed_docs(conn, doc_ids, collection_id)
        if not allowed:
            return [], {**diag, "reason": "no_documents"}

        weights = concept_weights(conn, concepts)
        diag["concept_weights"] = [round(w, 3) for w in weights]
        bm25: dict[str, int] = {}
        fq = _fts_query(concepts)
        if fq:
            rows = conn.execute(
                "SELECT chunk_id, bm25(chunks_fts) AS s FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY s LIMIT 200",
                (fq,)).fetchall()
            rank = 0
            for r in rows:
                if r["chunk_id"].rsplit("-", 1)[0] in allowed:
                    bm25[r["chunk_id"]] = rank
                    rank += 1

        vec_rank: dict[str, int] = {}
        vec_sim: dict[str, float] = {}
        emb = None
        try:
            emb = get_embedder(settings)
            vector_cache.load(conn)
            if vector_cache.ids:
                q = emb.embed([normalise_for_embedding(question)])[0]
                if q.shape[0] == vector_cache.matrix.shape[1]:
                    sims = vector_cache.matrix @ q
                    order = np.argsort(-sims)
                    rank = 0
                    for idx in order[:400]:
                        if vector_cache.doc_ids[idx] in allowed:
                            cid = vector_cache.ids[idx]
                            vec_rank[cid] = rank
                            vec_sim[cid] = float(sims[idx])
                            rank += 1
                            if rank >= 100:
                                break
                else:
                    diag["warning"] = "embedding dimension mismatch — rebuild the index"
        except Exception as exc:
            diag["warning"] = f"vector search unavailable ({type(exc).__name__}); keyword search only"

        cand = set(list(bm25)[:60]) | set(list(vec_rank)[:60])
        if not cand:
            return [], {**diag, "reason": "no_match"}
        q = ",".join("?" * len(cand))
        rows = conn.execute(
            f"SELECT c.*, d.filename, d.title, d.authors, d.year, d.doc_type FROM chunks c "
            f"JOIN documents d ON d.id=c.doc_id WHERE c.id IN ({q})", list(cand)).fetchall()
    hits = []
    for r in rows:
        toks = set(tokens((r["section"] or "") + " " + r["text"]))
        cov = concept_coverage(concepts, toks, weights)
        matched = [sorted(g)[0] for g in concepts if g & toks]
        rrf = 0.0
        if r["id"] in bm25:
            rrf += 1 / (60 + bm25[r["id"]])
        if r["id"] in vec_rank:
            rrf += 1 / (60 + vec_rank[r["id"]])
        h = Hit(chunk_id=r["id"], doc_id=r["doc_id"], text=r["text"], page=r["page"], printed_page=r["printed_page"],
                location=r["location"], section=r["section"], quality=r["quality"],
                flags=json.loads(r["flags"] or "[]"), filename=r["filename"], title=r["title"], authors=r["authors"],
                year=r["year"], doc_type=r["doc_type"], bm25_rank=bm25.get(r["id"]), vector_rank=vec_rank.get(r["id"]),
                vector_sim=vec_sim.get(r["id"], 0.0), coverage=cov, matched_concepts=matched)
        # Normalised fusion score: RRF (max 2/60) blended with concept coverage.
        h.score = 0.5 * (rrf / (2 / 60)) + 0.5 * cov
        hits.append(h)
    hits.sort(key=lambda h: h.score, reverse=True)
    diag["semantic_embedder"] = bool(emb and emb.semantic)
    return hits[: max(k * 3, k)], diag


def allowed_docs(conn, doc_ids: list[str] | None = None, collection_id: str | None = None) -> set[str]:
    """Documents in scope: optional explicit ids ∩ optional collection ∩ processed documents."""
    allowed: set[str] | None = set(doc_ids) if doc_ids else None
    if collection_id:
        ids = {r["doc_id"] for r in conn.execute(
            "SELECT doc_id FROM document_collections WHERE collection_id=?", (collection_id,))}
        allowed = ids if allowed is None else allowed & ids
    # Only processed documents are searchable.
    live = {r["id"] for r in conn.execute(
        "SELECT id FROM documents WHERE status IN ('processed','needs_review')")}
    return live if allowed is None else allowed & live


def full_scan(concepts: list[set[str]], weights: list[float] | None, doc_ids: list[str] | None = None,
              collection_id: str | None = None) -> tuple[list[Hit], dict]:
    """Read EVERY passage of every in-scope file (not only the top-ranked candidates) and
    score each one by weighted concept coverage. Uses the stemmed text already stored in
    the keyword index, so a whole library is scanned in well under a second.

    Returns (hits with coverage > 0, scan statistics)."""
    stats = {"files": 0, "passages": 0, "pages": 0, "unreadable_pages": 0, "filenames": []}
    if not concepts:
        return [], stats
    with db.session() as conn:
        allowed = allowed_docs(conn, doc_ids, collection_id)
        if not allowed:
            return [], stats
        q = ",".join("?" * len(allowed))
        docs = conn.execute(f"SELECT id, filename, page_count, pages_failed FROM documents WHERE id IN ({q})",
                            list(allowed)).fetchall()
        stats["files"] = len(docs)
        stats["filenames"] = sorted(d["filename"] for d in docs)
        stats["unreadable_pages"] = sum(d["pages_failed"] or 0 for d in docs)
        matched: dict[str, tuple[float, list[str]]] = {}
        pages: set[tuple[str, int]] = set()
        for r in conn.execute(f"SELECT f.chunk_id, f.body, c.doc_id, c.page FROM chunks_fts f "
                              f"JOIN chunks c ON c.id=f.chunk_id WHERE c.doc_id IN ({q})", list(allowed)):
            stats["passages"] += 1
            pages.add((r["doc_id"], r["page"] or 0))
            toks = set((r["body"] or "").split())
            cov = concept_coverage(concepts, toks, weights)
            if cov > 0:
                matched[r["chunk_id"]] = (cov, [sorted(g)[0] for g in concepts if g & toks])
        stats["pages"] = len(pages)
        hits: list[Hit] = []
        ids = list(matched)
        for i in range(0, len(ids), 500):
            part = ids[i:i + 500]
            rows = conn.execute(
                f"SELECT c.*, d.filename, d.title, d.authors, d.year, d.doc_type FROM chunks c "
                f"JOIN documents d ON d.id=c.doc_id WHERE c.id IN ({','.join('?' * len(part))})", part).fetchall()
            for r in rows:
                cov, m = matched[r["id"]]
                hits.append(Hit(chunk_id=r["id"], doc_id=r["doc_id"], text=r["text"], page=r["page"],
                                printed_page=r["printed_page"], location=r["location"], section=r["section"],
                                quality=r["quality"], flags=json.loads(r["flags"] or "[]"), filename=r["filename"],
                                title=r["title"], authors=r["authors"], year=r["year"], doc_type=r["doc_type"],
                                coverage=cov, score=0.5 * cov, matched_concepts=m))
    return hits, stats


def concept_weights(conn, concepts: list[set[str]]) -> list[float]:
    """IDF-style weight per concept group: words found in most passages (e.g. "training")
    weigh little, specific terms weigh more. Concepts absent from the library weigh most."""
    n = conn.execute("SELECT COUNT(*) c FROM chunks").fetchone()["c"]
    raw = []
    for g in concepts:
        q = " OR ".join('"' + t.replace('"', "") + '"' for t in sorted(g) if t)
        df = conn.execute("SELECT COUNT(*) c FROM chunks_fts WHERE chunks_fts MATCH ?", (q,)).fetchone()["c"] if q else 0
        raw.append((df, max(0.15, math.log((n + 1) / (df + 0.5)))))
    # A word that never occurs in the library weighs like a typical word that does (median),
    # so one unknown phrasing word cannot sink an otherwise well-covered question, while a
    # question made mostly of absent topics (e.g. "caffeine sprint") still fails the gate.
    present = sorted(w for df, w in raw if df > 0)
    cap = present[len(present) // 2] if present else 1.0
    return [w if df > 0 else cap for df, w in raw]


def passes_gate(hit: Hit, settings: Settings, semantic: bool) -> bool:
    """Evidence relevance gate: the passage must actually address the question."""
    if hit.coverage >= settings.min_concept_coverage:
        return True
    # A strong semantic match can compensate for vocabulary mismatch (e.g. Arabic
    # question vs English source) — only with a real semantic embedder.
    return semantic and hit.vector_sim >= settings.min_vector_similarity and hit.coverage > 0
