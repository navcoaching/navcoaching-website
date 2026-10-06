"""Educational slide decks generated from a verified summary.

Slides only re-use claims that already passed verification (each with its
source). Visuals are built strictly from file content:
* charts   — only from numeric cells of a table extracted from the file;
* flow     — only from methodology fields actually found in the file;
* concept map — only from sentences that state a relation between two terms.
No chart or diagram is created when the file has no data for it.
"""
from __future__ import annotations

import io
import re

from .docmodel import DocModel
from .summarize import LEVELS, NOT_FOUND, _first_number, _section_kind, score_sentences

T = {
    "big_picture": ("الصورة الكبيرة", "The big picture"), "concepts": ("المفاهيم الأساسية", "Key concepts"),
    "background": ("الخلفية", "Background"), "methods": ("المنهجية", "Methods"),
    "findings": ("النتائج الرئيسية", "Main findings"), "limitations": ("القيود", "Limitations"),
    "practical": ("التطبيقات العملية", "Practical takeaways"), "conclusion": ("الخلاصة", "Conclusion"),
    "takeaways": ("أهم ما يجب تذكره", "Key takeaways"), "concept_map": ("خريطة المفاهيم", "Concept map"),
    "data": ("بيانات من الملف", "Data from the file"), "table": ("جدول من الملف", "Table from the file"),
    "topic": ("الموضوع", "Topic"), "aim": ("السؤال / الهدف", "Question / aim"),
    "main_finding": ("أهم ما توصل إليه", "Main finding"), "why_important": ("لماذا هو مهم؟", "Why it matters"),
    "participants": ("المشاركون", "Participants"), "design": ("التصميم", "Design"),
    "intervention": ("التدخل", "Intervention"), "duration": ("المدة", "Duration"), "measures": ("القياسات", "Measurements"),
    "sample_characteristics": ("خصائص العينة", "Sample characteristics"),
    "measurement_method": ("طريقة القياس", "Measurement method"), "main_results": ("النتائج الأساسية", "Main results"),
}


def _t(key: str, lang: str) -> str:
    a, e = T.get(key, (key, key))
    return a if lang == "ar" else e


def _short(text: str, n: int = 170) -> str:
    text = text.strip()
    if len(text) <= n:
        return text
    cut = text[:n].rsplit(" ", 1)[0]
    return cut + " …"


def _bullet(claim: dict, **extra) -> dict:
    return {"text": _short(claim["text"]), "full": claim["text"], "kind": claim.get("kind"),
            "sources": claim.get("sources", []), **extra}


def _note(claim: dict) -> dict:
    return {"text": claim["text"], "sources": claim.get("sources", []), "kind": claim.get("kind")}


def _context_notes(model: DocModel, claim: dict, width: int = 1) -> list[dict]:
    """Verbatim neighbouring sentences from the same passage — extra detail for speaker notes."""
    if not claim.get("sources"):
        return []
    cid = claim["sources"][0]["chunk_id"]
    sents = [s for s in model.sentences if s.chunk_id == cid]
    idx = next((i for i, s in enumerate(sents) if s.text in claim["text"] or claim["text"] in s.text
                or (claim["sources"][0].get("quote") or "")[:60] in s.text), None)
    if idx is None:
        return []
    out = []
    for s in sents[max(0, idx - width):idx] + sents[idx + 1:idx + 1 + width]:
        out.append({"text": s.text, "sources": [model.src(s.source())], "kind": "quote", "context": True})
    return out


def _slide(i: int, typ: str, title: str, **kw) -> dict:
    s = {"id": f"sl{i}", "type": typ, "title": title, "subtitle": None, "bullets": [], "layout": "list",
         "visual": None, "notes": []}
    s.update(kw)
    srcs = [src for b in s["bullets"] for src in b.get("sources", [])] + [src for n in s["notes"] for src in n.get("sources", [])]
    if s["visual"] and s["visual"].get("source"):
        srcs.append(s["visual"]["source"])
    seen, uniq = set(), []
    for x in srcs:
        key = (x.get("chunk_id"), x.get("page"))
        if key not in seen:
            seen.add(key)
            uniq.append(x)
    s["sources"] = uniq
    return s


