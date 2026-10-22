"""Split extracted units into retrieval chunks.

Chunks never cross a page boundary, so every chunk maps to exactly one page and
citations stay exact.
"""
from __future__ import annotations

import bisect
import re
from dataclasses import dataclass, field

from .extract import ExtractResult
from .textutil import looks_like_injection, sentences

TARGET = 900
MAX = 1400


@dataclass
class Chunk:
    ordinal: int
    page: int | None
    printed_page: str | None
    location: str | None
    section: str | None
    text: str
    quality: str = "ok"
    flags: list[str] = field(default_factory=list)


def _section_at(headings: list[tuple[int, str]], offset: int, carried: str | None) -> str | None:
    if not headings:
        return carried
    offs = [h[0] for h in headings]
    i = bisect.bisect_right(offs, offset) - 1
    return headings[i][1] if i >= 0 else carried


def chunk_units(res: ExtractResult) -> list[Chunk]:
    chunks: list[Chunk] = []
    carried_section: str | None = None
    for unit in res.units:
        if unit.status not in ("ok", "ocr") or not unit.text.strip():
            continue
        paras = [(m.start(), m.group(0)) for m in re.finditer(r"[^\n]+(?:\n(?!\n)[^\n]+)*", unit.text)]
        heading_texts = {h for _, h in unit.headings}
        buf: list[str] = []
        buf_start = 0
        size = 0

        def emit():
            nonlocal buf, size
            text = "\n\n".join(buf).strip()
            if len(re.sub(r"\W", "", text)) < 15:
                buf, size = [], 0
                return
            first = text.split("\n", 1)[0].strip()
            sec = first if first in heading_texts else _section_at(unit.headings, buf_start, carried_section)
            flags = ["possible_instruction"] if looks_like_injection(text) else []
            chunks.append(Chunk(len(chunks), unit.page, unit.printed_page, unit.location, sec, text,
                                "ocr" if unit.status == "ocr" else "ok", flags))
            buf, size = [], 0

        for start, para in paras:
            # Very long paragraphs are split on sentence boundaries.
            pieces = [para] if len(para) <= MAX else _split_long(para)
            for piece in pieces:
                if not buf:
                    buf_start = start
                # Start a new chunk at section headings so sections are not mixed.
                is_heading = piece.split("\n", 1)[0].strip() in heading_texts
                if buf and (size + len(piece) > TARGET or is_heading):
                    emit()
                    buf_start = start
                buf.append(piece)
                size += len(piece)
        if buf:
            emit()
        if unit.headings:
            carried_section = unit.headings[-1][1]
    return chunks


def _split_long(para: str) -> list[str]:
    out, cur = [], ""
    for s in sentences(para):
        if cur and len(cur) + len(s) > TARGET:
            out.append(cur)
            cur = s
        else:
            cur = f"{cur} {s}".strip()
    if cur:
        out.append(cur)
    return out
