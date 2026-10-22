"""Client (trainee) files: storage, field extraction, safety screen and analysis.

Principles:
* Original client data is stored as provided and never overwritten by inferences.
* Every fact shown carries its source (manual entry or file + line).
* Missing information is listed explicitly — nothing is assumed.
* Red-flag findings trigger a referral note, never a diagnosis or treatment.
* Each client's data lives in its own folder and rows keyed by client_id.
"""
from __future__ import annotations

import json
import re
import shutil
import time
from pathlib import Path

from . import db
from .config import data_dir, get_settings
from .extract import ExtractionError, extract
from .ingest import safe_filename
from .textutil import fold

# key, ar label, en label, required-for-program, label regex
FIELDS = [
    ("name", "الاسم", "Name", False, r"name|الاسم"),
    ("age", "العمر", "Age", False, r"age|العمر|السن"),
    ("sex", "الجنس", "Sex", False, r"sex|gender|الجنس"),
    ("height", "الطول", "Height", False, r"height|الطول"),
    ("body_weight", "وزن الجسم", "Body weight", False, r"body ?weight|weight|الوزن|وزن الجسم"),
    ("goal", "الهدف التدريبي", "Training goal", True, r"goals?|objectives?|الهدف|الأهداف|الهدف التدريبي"),
    ("experience", "الخبرة التدريبية", "Training experience", True,
     r"training experience|experience|training age|الخبرة|الخبرة التدريبية"),
    ("days_available", "الأيام المتاحة أسبوعيًا", "Days available per week", True,
     r"days available|available days|training days|days per week|availability|الأيام المتاحة|أيام التدريب|عدد الأيام"),
    ("session_duration", "مدة الحصة المتاحة", "Session duration", False,
     r"session duration|session length|time per session|time available|مدة الحصة|الوقت المتاح"),
    ("equipment", "المعدات المتوفرة", "Available equipment", True, r"equipment|المعدات|الأدوات"),
    ("injuries", "الإصابات السابقة/الحالية", "Past/current injuries", True, r"injur(y|ies)|الإصابات|إصابات|الاصابات"),
    ("medical", "الحالة الصحية/الطبية", "Medical conditions", True,
     r"medical( conditions| history)?|health( conditions)?|conditions|الحالة الصحية|الحالة الطبية|أمراض|الأمراض"),
    ("medications", "الأدوية", "Medications", False, r"medications?|medicines?|الأدوية"),
    ("movement_limits", "القيود الحركية", "Movement restrictions", False,
     r"movement (restrictions|limitations)|restrictions|limitations|القيود الحركية|قيود"),
    ("current_program", "البرنامج الحالي", "Current program", False, r"current (program|programme|routine)|البرنامج الحالي"),
    ("adherence", "الالتزام والحضور", "Adherence / attendance", False, r"adherence|attendance|compliance|الالتزام|الحضور"),
    ("sleep", "النوم", "Sleep", False, r"sleep|النوم"),
    ("stress", "الإجهاد/الضغط", "Stress", False, r"stress|الإجهاد|الضغط النفسي|التوتر"),
    ("recovery", "التعافي", "Recovery", False, r"recovery|التعافي"),
    ("nutrition", "التغذية", "Nutrition", False, r"nutrition|diet|التغذية|النظام الغذائي"),
    ("preferences", "التفضيلات", "Preferences", False, r"preferences?|likes|التفضيلات"),
    ("measurements", "القياسات", "Measurements", False, r"measurements?|body composition|القياسات"),
    ("assessments", "نتائج التقييم/الفحوصات", "Assessment results", False, r"assessments?|tests?|screening|التقييم|الفحوصات"),
    ("progress", "سجل التقدم", "Progress log", False, r"progress|التقدم"),
]
FIELD_INDEX = {f[0]: f for f in FIELDS}
REQUIRED = [f[0] for f in FIELDS if f[3]]

