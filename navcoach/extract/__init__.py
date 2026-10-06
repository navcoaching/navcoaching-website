"""Document extraction: turns a file into page-level units with honest status.

Every extractor returns an :class:`ExtractResult`. A page/unit that could not
be read reliably is reported with status ``unreadable`` (or ``ocr`` when OCR
text was used) — it is never silently treated as read.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

SUPPORTED_EXTENSIONS = {".pdf", ".docx", ".pptx", ".xlsx", ".xlsm", ".csv", ".txt", ".md", ".markdown"}


class ExtractionError(Exception):
    """Raised when a file cannot be opened/parsed at all (corrupt, encrypted...)."""


@dataclass
class Unit:
    """A page, slide, sheet or text section."""
    page: int | None            # 1-based physical page/slide/sheet index; None for unpaged formats
    text: str
    status: str = "ok"          # ok | ocr | unreadable | empty
    printed_page: str | None = None
    location: str | None = None
    # list of (char_offset, heading) pairs inside `text`
    headings: list[tuple[int, str]] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


@dataclass
class ExtractResult:
    units: list[Unit]
    file_type: str
    title: str | None = None
    authors: str | None = None
    year: int | None = None
    doi: str | None = None
    doc_type: str | None = None
    warnings: list[str] = field(default_factory=list)

    @property
    def page_count(self) -> int:
        return len(self.units)

    @property
    def pages_ok(self) -> int:
        return sum(1 for u in self.units if u.status == "ok")

    @property
    def pages_ocr(self) -> int:
        return sum(1 for u in self.units if u.status == "ocr")

    @property
    def pages_failed(self) -> int:
        return sum(1 for u in self.units if u.status in ("unreadable",))

    @property
    def total_chars(self) -> int:
        return sum(len(u.text) for u in self.units if u.status in ("ok", "ocr"))

    def report(self) -> dict:
        return {
            "file_type": self.file_type,
            "units": [
                {"page": u.page, "printed_page": u.printed_page, "location": u.location,
                 "status": u.status, "chars": len(u.text), "warnings": u.warnings}
                for u in self.units
            ],
            "warnings": self.warnings,
        }


def extract(path: Path) -> ExtractResult:
    ext = path.suffix.lower()
    if ext not in SUPPORTED_EXTENSIONS:
        raise ExtractionError(f"unsupported file type: {ext}")
    if path.stat().st_size == 0:
        raise ExtractionError("empty file (0 bytes)")
    from . import formats
    from .metadata import enrich
    try:
        if ext == ".pdf":
            res = formats.extract_pdf(path)
        elif ext == ".docx":
            res = formats.extract_docx(path)
        elif ext == ".pptx":
            res = formats.extract_pptx(path)
        elif ext in (".xlsx", ".xlsm"):
            res = formats.extract_xlsx(path)
        elif ext == ".csv":
            res = formats.extract_csv(path)
        else:
            res = formats.extract_text(path)
    except ExtractionError:
        raise
    except Exception as exc:  # corrupt / unparsable
        raise ExtractionError(f"could not parse file ({type(exc).__name__})") from exc
    enrich(res, path)
    return res
