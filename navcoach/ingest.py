"""Knowledge-base ingestion: store originals, extract, chunk, index, report.

Files are processed incrementally: adding a file never re-processes the others.
"""
from __future__ import annotations

import hashlib
import json
import logging
import queue
import re
import shutil
import threading
import time
from pathlib import Path

from . import db, index
from .chunking import chunk_units
from .config import data_dir, get_settings
from .extract import SUPPORTED_EXTENSIONS, ExtractionError, extract
from .textutil import is_statement, looks_like_injection, sentences

log = logging.getLogger("navcoach.ingest")


def library_dir() -> Path:
    d = data_dir() / "library"
    d.mkdir(parents=True, exist_ok=True)
    return d


def safe_filename(name: str) -> str:
    name = Path(name.replace("\\", "/")).name
    name = re.sub(r"[^\w؀-ۿ.\- ()]+", "_", name).strip(" .")
    return name[:180] or "file"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class DuplicateFile(Exception):
    def __init__(self, existing: dict):
        super().__init__("duplicate file")
        self.existing = existing


class NameConflict(Exception):
    def __init__(self, existing: dict):
        super().__init__("a different file with the same name exists")
        self.existing = existing


def add_file(filename: str, data: bytes, source_path: str | None = None, on_name_conflict: str = "ask",
             process: bool = True, sync: bool = False) -> dict:
    """Store a new file and queue it for processing.

    on_name_conflict: 'ask' (raise NameConflict), 'replace' (update the existing
    document in place, no duplicate) or 'keep_both'.
    """
    filename = safe_filename(filename)
    ext = Path(filename).suffix.lower()
    if ext not in SUPPORTED_EXTENSIONS:
        raise ValueError(f"unsupported file type '{ext}'. Supported: {', '.join(sorted(SUPPORTED_EXTENSIONS))}")
    digest = sha256_bytes(data)
    with db.session() as conn:
        dup = conn.execute("SELECT * FROM documents WHERE sha256=?", (digest,)).fetchone()
        if dup:
            raise DuplicateFile(db.row_to_dict(dup))
        same = conn.execute("SELECT * FROM documents WHERE filename=?", (filename,)).fetchone()
    if same and on_name_conflict == "ask":
        raise NameConflict(db.row_to_dict(same))
    if same and on_name_conflict == "replace":
        return replace_file(same["id"], data, filename=filename, sync=sync)

    doc_id = db.new_id()
    folder = library_dir() / doc_id
    folder.mkdir(parents=True, exist_ok=True)
    stored = folder / filename
    stored.write_bytes(data)
    now = time.time()
    with db.session() as conn:
        conn.execute(
            "INSERT INTO documents(id,filename,stored_path,source_path,sha256,size_bytes,file_type,status,created_at,updated_at)"
            " VALUES(?,?,?,?,?,?,?,?,?,?)",
            (doc_id, filename, str(stored.relative_to(data_dir())), source_path, digest, len(data), ext.lstrip("."),
             "pending", now, now))
    if process:
        if sync:
            process_document(doc_id)
        else:
            worker.enqueue(doc_id)
    return get_document(doc_id)


def replace_file(doc_id: str, data: bytes, filename: str | None = None, sync: bool = False) -> dict:
    """Replace a document's file and re-process it under the same id (no duplicates)."""
    digest = sha256_bytes(data)
    with db.session() as conn:
        row = conn.execute("SELECT * FROM documents WHERE id=?", (doc_id,)).fetchone()
        if not row:
            raise KeyError(doc_id)
        dup = conn.execute("SELECT * FROM documents WHERE sha256=? AND id<>?", (digest, doc_id)).fetchone()
        if dup:
            raise DuplicateFile(db.row_to_dict(dup))
        filename = safe_filename(filename or row["filename"])
        folder = library_dir() / doc_id
        if folder.exists():
            shutil.rmtree(folder)
        folder.mkdir(parents=True)
        stored = folder / filename
        stored.write_bytes(data)
        index.delete_doc(conn, doc_id)
        conn.execute(
            "UPDATE documents SET filename=?, stored_path=?, sha256=?, size_bytes=?, file_type=?, status='pending',"
            " status_detail=NULL, updated_at=? WHERE id=?",
            (filename, str(stored.relative_to(data_dir())), digest, len(data), Path(filename).suffix.lstrip(".").lower(),
             time.time(), doc_id))
    if sync:
        process_document(doc_id)
    else:
        worker.enqueue(doc_id)
    return get_document(doc_id)