QUESTIONS = {
    "goal": ("ما الهدف التدريبي الأساسي للمتدرب؟", "What is the client's primary training goal?"),
    "experience": ("ما مدة ونوع خبرته التدريبية (مثلًا: سنوات تدريب المقاومة)؟", "How long and what type of training experience (e.g. years of resistance training)?"),
    "days_available": ("كم يومًا في الأسبوع يستطيع التدريب؟", "How many days per week can the client train?"),
    "equipment": ("ما المعدات المتوفرة له (نادي كامل، منزل، أوزان حرة...)؟", "What equipment is available (full gym, home, free weights...)?"),
    "injuries": ("هل لديه إصابات سابقة أو حالية؟ (اكتب «لا يوجد» إن لم توجد)", "Any past or current injuries? (write 'none' if none)"),
    "medical": ("هل لديه حالات صحية أو قيود طبية أو أدوية؟ (اكتب «لا يوجد» إن لم توجد)", "Any medical conditions, medical restrictions or medications? ('none' if none)"),
    "session_duration": ("كم دقيقة متاحة لكل حصة؟", "How many minutes are available per session?"),
    "sleep": ("كم ساعة ينام عادةً وما جودة نومه؟", "Typical sleep duration and quality?"),
    "current_program": ("ما البرنامج الذي يتبعه حاليًا؟", "What program is the client following now?"),
}

RED_FLAGS = [
    ("chest_pain", r"chest (pain|tightness)|ألم (في )?الصدر", "ألم في الصدر", "Chest pain", "physician"),
    ("dizziness", r"dizz(y|iness)|faint(ing|ed)?|syncope|blackout|دوخة|دوار|إغماء|اغماء", "دوخة/إغماء", "Dizziness/fainting", "physician"),
    ("breathless", r"shortness of breath|breathless(ness)?|ضيق (في )?(التنفس|النفس)", "ضيق تنفس", "Shortness of breath", "physician"),
    ("cardiac", r"heart (condition|disease|problem|attack)|arrhythmia|palpitation|القلب|خفقان", "حالة قلبية", "Cardiac condition", "physician"),
    ("blood_pressure", r"(high|uncontrolled) blood pressure|hypertension|ضغط الدم|ارتفاع الضغط", "ضغط الدم", "Blood pressure", "physician"),
    ("diabetes", r"diabet(es|ic)|السكري|سكر الدم", "السكري", "Diabetes", "physician"),
    ("pregnancy", r"pregnan(t|cy)|postpartum|حامل|أثناء الحمل|بعد الولادة|الولادة", "حمل/ما بعد الولادة", "Pregnancy/postpartum", "physician"),
    ("surgery", r"\bsurgery\b|\boperation\b|\bpost-?op\b|عملية جراحية|جراحة", "جراحة حديثة/سابقة", "Recent/previous surgery", "physician"),
    ("neuro", r"numbness|tingling|radiating pain|sciatica|تنميل|خدر|ألم ممتد|عرق النسا", "أعراض عصبية", "Neurological symptoms", "physician or physiotherapist"),
    ("acute_pain", r"\b(sharp|severe|acute|persistent|worsening) pain\b|pain (during|when|while)|ألم حاد|ألم شديد|ألم مستمر|ألم أثناء", "ألم حاد/مستمر", "Acute/persistent pain", "physiotherapist or physician"),
    ("injury_active", r"(current|recent|ongoing) injur|fracture|\btorn\b|\btear\b|sprain|dislocat|كسر|تمزق|التواء|خلع|إصابة حالية", "إصابة حالية", "Current injury", "physiotherapist or physician"),
    ("concussion", r"concussion|head injury|ارتجاج", "ارتجاج/إصابة رأس", "Concussion/head injury", "physician"),
    ("eating", r"eating disorder|anorexia|bulimia|اضطراب (في )?الأكل", "اضطراب الأكل", "Eating disorder", "physician / qualified specialist"),
    ("medication", r"medications?|insulin|beta[- ]blocker|anticoagulant|أدوية|دواء|إنسولين", "أدوية", "Medication use", "physician (to confirm exercise considerations)"),
    ("pain_general", r"\bpain\b|\bache\b|ألم|أوجاع|وجع", "ألم مذكور", "Pain reported", "physiotherapist or physician"),
]
NEGATION = re.compile(r"(\bno\b|\bnone\b|\bdenies\b|\bwithout\b|\bnot\b|\bnever\b|لا يوجد|لا توجد|بدون|لا|ليس|ينفي)[^.\n]{0,25}$", re.I)
NONE_VALUE = re.compile(r"^\s*(none( reported)?|no|nil|n/?a|لا يوجد|لا توجد|لا|بدون|ليس لديه|ليس لديها)\s*\.?\s*$", re.I)


