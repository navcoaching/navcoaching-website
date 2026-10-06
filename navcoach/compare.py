"""Study comparison table built only from text found in each file.

Each cell is either a verbatim sentence from the document (with its citation)
or the explicit marker "not stated in the file".
"""
from __future__ import annotations

import re

from . import db
from .rag import citation_for, log_entry
from .index import Hit
from .textutil import concept_coverage, is_statement, looks_like_injection, query_concepts, sentences, tokens

NOT_STATED = {"ar": "غير مذكور في الملف", "en": "Not stated in the file"}

FIELDS = [
    ("design", {"ar": "تصميم الدراسة", "en": "Study design"},
     re.compile(r"randomi[sz]ed|controlled trial|crossover|cross-sectional|cohort|systematic review|meta-analy|"
                r"within-subject|between-group|observational|case study|pilot", re.I)),
    ("sample", {"ar": "العينة وحجمها", "en": "Sample & size"},
     re.compile(r"\b(n\s*=\s*\d+|\d+\s+(?:resistance-trained |untrained |trained |healthy |recreationally |older |young )?"
                r"(participants|subjects|men|women|males|females|adults|athletes|individuals|volunteers|studies|trials))\b|"
                r"\b(thirty|forty|twenty|fifty|sixty)[- ]\w+ (participants|subjects)", re.I)),
    ("duration", {"ar": "مدة التدخل", "en": "Intervention duration"},
     re.compile(r"\b\d+[- ]?(weeks?|wk|months?|days?)\b(?! per)|\b(eight|six|ten|twelve|four)[- ]weeks?\b", re.I)),
    ("measures", {"ar": "المتغيرات المقاسة", "en": "Measured variables"},
     re.compile(r"\b(measured|assessed|evaluated|quantified|determined|recorded)\b|\b(ultrasound|dxa|mri|1rm test)\b", re.I)),
    ("results", {"ar": "النتائج الرئيسية", "en": "Main results"},
     re.compile(r"significant|no difference|greater|increase|improve|similar|comparable|dose-response|did not", re.I)),
    ("limitations", {"ar": "القيود المنهجية المذكورة", "en": "Stated limitations"},
     re.compile(r"limitation|limited by|should be interpreted|caution|may not generali|small sample|short duration", re.I)),
]


def _doc_hits(conn, doc_id: str) -> list[Hit]:
    rows = conn.execute(
        "SELECT c.*, d.filename, d.title, d.authors, d.year, d.doc_type FROM chunks c JOIN documents d ON d.id=c.doc_id "
        "WHERE c.doc_id=? ORDER BY c.ordinal", (doc_id,)).fetchall()
    out = []
    for r in rows:
        out.append(Hit(chunk_id=r["id"], doc_id=r["doc_id"], text=r["text"], page=r["page"], printed_page=r["printed_page"],
                       location=r["location"], section=r["section"], quality=r["quality"], flags=[],
                       filename=r["filename"], title=r["title"], authors=r["authors"], year=r["year"], doc_type=r["doc_type"]))
    return out


def _best_sentence(hits: list[Hit], rx: re.Pattern, field: str, concepts) -> tuple[str, Hit] | None:
    best, best_score = None, 0.0
    for h in hits:
        sec = (h.section or "").lower()
        for s in sentences(h.text):
            if not is_statement(s) or looks_like_injection(s) or not rx.search(s):
                continue
            score = 1.0
            if field == "limitations" and "limitation" in sec:
                score += 1.5
            if field == "results" and "result" in sec:
                score += 1.0
            if field in ("design", "sample", "duration") and any(k in sec for k in ("abstract", "method", "participant")):
                score += 0.8
            if field == "results" and concepts:
                score += concept_coverage(concepts, set(tokens(s)))
            if "reference" in sec:
                score -= 2
            if score > best_score:
                best, best_score = (s, h), score
    return best


def compare(doc_ids: list[str], question: str = "", lang: str = "ar") -> dict:
    lang = "en" if lang == "en" else "ar"
    concepts = query_concepts(question) if question else []
    rows, citations, n = [], {}, 0
    with db.session() as conn:
        docs = {r["id"]: dict(r) for r in conn.execute(
            f"SELECT * FROM documents WHERE id IN ({','.join('?' * len(doc_ids))})", doc_ids)} if doc_ids else {}
        for doc_id in doc_ids:
            d = docs.get(doc_id)
            if not d:
                continue
            hits = _doc_hits(conn, doc_id)
            row = {"doc_id": doc_id, "filename": d["filename"],
                   "title": d["title"] or NOT_STATED[lang], "year": d["year"] or NOT_STATED[lang],
                   "status": d["status"], "cells": {}}
            for key, label, rx in FIELDS:
                found = _best_sentence(hits, rx, key, concepts)
                if found:
                    n += 1
                    eid = f"E{n}"
                    s, h = found
                    citations[eid] = citation_for(eid, h, s)
                    row["cells"][key] = {"text": s, "citation": eid}
                else:
                    row["cells"][key] = {"text": NOT_STATED[lang], "citation": None}
            if concepts:
                best = max(((concept_coverage(concepts, set(tokens(h.text))), h) for h in hits),
                           key=lambda x: x[0], default=(0, None))
                if best[1] is not None and best[0] > 0:
                    n += 1
                    eid = f"E{n}"
                    citations[eid] = citation_for(eid, best[1], None)
                    row["cells"]["relevance"] = {"text": f"{round(best[0] * 100)}%", "citation": eid}
                else:
                    row["cells"]["relevance"] = {"text": "0%", "citation": None}
            rows.append(row)
    columns = [{"key": k, "label": lbl[lang]} for k, lbl, _ in FIELDS]
    if concepts:
        columns.append({"key": "relevance", "label": "الصلة بسؤالك (تغطية المفاهيم)" if lang == "ar"
                        else "Relevance to your question (concept coverage)"})
    result = {"question": question, "status": "answered" if rows else "insufficient", "columns": columns, "rows": rows,
              "citations": citations,
              "note": ("كل خانة اقتباس حرفي من الملف أو «غير مذكور في الملف». الاستخراج آلي، فتحقق من الدليل قبل الاعتماد عليه."
                       if lang == "ar" else
                       "Every cell is a verbatim quote from the file or 'Not stated in the file'. Extraction is automatic — check the evidence before relying on it.")}
    result["id"] = log_entry("compare", question or "comparison", result["status"], "extractive", result, doc_ids)
    return result