def _extractive_summary(res) -> str | None:
    """Summary made of sentences copied verbatim from the file (abstract first)."""
    abstract_text = None
    for u in res.units[:3]:
        for off, h in u.headings:
            if h.lower().strip(" :") in ("abstract", "summary", "الملخص"):
                abstract_text = u.text[off + len(h):]
                break
        if abstract_text:
            break
        m = re.search(r"\babstract\b[:.]?\s*(.+)", u.text, re.I | re.S)
        if m:
            abstract_text = m.group(1)
            break
    source = abstract_text or "\n\n".join(u.text for u in res.units[:2] if u.text)
    picked = []
    for s in sentences(source):
        if (40 <= len(s) <= 400 and is_statement(s) and not looks_like_injection(s)
                and sum(c.isalpha() for c in s) / len(s) > 0.6):
            picked.append(s)
        if len(picked) >= 3:
            break
    return " ".join(picked) or None


def process_document(doc_id: str) -> dict:
    with db.session() as conn:
        row = conn.execute("SELECT * FROM documents WHERE id=?", (doc_id,)).fetchone()
        if not row:
            raise KeyError(doc_id)
        conn.execute("UPDATE documents SET status='processing', status_detail=NULL, updated_at=? WHERE id=?",
                     (time.time(), doc_id))
    path = data_dir() / row["stored_path"]
    try:
        res = extract(path)
        chunks = chunk_units(res)
    except ExtractionError as exc:
        _fail(doc_id, str(exc))
        return get_document(doc_id)
    except Exception as exc:  # never log document content
        log.warning("processing failed for document %s: %s", doc_id, type(exc).__name__)
        _fail(doc_id, f"unexpected error ({type(exc).__name__})")
        return get_document(doc_id)

    report = res.report()
    if not chunks:
        detail = "no extractable text"
        if res.pages_failed:
            detail += f" — {res.pages_failed} page(s) unreadable (scanned or garbled)"
        _fail(doc_id, detail, res, report)
        return get_document(doc_id)
    problems = []
    if res.pages_failed:
        problems.append(f"{res.pages_failed} page(s) could not be read")
    if res.pages_ocr:
        problems.append(f"{res.pages_ocr} page(s) read by OCR")
    flagged = sum(1 for c in chunks if c.flags)
    if flagged:
        problems.append(f"{flagged} passage(s) contain instruction-like text (treated as data, not instructions)")
    status = "needs_review" if problems else "processed"
    settings = get_settings()
    try:
        with db.session() as conn:
            index.delete_doc(conn, doc_id)
            n = index.add_chunks(conn, doc_id, chunks, settings)
            conn.execute(
                "UPDATE documents SET status=?, status_detail=?, title=?, authors=?, year=?, doi=?, doc_type=?,"
                " page_count=?, pages_ok=?, pages_failed=?, pages_ocr=?, chunk_count=?, summary=?, extraction_report=?,"
                " embedder=?, processed_at=?, updated_at=? WHERE id=?",
                (status, "; ".join(problems) or None, res.title, res.authors, res.year, res.doi, res.doc_type,
                 res.page_count, res.pages_ok, res.pages_failed, res.pages_ocr, n, _extractive_summary(res),
                 json.dumps(report, ensure_ascii=False), db.get_meta(conn, "embedder"), time.time(), time.time(), doc_id))
    except Exception as exc:
        log.warning("indexing failed for document %s: %s", doc_id, type(exc).__name__)
        _fail(doc_id, f"indexing failed ({type(exc).__name__})", res, report)
    return get_document(doc_id)


