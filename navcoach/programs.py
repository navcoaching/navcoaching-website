"""Evidence-linked training program proposals with versioning.

For every program element the system retrieves passages from the library,
extracts values the sources actually state (e.g. "10 sets per week") with
their citations, checks how well the studied population matches the client,
and proposes a value only when it is backed by a cited source and compatible
with the client's stated constraints. Anything else is labelled
"coach decision" or "no evidence in library".
"""
from __future__ import annotations

import copy
import json
import re
import time

from . import db
from .clients import DISCLAIMER, analyze, first_int, get_client
from .config import get_settings
from .rag import ask

# Numbers may be written as words in papers ("three days per week").
WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
         "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30}
N = r"(\d+|" + "|".join(WORDS) + r")"

ELEMENTS = [
    # key, ar, en, query template, value regex
    ("frequency", "عدد أيام التدريب أسبوعيًا", "Training days per week",
     "{goal} training frequency days per week sessions",
     r"\b" + N + r"(?:\s*(?:-|–|to|or)\s*" + N + r")?\s*(?:training\s+)?(?:days|sessions|times)\s*(?:per|a|/|each)\s*week"),
    ("split", "تقسيم الحصص", "Session split", "{goal} training split full body upper lower body part", None),
    ("exercise_selection", "اختيار التمارين", "Exercise selection", "{goal} exercise selection exercises", None),
    ("weekly_volume", "الحجم الأسبوعي (مجموعات لكل عضلة)", "Weekly volume (sets per muscle)",
     "{goal} weekly training volume sets per muscle group per week",
     r"\b" + N + r"(?:\s*(?:-|–|to|or|,)\s*" + N + r")?(?:\s*(?:,|or)\s*" + N + r")?\s*(?:weekly\s+sets|sets\s*(?:per\s+(?:muscle(?:\s+group)?\s+)?(?:per\s+)?week|weekly|a week))"),
    ("reps", "التكرارات لكل مجموعة", "Repetitions per set", "{goal} repetitions per set",
     r"(\d+)\s*(?:-|–|to)\s*(\d+)\s*(?:repetitions|reps)(?!\s+in reserve)"),
    ("effort", "الشدة / قرب الفشل (RIR/RPE)", "Effort / proximity to failure (RIR/RPE)",
     "{goal} repetitions in reserve RIR RPE failure",
     r"(\d+)(?:\s*(?:-|–|to)\s*(\d+))?\s*(?:repetitions in reserve|RIR\b)|RPE\s*(\d+(?:\.\d+)?)"),
    ("rest", "الراحة بين المجموعات", "Rest between sets", "rest interval between sets minutes {goal}",
     r"(\d+(?:\.\d+)?)(?:\s*(?:-|–|to)\s*(\d+(?:\.\d+)?))?\s*(minutes?|min|seconds?|s\b)\s*(?:of\s+)?rest"),
    ("progression", "التدرج في الحمل/التكرارات", "Progression of load/reps",
     "progression progressive overload increase load repetitions {goal}", None),
    ("monitoring", "متابعة الأداء والتعافي ومعايير التعديل", "Monitoring performance/recovery & adjustment criteria",
     "monitoring fatigue recovery performance adjust training", None),
]

POPULATION = [
    ("untrained", re.compile(r"\buntrained\b|\bnovice|\bbeginner|previously untrained|sedentary", re.I)),
    ("trained", re.compile(r"\b(resistance-trained|trained|experienced|athletes?)\b", re.I)),
    ("women", re.compile(r"\b(women|females?)\b", re.I)),
    ("men", re.compile(r"\b(men|males?)\b", re.I)),
    ("older", re.compile(r"\b(older|elderly|aged (6|7|8)\d)\b", re.I)),
]

NO_EVIDENCE = {"ar": "لا يوجد دليل في مكتبتك لهذا العنصر — لم يُحدَّد", "en": "No evidence in your library for this element — not specified"}
COACH = {"ar": "قرار المدرب (لا تحدد الأدلة قيمة رقمية)", "en": "Coach decision (the evidence does not state a numeric value)"}


def _population(text: str) -> set[str]:
    found = {k for k, rx in POPULATION if rx.search(text)}
    if "untrained" in found:
        # "untrained" contains "trained": keep the specific one when only that matches
        if not re.search(r"(?<!un)trained", text, re.I):
            found.discard("trained")
    return found


def _client_population(facts: dict, level: str | None) -> set[str]:
    out = set()
    if level:
        out.add(level)
    sex = (facts.get("sex") or "").lower()
    if re.search(r"\b(female|woman|f)\b|أنثى|انثى|امرأة", sex):
        out.add("women")
    elif re.search(r"\b(male|man|m)\b|ذكر|رجل", sex):
        out.add("men")
    age = first_int(facts.get("age"))
    if age and age >= 60:
        out.add("older")
    return out