def client_dir(client_id: str) -> Path:
    d = data_dir() / "clients" / client_id
    d.mkdir(parents=True, exist_ok=True)
    return d


# ------------------------------------------------------------------ CRUD

def create_client(name: str, profile: dict | None = None, notes: str = "") -> dict:
    cid = db.new_id()
    now = time.time()
    profile = {k: v for k, v in (profile or {}).items() if k in FIELD_INDEX and str(v).strip()}
    with db.session() as conn:
        conn.execute("INSERT INTO clients(id,name,profile,notes,created_at,updated_at) VALUES(?,?,?,?,?,?)",
                     (cid, name.strip()[:120] or "client", json.dumps(profile, ensure_ascii=False), notes, now, now))
    client_dir(cid)
    return get_client(cid)


def update_client(client_id: str, name: str | None = None, profile: dict | None = None, notes: str | None = None) -> dict:
    with db.session() as conn:
        row = conn.execute("SELECT * FROM clients WHERE id=?", (client_id,)).fetchone()
        if not row:
            raise KeyError(client_id)
        if name is not None:
            conn.execute("UPDATE clients SET name=? WHERE id=?", (name.strip()[:120], client_id))
        if profile is not None:
            clean = {k: v for k, v in profile.items() if k in FIELD_INDEX and str(v).strip()}
            conn.execute("UPDATE clients SET profile=? WHERE id=?", (json.dumps(clean, ensure_ascii=False), client_id))
        if notes is not None:
            conn.execute("UPDATE clients SET notes=? WHERE id=?", (notes, client_id))
        conn.execute("UPDATE clients SET updated_at=? WHERE id=?", (time.time(), client_id))
    return get_client(client_id)


def get_client(client_id: str) -> dict | None:
    with db.session() as conn:
        c = db.row_to_dict(conn.execute("SELECT * FROM clients WHERE id=?", (client_id,)).fetchone())
        if not c:
            return None
        c["files"] = [{k: v for k, v in db.row_to_dict(r).items() if k not in ("text",)}
                      for r in conn.execute("SELECT * FROM client_files WHERE client_id=? ORDER BY created_at", (client_id,))]
        c["programs"] = [dict(r) for r in conn.execute(
            "SELECT id, lineage_id, version, title, created_at FROM programs WHERE client_id=? ORDER BY created_at DESC",
            (client_id,))]
    if not isinstance(c.get("profile"), dict):
        c["profile"] = {}
    return c


def list_clients() -> list[dict]:
    with db.session() as conn:
        return [dict(r) for r in conn.execute("SELECT id, name, created_at, updated_at FROM clients ORDER BY name")]


def delete_client(client_id: str) -> bool:
    with db.session() as conn:
        n = conn.execute("DELETE FROM clients WHERE id=?", (client_id,)).rowcount
    shutil.rmtree(data_dir() / "clients" / client_id, ignore_errors=True)
    return bool(n)