def build_slides(model: DocModel, content: dict, level: str, lang: str) -> dict:
    L = LEVELS[level]
    ov = content["overview"]
    slides: list[dict] = []

    def add(typ, title, **kw):
        slides.append(_slide(len(slides) + 1, typ, title, **kw))

    # 1. Title
    aim = next((q for q in content["quick"] if q["key"] == "aim" and q.get("sources")), None)
    meta = " — ".join(str(x) for x in (ov.get("authors"), ov.get("year")) if x)
    add("title", ov["title"], subtitle=_short(aim["text"], 220) if aim else None, layout="title",
        bullets=[_bullet(aim)] if aim else [],
        notes=[{"text": f"{ov['filename']} • {meta}" if meta else ov["filename"], "sources": []}]
              + ([{"text": w, "sources": []} for w in content.get("warnings", [])]))
    # 2. Big picture
    cards = []
    for q in content["quick"]:
        if q.get("sources"):
            cards.append(_bullet(q, label=_t(q["key"], lang)))
        else:
            cards.append({"text": NOT_FOUND[lang], "full": NOT_FOUND[lang], "kind": "not_found", "sources": [],
                          "label": _t(q["key"], lang)})
    add("big_picture", _t("big_picture", lang), bullets=cards, layout="cards",
        notes=[_note(q) for q in content["quick"] if q.get("sources")])
    # 3. Key concepts
    if content.get("concepts"):
        add("concepts", _t("concepts", lang), layout="cards",
            bullets=[_bullet(c, label=c.get("term")) for c in content["concepts"][:6]],
            notes=[{**_note(c), "label": c.get("term")} for c in content["concepts"]])
    # 4. Background
    scores = score_sentences(model)
    intro = [s for s in model.sentences if _section_kind(s.section) == "intro"]
    intro.sort(key=lambda s: -scores.get(s.idx, 0))
    if intro:
        top = sorted(intro[:4], key=lambda s: s.idx)
        bl = [{"text": _short(s.text), "full": s.text, "kind": "quote", "sources": [model.src(s.source())]} for s in top]
        add("background", _t("background", lang), bullets=bl[:3], notes=[_note(b) for b in bl])
    # 5. Methods
    meth = content.get("methodology") or {}
    if meth.get("_applicable"):
        order = ["participants", "design", "intervention", "duration", "measures", "measurement_method", "sample_characteristics"]
        found_raw = [(k, meth[k]) for k in order if isinstance(meth.get(k), dict) and meth[k].get("sources")]
        # One card per distinct sentence: fields answered by the same sentence are merged.
        merged: dict[str, tuple[list[str], dict]] = {}
        for k, c in found_raw:
            merged.setdefault(c["text"], ([], c))[0].append(k)
        found = [(" / ".join(_t(k, lang) for k in ks), c, ks) for ks, c in merged.values()]
        if found:
            flow = [(label, c) for label, c, ks in found
                    if set(ks) & {"participants", "design", "intervention", "duration", "measures"}]
            visual = None
            if len(flow) >= 3:
                visual = {"type": "flow", "nodes": [{"label": label, "text": _short(c["text"], 110), "sources": c["sources"]}
                                                    for label, c in flow]}
            add("methods", _t("methods", lang), layout="flow" if visual else "cards", visual=visual,
                bullets=[_bullet(c, label=label) for label, c, _ in found],
                notes=[{**_note(c), "label": label} for label, c, _ in found])
    # 6+. Findings (with highlighted numbers)
    fps = L["findings_per_slide"]
    fnd = content.get("findings") or []
    for i in range(0, len(fnd), fps):
        part = fnd[i:i + fps]
        bl = []
        for c in part:
            hl = re.search(r"(?:n\s*=\s*\d+|\d+(?:[.,]\d+)?\s?(?:%|kg|g/kg|weeks?|sets?|reps?|repetitions|minutes?|min|days?|cm|mm|kcal))",
                           c["text"], re.I)
            bl.append(_bullet(c, highlight=hl.group(0) if hl else None))
        notes = []
        for c in part:
            notes.append(_note(c))
            notes.extend(_context_notes(model, c))
        n = len(fnd) // fps + (1 if len(fnd) % fps else 0)
        title = _t("findings", lang) + (f" ({i // fps + 1}/{n})" if n > 1 else "")
        add("findings", title, bullets=bl, notes=notes,
            layout="bignumbers" if any(b["highlight"] for b in bl) else "list")
    # Charts / tables: only real table data.
    for t in content.get("tables") or []:
        if t["numeric_columns"]:
            ci = t["numeric_columns"][0]
            labels, values = [], []
            for r in t["rows"][:12]:
                v = _first_number(r[ci]) if ci < len(r) else None
                if v is not None and r and r[0].strip():
                    labels.append(r[0].strip()[:40])
                    values.append(v)
            if len(values) >= 2:
                series = [{"name": t["header"][ci] if ci < len(t["header"]) else "", "values": values}]
                for cj in t["numeric_columns"][1:3]:
                    vals = [_first_number(r[cj]) if cj < len(r) else None for r in t["rows"][:12] if r and r[0].strip()]
                    if len(vals) == len(values) and all(v is not None for v in vals):
                        series.append({"name": t["header"][cj] if cj < len(t["header"]) else "", "values": vals})
                visual = {"type": "bar", "labels": labels, "series": series, "caption": t["caption"],
                          "source": t["source"], "table": {"header": t["header"], "rows": t["rows"][:12]}}
                add("chart", f"{_t('data', lang)}: {t['caption']}", layout="chart", visual=visual,
                    notes=[{"text": " | ".join(t["header"]), "sources": [t["source"]]}]
                          + [{"text": " | ".join(r), "sources": []} for r in t["rows"][:25]])
                continue
        if t["rows"]:
            add("table", f"{_t('table', lang)}: {t['caption']}", layout="table",
                visual={"type": "table", "header": t["header"][:6], "rows": [r[:6] for r in t["rows"][:8]],
                        "caption": t["caption"], "source": t["source"]},
                notes=[{"text": " | ".join(r), "sources": []} for r in t["rows"][8:25]])
    # Concept map
    rels = [r for r in content.get("relations") or [] if r.get("a") and r.get("b")]
    if len(rels) >= 2:
        nodes = list(dict.fromkeys(x for r in rels for x in (r["a"], r["b"])))  # edge endpoints adjacent on the circle
        add("concept_map", _t("concept_map", lang), layout="map",
            visual={"type": "map", "nodes": nodes,
                    "edges": [{"a": r["a"], "b": r["b"], "label": r["relation"], "sources": r["sources"]} for r in rels]},
            notes=[_note(r) for r in rels])
    # Limitations / practical / conclusion
    if content.get("limitations"):
        add("limitations", _t("limitations", lang), bullets=[_bullet(c) for c in content["limitations"][:4]],
            notes=[_note(c) for c in content["limitations"]])
    else:
        add("limitations", _t("limitations", lang),
            bullets=[{"text": content.get("limitations_message", ""), "full": "", "kind": "not_found", "sources": []}])
    if content.get("practical"):
        add("practical", _t("practical", lang), bullets=[_bullet(c) for c in content["practical"][:4]],
            notes=[_note(c) for c in content["practical"]])
    if content.get("conclusion"):
        add("conclusion", _t("conclusion", lang), bullets=[_bullet(c) for c in content["conclusion"][:3]],
            notes=[_note(c) for c in content["conclusion"]])
    # Final: key takeaways (3-7)
    n_take = {"quick": 3, "standard": 5, "detailed": 6, "expert": 7}[level]
    kp = sorted(content.get("key_points") or [], key=lambda c: -(c.get("importance") or 0))[:n_take]
    if kp:
        add("takeaways", _t("takeaways", lang), bullets=[_bullet(c) for c in kp], notes=[_note(c) for c in kp])
    return {"title": ov["title"], "lang": lang, "slides": slides}


