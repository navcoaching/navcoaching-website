"""Metadata detection from extracted text (title, year, DOI, document type).

All values are *detected* from the file; anything not found stays empty rather
than being guessed.
"""
from __future__ import annotations

import re
from pathlib import Path

from . import ExtractResult

_DOI = re.compile(r"\b(10\.\d{4,9}/[^\s\"<>]+[^\s\"<>.,;)])", re.I)
_YEAR_CONTEXT = re.compile(
    r"(?:©|\(c\)|copyright|published(?: online)?:?|accepted:?|received:?|\b(?:19|20)\d{2}\s*;\s*\d+)\s*"
    r"(?:[A-Za-z]+\s+\d{1,2},?\s+)?((?:19|20)\d{2})", re.I)

DOC_TYPES = [
    ("meta_analysis", re.compile(r"meta[- ]?analy(sis|ses|tic)|تحليل تلوي|التحليل التلوي", re.I)),
    ("systematic_review", re.compile(r"systematic(ally)? review|مراجعة منهجية", re.I)),
    ("rct", re.compile(r"randomi[sz]ed (controlled|control|clinical) trial|\brct\b|randomly (assigned|allocated)|تجربة عشوائية", re.I)),
    ("narrative_review", re.compile(r"\b(narrative|scoping) review\b|\breview article\b", re.I)),
    ("book", re.compile(r"\bisbn\b|\bchapter \d+\b|all rights reserved", re.I)),
    ("guideline", re.compile(r"position stand|position statement|guideline", re.I)),
    ("observational", re.compile(r"cross[- ]sectional (study|design|survey)|cohort study|observational study", re.I)),
]


def enrich(res: ExtractResult, path: Path) -> None:
    head = "\n".join(u.text for u in res.units[:3] if u.text)[:15000]
    m = _DOI.search(head)
    if m:
        res.doi = m.group(1)
    year = None
    m = _YEAR_CONTEXT.search(head)
    if m:
        year = int(m.group(1))
    if year is None:
        year = getattr(res, "_meta_year", None)
        if year is not None:
            res.warnings.append("publication year taken from file metadata (creation date) — verify")
    res.year = year
    for name, rx in DOC_TYPES:
        if rx.search(head):
            res.doc_type = name
            break
    if res.title:
        res.title = re.sub(r"\s+", " ", res.title).strip()[:300]
        if res.title.lower() in ("untitled", "microsoft word", "title") or res.title.lower().endswith((".doc", ".docx", ".pdf")):
            res.title = None
    if not res.title:
        res.title = path.stem.replace("_", " ")
        res.warnings.append("title not detected — using file name")
