"""A structured view of ONE indexed document, rebuilt from its stored chunks.

Everything downstream (summaries, slides, study mode) reads the document only
through this model, so every sentence, table value and heading carries the
chunk/page it came from.
"""
from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field

from . import db
from .textutil import EN_STOP, is_statement, looks_like_injection, sentences, tokens

TOP_LEVEL = re.compile(
    r"^(abstract|summary|introduction|background|methods?|methodology|materials and methods|results|discussion|"
    r"conclusions?|limitations|practical applications|references|acknowledg\w+|chapter \d+|part [ivx\d]+|"
    r"الملخص|المقدمة|الطرق|المنهجية|النتائج|المناقشة|الخلاصة|القيود|المراجع)\b", re.I)
NUMBERED = re.compile(r"^\s*((?:\d+\.)*\d+)\.?\s+\S")
GENERIC_TERMS = set("""study studies participant participants group groups result results data table figure fig
et al use used using also however although including included include may might can could one two three
first second third total mean value values level levels effect effects significant significantly week weeks
day days author authors article paper chapter section page pages time times per p n determines determine determined performed perform
increased increase decreased decrease compared compare showed show shown found find using include includes many much
more less such well both each between after before during whether while within without across among various""".split())


@dataclass
class Source:
    chunk_id: str
    page: int | None
    printed_page: str | None
    section: str | None
    location: str | None
    quote: str
    quality: str = "ok"

    def to_dict(self, doc_id: str, filename: str) -> dict:
        is_pdf = filename.lower().endswith(".pdf")
        return {
            "chunk_id": self.chunk_id, "doc_id": doc_id, "filename": filename,
            "page": self.page if is_pdf else None, "unit_index": None if is_pdf else self.page,
            "printed_page": self.printed_page, "section": self.section, "location": self.location,
            "quote": self.quote, "quality": self.quality,
            "open_url": f"/api/documents/{doc_id}/file" + (f"#page={self.page}" if is_pdf and self.page else ""),
            "evidence_url": f"#/evidence/{self.chunk_id}",
        }


@dataclass
class Sentence:
    idx: int
    text: str
    chunk_id: str
    page: int | None
    printed_page: str | None
    section: str | None
    section_id: str
    location: str | None
    quality: str
    position: float          # 0..1 position in the document
    toks: set[str] = field(default_factory=set)

    def source(self) -> Source:
        return Source(self.chunk_id, self.page, self.printed_page, self.section, self.location, self.text, self.quality)


@dataclass
class OutlineSection:
    id: str
    title: str
    level: int
    number: str | None
    chunk_ids: list[str]
    pages: list[int]

    def to_dict(self) -> dict:
        return {"id": self.id, "title": self.title, "level": self.level, "number": self.number,
                "first_chunk_id": self.chunk_ids[0] if self.chunk_ids else None,
                "page_start": min(self.pages) if self.pages else None,
                "page_end": max(self.pages) if self.pages else None}


@dataclass
class Table:
    id: str
    caption: str
    header: list[str]
    rows: list[list[str]]
    chunk_id: str
    page: int | None
    printed_page: str | None
    section: str | None


@dataclass
class DocModel:
    doc: dict
    chunks: list[dict]
    outline: list[OutlineSection]
    sentences: list[Sentence]
    tables: list[Table]
    keywords: list[str]
    unread_units: list[dict]

    @property
    def doc_id(self) -> str:
        return self.doc["id"]

    @property
    def filename(self) -> str:
        return self.doc["filename"]

    def src(self, s: Source) -> dict:
        return s.to_dict(self.doc_id, self.filename)

    def chunk(self, chunk_id: str) -> dict | None:
        return next((c for c in self.chunks if c["id"] == chunk_id), None)


def _level(title: str) -> tuple[int, str | None]:
    m = NUMBERED.match(title)
    if m:
        number = m.group(1)
        return number.count(".") + 1, number
    return (1 if TOP_LEVEL.match(title) else 2), None