def add_client_file(client_id: str, filename: str, data: bytes) -> dict:
    if not get_client(client_id):
        raise KeyError(client_id)
    filename = safe_filename(filename)
    fid = db.new_id()
    folder = client_dir(client_id) / fid
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / filename
    path.write_bytes(data)
    status, text = "processed", ""
    try:
        res = extract(path)
        parts = []
        for u in res.units:
            if u.status in ("ok", "ocr") and u.text:
                parts.append(u.text)
        text = "\n\n".join(parts)
        if res.pages_failed:
            status = "needs_review"
        if not text.strip():
            status = "failed"
    except ExtractionError as exc:
        status, text = "failed", ""
        extracted = {"error": str(exc)}
    else:
        extracted = parse_client_text(text, filename)
    with db.session() as conn:
        conn.execute("INSERT INTO client_files(id,client_id,filename,stored_path,text,extracted,status,created_at)"
                     " VALUES(?,?,?,?,?,?,?,?)",
                     (fid, client_id, filename, str(path.relative_to(data_dir())), text,
                      json.dumps(extracted, ensure_ascii=False), status, time.time()))
    return {"id": fid, "filename": filename, "status": status, "extracted": extracted}


def delete_client_file(client_id: str, file_id: str) -> bool:
    with db.session() as conn:
        n = conn.execute("DELETE FROM client_files WHERE id=? AND client_id=?", (file_id, client_id)).rowcount
    shutil.rmtree(client_dir(client_id) / file_id, ignore_errors=True)
    return bool(n)


# ------------------------------------------------------------------ parsing

_LABEL_LINE = re.compile(r"^\s*[-*•]?\s*([^:：\n]{2,60})\s*[:：]\s*(.+?)\s*$")
_EXERCISE = re.compile(
    r"^\s*[-*•]?\s*(?P<ex>[A-Za-zء-ي][\wء-ي \-/()]{1,40}?)\s*[:\-–]\s*(?P<sets>\d+)\s*(sets?|مجموعات|×)?\s*[x×*]\s*"
    r"(?P<reps>\d+(?:\s*[-–]\s*\d+)?)\s*(reps?|تكرار(ات)?)?(?:\s*(?:@|at|بوزن)\s*(?P<load>\d+(?:\.\d+)?)\s*(?P<unit>kg|lb|lbs|كجم|كغ)?)?"
    r"(?:.*?\b(?P<scale>RIR|RPE)\s*(?P<eff>\d+(?:\.\d+)?))?", re.I)


def _match_field(label: str) -> str | None:
    lab = fold(label).strip()
    best = None
    for key, _, _, _, rx in FIELDS:
        if re.fullmatch(f"(?:{rx})", lab, re.I) or re.fullmatch(f"(?:{rx})", label.strip(), re.I):
            return key
        if best is None and re.search(f"(?:{rx})", label.strip(), re.I) and len(label) < 30:
            best = key
    return best


def parse_client_text(text: str, source: str) -> dict:
    """Extract labelled fields and training-log lines. Unlabelled text is kept as notes."""
    fields: dict[str, dict] = {}
    log: list[dict] = []
    for n, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        m = _EXERCISE.match(line)
        if m:
            log.append({"exercise": m.group("ex").strip(), "sets": int(m.group("sets")), "reps": m.group("reps").replace(" ", ""),
                        "load": m.group("load"), "unit": m.group("unit"), "effort_scale": (m.group("scale") or "").upper() or None,
                        "effort": m.group("eff"), "source": f"{source} (line {n})"})
            continue
        m = _LABEL_LINE.match(line)
        if m:
            key = _match_field(m.group(1))
            if key and key not in fields:
                fields[key] = {"value": m.group(2).strip(), "source": f"{source} (line {n})"}
        # CSV-style rows from xlsx/csv extraction: "exercise: Squat; sets: 3; reps: 5; ..."
        if ";" in line and re.search(r"exercise\s*:", line, re.I):
            kv = dict((a.strip().lower(), b.strip()) for a, _, b in (p.partition(":") for p in line.split(";")) if b)
            log.append({"exercise": kv.get("exercise"), "sets": kv.get("sets"), "reps": kv.get("reps"),
                        "load": kv.get("weight") or kv.get("load"), "unit": None,
                        "effort_scale": "RIR" if "rir" in kv else ("RPE" if "rpe" in kv else None),
                        "effort": kv.get("rir") or kv.get("rpe"), "date": kv.get("date"), "source": f"{source} (line {n})"})
    return {"fields": fields, "training_log": log}