def _fail(doc_id: str, detail: str, res=None, report=None) -> None:
    with db.session() as conn:
        index.delete_doc(conn, doc_id)
        conn.execute(
            "UPDATE documents SET status='failed', status_detail=?, chunk_count=0, page_count=?, pages_ok=?,"
            " pages_failed=?, pages_ocr=?, extraction_report=?, updated_at=? WHERE id=?",
            (detail, res.page_count if res else None, res.pages_ok if res else None,
             res.pages_failed if res else None, res.pages_ocr if res else None,
             json.dumps(report, ensure_ascii=False) if report else None, time.time(), doc_id))


def get_document(doc_id: str) -> dict | None:
    with db.session() as conn:
        row = conn.execute("SELECT * FROM documents WHERE id=?", (doc_id,)).fetchone()
        if not row:
            return None
        d = db.row_to_dict(row)
        d["collections"] = [dict(r) for r in conn.execute(
            "SELECT c.id, c.name, c.name_ar FROM collections c JOIN document_collections dc ON dc.collection_id=c.id"
            " WHERE dc.doc_id=?", (doc_id,))]
        d["tags"] = [r["tag"] for r in conn.execute("SELECT tag FROM document_tags WHERE doc_id=? ORDER BY tag", (doc_id,))]
        return d


def list_documents(collection_id: str | None = None, tag: str | None = None, q: str | None = None) -> list[dict]:
    sql = "SELECT id FROM documents d WHERE 1=1"
    args: list = []
    if collection_id:
        sql += " AND id IN (SELECT doc_id FROM document_collections WHERE collection_id=?)"
        args.append(collection_id)
    if tag:
        sql += " AND id IN (SELECT doc_id FROM document_tags WHERE tag=?)"
        args.append(tag)
    if q:
        sql += " AND (filename LIKE ? OR title LIKE ? OR authors LIKE ?)"
        args += [f"%{q}%"] * 3
    sql += " ORDER BY created_at DESC"
    with db.session() as conn:
        ids = [r["id"] for r in conn.execute(sql, args)]
    return [get_document(i) for i in ids]


def delete_document(doc_id: str) -> bool:
    with db.session() as conn:
        row = conn.execute("SELECT * FROM documents WHERE id=?", (doc_id,)).fetchone()
        if not row:
            return False
        index.delete_doc(conn, doc_id)
        conn.execute("DELETE FROM documents WHERE id=?", (doc_id,))
    folder = library_dir() / doc_id
    if folder.exists():
        shutil.rmtree(folder, ignore_errors=True)
    return True


def update_document_meta(doc_id: str, changes: dict) -> dict:
    allowed = {"title", "authors", "year", "doc_type"}
    with db.session() as conn:
        for k, v in changes.items():
            if k in allowed:
                conn.execute(f"UPDATE documents SET {k}=?, updated_at=? WHERE id=?", (v or None, time.time(), doc_id))
        if "tags" in changes:
            conn.execute("DELETE FROM document_tags WHERE doc_id=?", (doc_id,))
            for t in {str(t).strip() for t in changes["tags"] if str(t).strip()}:
                conn.execute("INSERT INTO document_tags(doc_id,tag) VALUES(?,?)", (doc_id, t[:60]))
        if "collection_ids" in changes:
            conn.execute("DELETE FROM document_collections WHERE doc_id=?", (doc_id,))
            for cid in changes["collection_ids"]:
                conn.execute("INSERT OR IGNORE INTO document_collections(doc_id,collection_id) VALUES(?,?)", (doc_id, cid))
    return get_document(doc_id)