def _parse_tables(chunk: dict, start_index: int) -> list[Table]:
    out: list[Table] = []
    text = chunk["text"]
    # PDF/DOCX tables are stored as "[Table N ...]" followed by "a | b | c" rows.
    for m in re.finditer(r"\[Table[^\]]*\]\s*\n((?:[^\n]*\|[^\n]*\n?)+)", text):
        lines = [ln for ln in m.group(1).strip().split("\n") if "|" in ln]
        rows = [[c.strip() for c in ln.split("|")] for ln in lines]
        if len(rows) >= 2:
            out.append(Table(f"t{start_index + len(out) + 1}", m.group(0).split("]")[0].strip("[ "),
                             rows[0], rows[1:], chunk["id"], chunk["page"], chunk["printed_page"], chunk["section"]))
    # Spreadsheet rows are stored as "header: value; header: value".
    if not out and chunk.get("location") and ("rows" in (chunk["location"] or "")):
        recs = []
        for ln in text.split("\n"):
            parts = [p.partition(":") for p in ln.split(";")]
            if len(parts) >= 2 and all(p[1] for p in parts):
                recs.append({p[0].strip(): p[2].strip() for p in parts})
        if len(recs) >= 2:
            header = list(dict.fromkeys(k for r in recs for k in r))
            out.append(Table(f"t{start_index + 1}", chunk["location"], header,
                             [[r.get(h, "") for h in header] for r in recs], chunk["id"], chunk["page"],
                             chunk["printed_page"], chunk["section"]))
    return out


def _keywords(sents: list[Sentence], n: int = 40) -> list[str]:
    counts: Counter[str] = Counter()
    for s in sents:
        words = [w.lower() for w in re.findall(r"[A-Za-z][A-Za-z\-]{2,}|[ء-ي]{3,}", s.text)]
        for size in (1, 2, 3):
            for i in range(len(words) - size + 1):
                gram = words[i:i + size]
                if any(w in EN_STOP or w in GENERIC_TERMS for w in gram):
                    continue
                counts[" ".join(gram)] += 1 + 0.6 * (size - 1)
    ranked = [t for t, c in counts.most_common(n * 3) if c >= 2]
    out: list[str] = []
    for t in ranked:  # drop terms that are sub-strings of an already chosen longer term with similar weight
        if any(t in o.split() or t == o for o in out):
            continue
        out.append(t)
        if len(out) >= n:
            break
    return out


def load(doc_id: str) -> DocModel | None:
    with db.session() as conn:
        doc = db.row_to_dict(conn.execute("SELECT * FROM documents WHERE id=?", (doc_id,)).fetchone())
        if not doc:
            return None
        chunks = [db.row_to_dict(r) for r in conn.execute(
            "SELECT * FROM chunks WHERE doc_id=? ORDER BY ordinal", (doc_id,))]
    outline: list[OutlineSection] = []
    sents: list[Sentence] = []
    tables: list[Table] = []
    total = max(len(chunks), 1)
    current: OutlineSection | None = None
    for ci, c in enumerate(chunks):
        title = (c["section"] or "").strip()
        if current is None or title != current.title:
            lvl, num = _level(title) if title else (1, None)
            current = OutlineSection(f"s{len(outline) + 1}", title, lvl, num, [], [])
            outline.append(current)
        current.chunk_ids.append(c["id"])
        if c["page"]:
            current.pages.append(c["page"])
        tables.extend(_parse_tables(c, len(tables)))
        body = re.sub(r"\[Table[^\]]*\]\s*\n(?:[^\n]*\|[^\n]*\n?)+", "\n\n", c["text"])
        for s in sentences(body):
            s = s.strip()
            if not is_statement(s) or looks_like_injection(s):
                continue
            if title and s.startswith(title + " ") and s[len(title) + 1:len(title) + 2].isupper():
                s = s[len(title) + 1:].strip()  # heading glued to the first sentence of its section
            sents.append(Sentence(len(sents), s, c["id"], c["page"], c["printed_page"], c["section"], current.id,
                                  c["location"], c["quality"], ci / total, set(tokens(s))))
    report = doc.get("extraction_report") or {}
    unread = [u for u in (report.get("units") or []) if u.get("status") == "unreadable"]
    return DocModel(doc, chunks, outline, sents, tables, _keywords(sents), unread)