# ------------------------------------------------------------------ analysis

def _facts(client: dict) -> tuple[dict[str, dict], list[dict], str]:
    """Merge manual profile and file-extracted fields. Manual entries win; both are kept."""
    facts: dict[str, dict] = {}
    for k, v in (client.get("profile") or {}).items():
        facts[k] = {"value": str(v), "source": "manual entry", "alternatives": []}
    log, texts = [], []
    with db.session() as conn:
        rows = conn.execute("SELECT filename, text, extracted FROM client_files WHERE client_id=? ORDER BY created_at",
                            (client["id"],)).fetchall()
    for r in rows:
        texts.append(r["text"] or "")
        ex = json.loads(r["extracted"] or "{}")
        for k, v in (ex.get("fields") or {}).items():
            if k in facts:
                if v["value"] != facts[k]["value"]:
                    facts[k]["alternatives"].append(v)
            else:
                facts[k] = {**v, "alternatives": []}
        log.extend(ex.get("training_log") or [])
    all_text = "\n".join(texts + [f"{k}: {v}" for k, v in (client.get("profile") or {}).items()] + [client.get("notes") or ""])
    return facts, log, all_text


def screen_red_flags(text: str) -> list[dict]:
    found, seen = [], set()
    for line in text.splitlines():
        m_lab = _LABEL_LINE.match(line)
        if m_lab and NONE_VALUE.match(m_lab.group(2)):
            continue  # e.g. "Injuries: none"
        for key, rx, ar, en, referral in RED_FLAGS:
            for m in re.finditer(rx, line, re.I):
                before = line[max(0, m.start() - 30):m.start()]
                if NEGATION.search(before):
                    continue
                if key == "pain_general" and ({"chest_pain", "acute_pain", "neuro"} & seen):
                    continue
                if key in seen:
                    continue
                seen.add(key)
                found.append({"flag": key, "label_ar": ar, "label_en": en, "excerpt": line.strip()[:200],
                              "referral": referral})
                break
    return found


def experience_level(value: str | None) -> str | None:
    """Classify only when the text states it; returns None when unclear."""
    if not value:
        return None
    v = fold(value)
    if re.search(r"\b(none|no experience|beginner|novice|never)\b|مبتدئ|لا يوجد|بدون خبرة", v):
        return "untrained"
    m = re.search(r"(\d+(?:\.\d+)?)\s*(years?|yrs?|سنوات|سنة|سنه|عام|أعوام)", v)
    if m:
        return "trained" if float(m.group(1)) >= 1 else "untrained"
    m = re.search(r"(\d+)\s*(months?|أشهر|شهور|شهر)", v)
    if m:
        return "trained" if int(m.group(1)) >= 12 else "untrained"
    if re.search(r"advanced|intermediate|trained|متقدم|متوسط", v):
        return "trained"
    return None


def first_int(value: str | None) -> int | None:
    if not value:
        return None
    v = value.translate(str.maketrans("٠١٢٣٤٥٦٧٨٩", "0123456789"))
    m = re.search(r"\d+", v)
    return int(m.group()) if m else None


DISCLAIMER = {
    "ar": "هذا التحليل أداة دعم لقرارك المهني وليس تقييمًا طبيًا أو تشخيصًا. أي ألم أو إصابة أو حالة صحية تتطلب تقييم مختص مؤهل قبل التدريب.",
    "en": "This analysis supports your professional judgement; it is not a medical assessment or diagnosis. Any pain, injury or health condition requires assessment by a qualified professional before training.",
}