# ----------------------------------------------------------------------------- export

def _src_label(s: dict) -> str:
    page = s.get("page") or s.get("unit_index")
    return f"{s.get('filename')} — " + (f"p.{page}" if page else (s.get("location") or "")) + \
        (f" (printed {s['printed_page']})" if s.get("printed_page") else "")


def to_pptx(deck: dict) -> bytes:
    from pptx import Presentation
    from pptx.chart.data import CategoryChartData
    from pptx.enum.chart import XL_CHART_TYPE
    from pptx.util import Inches, Pt

    prs = Presentation()
    prs.slide_width, prs.slide_height = Inches(13.333), Inches(7.5)
    for sl in deck["slides"]:
        layout = prs.slide_layouts[0] if sl["type"] == "title" else prs.slide_layouts[5]
        slide = prs.slides.add_slide(layout)
        slide.shapes.title.text = sl["title"][:200]
        if sl["type"] == "title" and sl.get("subtitle") and len(slide.placeholders) > 1:
            slide.placeholders[1].text = sl["subtitle"]
        top = Inches(1.6)
        vis = sl.get("visual") or {}
        if vis.get("type") == "bar":
            cd = CategoryChartData()
            cd.categories = vis["labels"]
            for s in vis["series"]:
                cd.add_series(s["name"] or "value", s["values"])
            slide.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED, Inches(.7), top, Inches(11.8), Inches(5.2), cd)
        elif vis.get("type") == "table":
            rows, cols = len(vis["rows"]) + 1, max(len(vis["header"]), 1)
            tbl = slide.shapes.add_table(rows, cols, Inches(.5), top, Inches(12.3), Inches(.4) * rows).table
            for j, h in enumerate(vis["header"][:cols]):
                tbl.cell(0, j).text = h
            for i, r in enumerate(vis["rows"], start=1):
                for j in range(cols):
                    tbl.cell(i, j).text = r[j] if j < len(r) else ""
        elif sl["type"] != "title":
            box = slide.shapes.add_textbox(Inches(.7), top, Inches(11.9), Inches(5.4)).text_frame
            box.word_wrap = True
            items = sl["bullets"]
            if not items and vis.get("type") == "flow":
                items = [{"text": f"{n['label']} → {n['text']}"} for n in vis["nodes"]]
            elif not items and vis.get("type") == "map":
                items = [{"text": f"{e['a']} —({e['label']})→ {e['b']}"} for e in vis["edges"]]
            for k, b in enumerate(items):
                p = box.paragraphs[0] if k == 0 else box.add_paragraph()
                label = f"{b['label']}: " if b.get("label") else ""
                p.text = f"• {label}{b['text']}"
                p.font.size = Pt(18)
        notes = []
        for n in sl["notes"]:
            label = f"{n['label']}: " if n.get("label") else ""
            refs = "; ".join(_src_label(s) for s in n.get("sources", []))
            notes.append(f"{label}{n['text']}" + (f"\n   Source → {refs}" if refs else ""))
        slide.notes_slide.notes_text_frame.text = "\n\n".join(notes)[:20000]
    buf = io.BytesIO()
    prs.save(buf)
    return buf.getvalue()