def import_folder(folder: str, on_name_conflict: str = "replace", sync: bool = False) -> dict:
    root = Path(folder).expanduser()
    if not root.is_dir():
        raise ValueError("folder not found")
    report = {"added": [], "duplicates": [], "replaced": [], "skipped": [], "errors": []}
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        if p.suffix.lower() not in SUPPORTED_EXTENSIONS:
            report["skipped"].append(str(p.relative_to(root)))
            continue
        try:
            existing_names = {d["filename"] for d in list_documents()}
            doc = add_file(p.name, p.read_bytes(), source_path=str(p.relative_to(root)),
                           on_name_conflict=on_name_conflict, sync=sync)
            key = "replaced" if safe_filename(p.name) in existing_names else "added"
            report[key].append({"file": str(p.relative_to(root)), "id": doc["id"]})
        except DuplicateFile as d:
            report["duplicates"].append({"file": str(p.relative_to(root)), "existing_id": d.existing["id"]})
        except NameConflict as c:
            report["skipped"].append(f"{p.relative_to(root)} (name exists: {c.existing['id']})")
        except Exception as exc:
            report["errors"].append({"file": str(p.relative_to(root)), "error": type(exc).__name__})
    return report


def rebuild_index(sync: bool = True) -> dict:
    """Drop all chunks/vectors and re-extract every stored original file."""
    with db.session() as conn:
        index.clear_all(conn)
        ids = [r["id"] for r in conn.execute("SELECT id FROM documents ORDER BY created_at")]
        conn.execute("UPDATE documents SET status='pending', chunk_count=0")
        db.set_meta(conn, "embedder", "")
    results = {"processed": 0, "failed": 0, "needs_review": 0}
    for i in ids:
        if sync:
            d = process_document(i)
            results[d["status"]] = results.get(d["status"], 0) + 1
        else:
            worker.enqueue(i)
    return {"documents": len(ids), **results}


def library_stats() -> dict:
    with db.session() as conn:
        by_status = {r["status"]: r["c"] for r in conn.execute("SELECT status, COUNT(*) c FROM documents GROUP BY status")}
        tot = conn.execute(
            "SELECT COUNT(*) docs, COALESCE(SUM(page_count),0) pages, COALESCE(SUM(pages_ok),0) pages_ok,"
            " COALESCE(SUM(pages_failed),0) pages_failed, COALESCE(SUM(pages_ocr),0) pages_ocr,"
            " COALESCE(SUM(chunk_count),0) chunks FROM documents").fetchone()
        by_type = {(r["doc_type"] or "unknown"): r["c"] for r in conn.execute(
            "SELECT doc_type, COUNT(*) c FROM documents GROUP BY doc_type")}
        queries = conn.execute("SELECT COUNT(*) c FROM queries").fetchone()["c"]
        clients = conn.execute("SELECT COUNT(*) c FROM clients").fetchone()["c"]
        programs = conn.execute("SELECT COUNT(DISTINCT lineage_id) c FROM programs").fetchone()["c"]
        idx = index.index_status(conn)
    return {**dict(tot), "by_status": by_status, "by_type": by_type, "queries": queries, "clients": clients,
            "programs": programs, "index": idx, "queue": worker.pending()}


class Worker:
    """Single background thread so uploads return immediately."""

    def __init__(self):
        self.q: queue.Queue[str] = queue.Queue()
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()

    def enqueue(self, doc_id: str) -> None:
        self.q.put(doc_id)
        with self._lock:
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(target=self._run, name="navcoach-ingest", daemon=True)
                self._thread.start()

    def pending(self) -> int:
        return self.q.qsize()

    def _run(self) -> None:
        while True:
            try:
                doc_id = self.q.get(timeout=2)
            except queue.Empty:
                return
            try:
                process_document(doc_id)
            except Exception as exc:
                log.warning("worker error on %s: %s", doc_id, type(exc).__name__)
            finally:
                self.q.task_done()

    def join(self) -> None:
        self.q.join()


worker = Worker()


def resume_pending() -> None:
    """Re-queue documents left pending/processing by a previous shutdown."""
    with db.session() as conn:
        ids = [r["id"] for r in conn.execute("SELECT id FROM documents WHERE status IN ('pending','processing')")]
    for i in ids:
        worker.enqueue(i)