def analyze(client_id: str, lang: str = "ar", evidence: bool = True) -> dict:
    from .rag import ask

    lang = "en" if lang == "en" else "ar"
    client = get_client(client_id)
    if not client:
        raise KeyError(client_id)
    facts, log, all_text = _facts(client)
    li = 1 if lang == "ar" else 2
    fact_list = [{"field": k, "label": FIELD_INDEX[k][li], "value": v["value"], "source": v["source"],
                  "conflicting_values": v.get("alternatives") or []} for k, v in facts.items() if k in FIELD_INDEX]
    missing = []
    for key, ar, en, req, _ in FIELDS:
        if key not in facts and (req or key in QUESTIONS):
            q = QUESTIONS.get(key)
            missing.append({"field": key, "label": ar if lang == "ar" else en, "required_for_program": req,
                            "question": (q[0] if lang == "ar" else q[1]) if q else None})
    flags = screen_red_flags(all_text)
    level = experience_level(facts.get("experience", {}).get("value"))
    days = first_int(facts.get("days_available", {}).get("value"))

    priorities = []
    settings = get_settings()

    def add_priority(title_ar, title_en, basis_fields, query):
        item = {"title": title_ar if lang == "ar" else title_en, "basis": "inference",
                "based_on_facts": basis_fields, "evidence": None}
        if evidence and query:
            res = ask(query, lang=lang, settings=settings, use_llm=_client_llm_allowed(settings), log_query=False)
            item["evidence"] = {"status": res["status"], "query": query,
                                "claims": res["claims"][:4], "citations": res["citations"],
                                "conflicts": res["conflicts"], "message": res.get("message")}
        priorities.append(item)

    goal = facts.get("goal", {}).get("value")
    if goal:
        add_priority(f"البرمجة نحو الهدف المذكور: {goal}", f"Programme toward the stated goal: {goal}", ["goal"],
                     f"{goal} training")
    if flags:
        priorities.insert(0, {"title": "إحالة/تقييم مختص قبل التدريب للعناصر المذكورة في التنبيهات" if lang == "ar"
                              else "Referral / professional assessment before training for the flagged items",
                              "basis": "client_file", "based_on_facts": [f["flag"] for f in flags], "evidence": None})
    if "sleep" in facts:
        add_priority("مراجعة النوم والتعافي (بيانات النوم مذكورة في الملف)", "Review sleep & recovery (sleep data provided)",
                     ["sleep"], "sleep recovery training")
    if "adherence" in facts:
        add_priority("الالتزام والحضور (بيانات مذكورة في الملف)", "Adherence / attendance (data provided)", ["adherence"],
                     "adherence training program")
    if "stress" in facts:
        add_priority("الإجهاد (بيانات مذكورة في الملف)", "Stress (data provided)", ["stress"], "stress recovery fatigue")

    missing_required = [m for m in missing if m["required_for_program"]]
    readiness = "ready"
    if missing_required:
        readiness = "needs_info"
    if flags:
        readiness = "needs_medical_clearance" if readiness == "ready" else "needs_info_and_clearance"
    result = {
        "client": {"id": client["id"], "name": client["name"]},
        "facts": fact_list, "training_log": log, "missing": missing, "red_flags": flags,
        "derived": {"experience_level": level, "days_available": days,
                    "note": "قيم مشتقة آليًا من نص الملف — تحقق منها" if lang == "ar" else "Values derived automatically from the text — verify"},
        "priorities": priorities, "readiness": readiness, "disclaimer": DISCLAIMER[lang],
        "labels": {"facts": "حقائق من ملف المتدرب" if lang == "ar" else "Facts from the client file",
                   "inference": "استنتاج" if lang == "ar" else "Inference"},
    }
    with db.session() as conn:
        aid = db.new_id()
        conn.execute("INSERT INTO client_analyses(id,client_id,created_at,result) VALUES(?,?,?,?)",
                     (aid, client_id, time.time(), json.dumps(result, ensure_ascii=False)))
    result["id"] = aid
    return result


def _client_llm_allowed(settings) -> bool:
    from .llm import PrivacyBlocked, LLMUnavailable, get_llm
    try:
        return get_llm(settings, "client") is not None
    except (PrivacyBlocked, LLMUnavailable):
        return False