def _applicability(evidence_pop: set[str], client_pop: set[str], lang: str) -> list[str]:
    notes = []
    pairs = [("trained", "untrained"), ("men", "women")]
    for a, b in pairs:
        for x, y in ((a, b), (b, a)):
            if x in evidence_pop and y not in evidence_pop and y in client_pop:
                notes.append(f"الدليل من فئة «{x}» بينما المتدرب «{y}» — قابلية تطبيق محدودة" if lang == "ar"
                             else f"Evidence population is '{x}' while the client is '{y}' — limited applicability")
    if "older" in evidence_pop and "older" not in client_pop:
        notes.append("الدليل من كبار السن" if lang == "ar" else "Evidence is from older adults")
    if not evidence_pop:
        notes.append("الفئة المدروسة غير مذكورة في المقطع" if lang == "ar" else "The studied population is not stated in the passage")
    return notes


def _extract_values(rx: str, text: str) -> list[str]:
    vals = []
    for m in re.finditer(rx, text, re.I):
        vals.append(re.sub(r"\s+", " ", m.group(0)).strip())
    return vals


def _nums(v: str) -> list[float]:
    out = []
    for x in re.findall(r"\d+(?:\.\d+)?|[a-z]+", v.lower()):
        if x in WORDS:
            out.append(float(WORDS[x]))
        elif x[0].isdigit():
            out.append(float(x))
    return out


def build_program(client_id: str, lang: str = "ar", medical_clearance_confirmed: bool = False,
                  title: str | None = None) -> dict:
    lang = "en" if lang == "en" else "ar"
    client = get_client(client_id)
    if not client:
        raise KeyError(client_id)
    analysis = analyze(client_id, lang=lang, evidence=False)
    facts = {f["field"]: f["value"] for f in analysis["facts"]}
    level = analysis["derived"]["experience_level"]
    days = analysis["derived"]["days_available"]
    missing_required = [m for m in analysis["missing"] if m["required_for_program"]]
    base = {"client_id": client_id, "client_name": client["name"], "analysis_id": analysis["id"],
            "missing": analysis["missing"], "red_flags": analysis["red_flags"], "disclaimer": DISCLAIMER[lang]}
    if missing_required:
        return {**base, "status": "needs_info",
                "message": ("البيانات غير كافية لاقتراح برنامج مفصل. أجب عن الأسئلة التالية أولًا؛ يمكن الاطلاع على التحليل المبدئي في صفحة التحليل."
                            if lang == "ar" else
                            "Not enough information for a detailed program. Please answer the questions below first; a preliminary analysis is available on the analysis page."),
                "questions": [m["question"] for m in missing_required if m["question"]]}
    if analysis["red_flags"] and not medical_clearance_confirmed:
        return {**base, "status": "needs_medical_clearance",
                "message": ("ظهرت في بيانات المتدرب مؤشرات تستدعي تقييمًا مختصًا قبل وضع برنامج. لن يُقترح برنامج حتى تؤكد وجود تصريح/تقييم مختص، ولن يتجاوز البرنامج أي قيود طبية موثقة."
                            if lang == "ar" else
                            "The client data contains items that need professional assessment before programming. No program will be proposed until you confirm clearance/assessment, and the program will not override documented medical restrictions.")}

    settings = get_settings()
    from .clients import _client_llm_allowed
    use_llm = _client_llm_allowed(settings)
    goal = facts.get("goal", "")
    client_pop = _client_population(facts, level)
    elements, citations = [], {}
    li = 1 if lang == "ar" else 2
    for key, ar, en, qtpl, rx in ELEMENTS:
        query = qtpl.format(goal=goal).strip()
        res = ask(query, lang=lang, settings=settings, use_llm=use_llm, log_query=False)
        el = {"key": key, "label": ar if lang == "ar" else en, "query": query, "evidence_status": res["status"],
              "client_constraint": None, "evidence_values": [], "proposed": None, "basis": None,
              "applicability": [], "claims": [], "conflicts": res.get("conflicts", []), "citations": [],
              "coach_notes": ""}
        if key == "frequency" and days:
            el["client_constraint"] = (f"الأيام المتاحة: {days} (من ملف المتدرب)" if lang == "ar"
                                       else f"Days available: {days} (from client file)")
        if key == "exercise_selection" and facts.get("equipment"):
            el["client_constraint"] = (f"المعدات: {facts['equipment']} (من ملف المتدرب)" if lang == "ar"
                                       else f"Equipment: {facts['equipment']} (from client file)")
        if key == "split" and facts.get("session_duration"):
            el["client_constraint"] = (f"مدة الحصة: {facts['session_duration']}" if lang == "ar"
                                       else f"Session duration: {facts['session_duration']}")
        if res["status"] != "answered":
            el["proposed"], el["basis"] = NO_EVIDENCE[lang], "no_evidence"
            elements.append(el)
            continue
        prefix = key + "-"
        local_map = {}
        for eid, c in res["citations"].items():
            gid = prefix + eid
            local_map[eid] = gid
            citations[gid] = {**c, "id": gid}
        for c in res["claims"]:
            el["claims"].append({**c, "citations": [local_map[e] for e in c["citations"]],
                                 "quotes": {local_map[e]: q for e, q in c["quotes"].items()}})
        for cf in el["conflicts"]:
            for p in cf["positions"]:
                if p.get("evidence_id"):
                    p["evidence_id"] = local_map.get(p["evidence_id"], p["evidence_id"])
        el["citations"] = sorted(local_map.values())
        pops = set()
        if rx:
            # Values are read only from verbatim quotes (claims and conflict statements).
            quoted = [(e, q) for cl in res["claims"] for e, q in cl["quotes"].items()]
            quoted += [(p["evidence_id"], p["text"]) for cf in res.get("conflicts", []) for p in cf["positions"]
                       if p.get("evidence_id") in local_map.values() and p.get("text")]
            # Also scan every sentence of the cited passages (still verbatim text).
            from .textutil import sentences as _sents
            for e, c in res.get("considered", {}).items():
                found = [(e, x) for x in _sents(c["passage"]) if re.search(rx, x, re.I)]
                if found and e not in res["citations"]:
                    res["citations"][e] = {**c, "quote": found[0][1]}
                    local_map[e] = prefix + e
                    citations[prefix + e] = {**res["citations"][e], "id": prefix + e}
                quoted += found
            seen = set()
            for eid, s in quoted:
                eid = eid if eid in res["citations"] else next((k for k, v in local_map.items() if v == eid), None)
                if eid is None:
                    continue
                c = res["citations"][eid]
                for v in _extract_values(rx, s):
                    if (v, eid) in seen or any(v == x["value"] for x in el["evidence_values"] if x["citation"] == local_map[eid]):
                        continue
                    seen.add((v, eid))
                    p = _population(c["passage"])
                    pops |= p
                    el["evidence_values"].append({"value": v, "citation": local_map[eid], "population": sorted(p),
                                                  "quote": s, "applicability": _applicability(p, client_pop, lang)})
        else:
            for eid, c in res["citations"].items():
                pops |= _population(c["passage"])
        el["citations"] = sorted(set(local_map.values()))
        el["applicability"] = sorted(set(_applicability(pops, client_pop, lang)))
        if el["evidence_values"]:
            el["basis"] = "evidence"
            el["proposed"] = _propose(key, el["evidence_values"], days, lang)
        else:
            el["basis"] = "coach_decision"
            el["proposed"] = COACH[lang]
        if el["conflicts"]:
            el["applicability"].append("المصادر متعارضة في هذا العنصر — راجع الطرفين قبل القرار" if lang == "ar"
                                       else "Sources conflict on this element — review both before deciding")
        elements.append(el)

    sessions = None
    freq = next((e for e in elements if e["key"] == "frequency"), None)
    n_sessions = first_int(freq["proposed"]) if freq and freq["basis"] == "evidence" else None
    if n_sessions and days and n_sessions <= days:
        sessions = [{"name": (f"الحصة {i + 1}" if lang == "ar" else f"Session {i + 1}"),
                     "items": [{"element": e["label"], "value": e["proposed"]}
                               for e in elements if e["key"] in ("weekly_volume", "reps", "effort", "rest")]}
                    for i in range(n_sessions)]
    current_exercises = [x for x in analysis["training_log"] if x.get("exercise")]
    content = {**base, "status": "proposed", "title": title or (f"برنامج {client['name']}" if lang == "ar" else f"{client['name']} program"),
               "goal": goal, "client_population": sorted(client_pop), "elements": elements, "sessions": sessions,
               "current_exercises_from_client_file": current_exercises, "citations": citations,
               "mode": "llm" if use_llm else "extractive",
               "medical_clearance_confirmed": medical_clearance_confirmed,
               "note": ("كل قيمة مقترحة مرتبطة باقتباس من مكتبتك. العناصر بلا دليل تُركت لقرارك ولم تُملأ بتخمين. لا يوجد برنامج واحد هو الأفضل دائمًا؛ عند تعدد القيم في المصادر تُعرض جميعها."
                        if lang == "ar" else
                        "Every proposed value is linked to a quote from your library. Elements without evidence are left for your decision and are not filled by guessing. No single program is always best; when sources give several values, all are shown.")}
    return save_program(client_id, content, change_notes=[])


def _propose(key: str, values: list[dict], days: int | None, lang: str) -> str:
    texts = [v["value"] for v in values]
    if key == "frequency":
        options = sorted({int(n) for v in texts for n in _nums(v)})
        if days:
            fitting = [n for n in options if n <= days]
            if not fitting:
                return (f"قيم المصادر ({', '.join(map(str, options))}) تتجاوز الأيام المتاحة ({days}) — قرار المدرب"
                        if lang == "ar" else f"Source values ({', '.join(map(str, options))}) exceed available days ({days}) — coach decision")
            return (f"{max(fitting)} أيام أسبوعيًا (ضمن ما تذكره المصادر ولا يتجاوز الأيام المتاحة)" if lang == "ar"
                    else f"{max(fitting)} days per week (stated in sources and within available days)")
    uniq = list(dict.fromkeys(texts))
    joined = " | ".join(uniq[:4])
    return (f"قيم مذكورة في المصادر: {joined} — اختر ضمنها حسب حالة المتدرب" if lang == "ar"
            else f"Values stated in sources: {joined} — choose within these for this client")


def save_program(client_id: str, content: dict, change_notes: list, lineage_id: str | None = None) -> dict:
    pid = db.new_id()
    with db.session() as conn:
        if lineage_id:
            v = conn.execute("SELECT MAX(version) v FROM programs WHERE lineage_id=?", (lineage_id,)).fetchone()["v"] or 0
        else:
            lineage_id, v = pid, 0
        conn.execute("INSERT INTO programs(id,client_id,lineage_id,version,title,content,change_notes,created_at)"
                     " VALUES(?,?,?,?,?,?,?,?)",
                     (pid, client_id, lineage_id, v + 1, content.get("title"), json.dumps(content, ensure_ascii=False),
                      json.dumps(change_notes, ensure_ascii=False), time.time()))
    return get_program(pid)


def get_program(pid: str) -> dict | None:
    with db.session() as conn:
        r = db.row_to_dict(conn.execute("SELECT * FROM programs WHERE id=?", (pid,)).fetchone())
        if not r:
            return None
        r["versions"] = [dict(x) for x in conn.execute(
            "SELECT id, version, created_at FROM programs WHERE lineage_id=? ORDER BY version", (r["lineage_id"],))]
    return r


def list_programs(client_id: str | None = None) -> list[dict]:
    sql = ("SELECT p.id, p.client_id, p.lineage_id, p.version, p.title, p.created_at, c.name client_name FROM programs p "
           "LEFT JOIN clients c ON c.id=p.client_id WHERE p.version = (SELECT MAX(version) FROM programs q WHERE q.lineage_id=p.lineage_id)")
    args = []
    if client_id:
        sql += " AND p.client_id=?"
        args.append(client_id)
    sql += " ORDER BY p.created_at DESC"
    with db.session() as conn:
        return [dict(r) for r in conn.execute(sql, args)]


def revise_program(pid: str, edits: list[dict], reason: str, lang: str = "ar") -> dict:
    """Create a new version. edits: [{key, proposed?, coach_notes?}]. Original versions are kept."""
    prev = get_program(pid)
    if not prev:
        raise KeyError(pid)
    if not reason or not reason.strip():
        raise ValueError("a reason for the change is required")
    content = copy.deepcopy(prev["content"])
    notes = []
    by_key = {e["key"]: e for e in content.get("elements", [])}
    for ed in edits:
        el = by_key.get(ed.get("key"))
        if not el:
            continue
        for field in ("proposed", "coach_notes"):
            if field in ed and ed[field] != el.get(field):
                notes.append({"element": el["label"], "field": field, "before": el.get(field), "after": ed[field],
                              "reason": reason.strip()})
                el[field] = ed[field]
                if field == "proposed":
                    el["basis"] = "coach_edit"
    if not notes:
        raise ValueError("no changes")
    content["status"] = "revised"
    return save_program(prev["client_id"], content, notes, lineage_id=prev["lineage_id"])


def delete_program_lineage(lineage_id: str) -> int:
    with db.session() as conn:
        return conn.execute("DELETE FROM programs WHERE lineage_id=?", (lineage_id,)).rowcount


def program_markdown(p: dict, lang: str = "ar") -> str:
    c = p["content"]
    hdr = ("| العنصر | القيمة المقترحة | الأساس | المراجع | ملاحظات التطبيق |" if lang == "ar"
           else "| Element | Proposed | Basis | References | Applicability notes |")
    lines = [f"# {c.get('title')} (v{p['version']})", "", hdr, "|---|---|---|---|---|"]
    for e in c.get("elements", []):
        refs = ", ".join(f"{c['citations'][r]['filename']} p.{c['citations'][r].get('pdf_page') or '-'}"
                         for r in e.get("citations", [])[:4] if r in c["citations"])
        lines.append(f"| {e['label']} | {e['proposed']} | {e['basis']} | {refs} | {'; '.join(e.get('applicability', []))} |")
    lines += ["", c.get("disclaimer", "")]
    return "\n".join(lines)
