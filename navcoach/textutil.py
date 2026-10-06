"""Text normalisation, tokenisation and query-concept extraction (EN + AR)."""
from __future__ import annotations

import re
import unicodedata

_ARABIC_DIACRITICS = re.compile(r"[ؐ-ًؚ-ٰٟۖ-ۭـ]")
_WORD = re.compile(r"[a-z0-9]+(?:\.[0-9]+)?|[ء-ي]+")
_LIGATURES = {"ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl"}

EN_STOP = set(
    """a an the and or of to in on for with by at from as is are was were be been being this that these those
    it its into than then there their them they we our you your i me my he she his her not no nor but if so such
    can could should would may might will shall do does did done have has had having also more most less least
    very per vs versus between among about over under after before during while which who whom whose what when
    where why how all any both each few other some only own same too just s t don now up down out off again
    further once here both either neither one two three et al i.e e.g""".split()
)
# Words that frame a question but carry no scientific concept.
EN_QUESTION_FRAME = set(
    """say says tell according file files library my document documents study studies research paper papers
    evidence evidences find found show shows available regarding concerning relation relationship best
    optimal compare comparison summarize summary explain many much use used using does do give""".split()
)
AR_STOP = set(
    """في من على إلى الى عن مع هذا هذه ذلك تلك التي الذي الذين هو هي هم ما ماذا لماذا كيف هل أو او و ثم لا لم لن
    قد كان كانت يكون تكون بين عند كل أي اي أن ان إن بعد قبل خلال حول حسب وفق وفقا وفقًا مثل أكثر اكثر أقل اقل
    عليه عليها فيه فيها به بها له لها منه منها""".split()
)
AR_QUESTION_FRAME = set(
    """تقول يقول ملفاتي ملفات ملف مكتبتي المكتبة الدراسات دراسات دراسة الدراسة الأبحاث ابحاث بحث الأدلة ادلة دليل
    أفضل افضل الأفضل الامثل الأمثل العلاقة علاقة قارن مقارنة لخص اشرح المتاحة متاحة موجودة الموجودة التي رفعتها
    كم عدد مقدار كمية الكمية انسب الأنسب المناسب مناسب المناسبة المفترض ينبغي يجب أحتاج احتاج يحتاج تحتاج تنصح تنصحين
    توصي توصية التوصية نصيحة حتى مفيد مفيدة فائدة فوائد أثر اثر تأثير تاثير وش ايش إيش شنو شو وشو يعني معلومات أعرف اعرف أريد اريد ابغى أبغى ودي ممكن""".split()
)

# Arabic → English concept glossary for cross-lingual retrieval (query expansion
# only; it never feeds an answer). Keys are normalised Arabic stems.
AR_EN_GLOSSARY: dict[str, list[str]] = {
    "تضخم": ["hypertrophy", "muscle growth"],
    "ضخامه": ["hypertrophy"],
    "عضل": ["muscle", "muscular"],
    "عضلي": ["muscle", "muscular"],
    "عضلات": ["muscle", "muscles"],
    "حجم": ["volume"],
    "تدريبي": ["training"],
    "تدريب": ["training", "exercise"],
    "تمرين": ["exercise", "training"],
    "تمارين": ["exercises", "exercise"],
    "شده": ["intensity", "load"],
    "حمل": ["load"],
    "اوزان": ["load", "weight"],
    "وزن": ["weight", "load"],
    "تكرارات": ["repetitions", "reps"],
    "تكرار": ["repetitions", "frequency"],
    "مجموعات": ["sets"],
    "مجموعه": ["set", "sets"],
    "فشل": ["failure"],
    "احتياطيه": ["reserve", "rir"],
    "احتياطي": ["reserve", "rir"],
    "راحه": ["rest"],
    "نوم": ["sleep"],
    "تعافي": ["recovery"],
    "استشفاء": ["recovery"],
    "اجهاد": ["fatigue", "stress"],
    "تعب": ["fatigue"],
    "تغذيه": ["nutrition", "diet"],
    "بروتين": ["protein"],
    "سعرات": ["calories", "energy"],
    "كربوهيدرات": ["carbohydrate"],
    "دهون": ["fat"],
    "قوه": ["strength"],
    "قدره": ["power"],
    "مرونه": ["flexibility"],
    "حركه": ["mobility", "movement"],
    "تاهيل": ["rehabilitation"],
    "اصابه": ["injury"],
    "اصابات": ["injury", "injuries"],
    "الم": ["pain"],
    "ايام": ["days", "frequency"],
    "يوم": ["day", "days"],
    "اسبوعي": ["weekly", "week"],
    "اسبوع": ["week", "weekly"],
    "اسابيع": ["weeks"],
    "تقسيم": ["split"],
    "مبتدئين": ["untrained", "novice", "beginners"],
    "مبتدئ": ["untrained", "novice"],
    "متقدمين": ["trained", "advanced"],
    "مدربين": ["trained"],
    "نساء": ["women", "female"],
    "رجال": ["men", "male"],
    "كبار": ["older", "elderly"],
    "السن": ["older", "aged"],
    "قيود": ["limitations"],
    "منهجيه": ["methodological", "methods"],
    "عينه": ["sample", "participants"],
    "مده": ["duration", "weeks"],
    "نتائج": ["results", "findings"],
    "كرياتين": ["creatine"],
    "كافيين": ["caffeine"],
    "سرعه": ["speed", "velocity"],
    "تحمل": ["endurance"],
    "هوائي": ["aerobic"],
    "قلب": ["cardio", "heart"],
    "دهني": ["fat"],
    "خساره": ["loss"],
    "نزول": ["loss"],
    "تقدم": ["progression", "progress"],
    "تدرج": ["progression", "progressive"],
    "زياده": ["increase", "overload"],
    "مستوى": ["level"],
    "شدتها": ["intensity"],
    "قرفصاء": ["squat"],
    "سكوات": ["squat"],
    "اطاله": ["stretching"],
    "اطالات": ["stretching"],
    # sets / reps (incl. colloquial)
    "جوله": ["set", "sets", "round"], "جولات": ["sets", "rounds"], "جول": ["sets", "rounds"],
    "سيت": ["set", "sets"], "سيتات": ["sets"], "مجاميع": ["sets"], "مجموعه": ["set", "sets"],
    "عده": ["repetitions", "reps"], "عدات": ["repetitions", "reps"], "ريب": ["reps", "repetitions"],
    "ريبس": ["reps", "repetitions"], "عدات": ["repetitions", "reps"],
    # training types
    "حديد": ["resistance", "weights", "iron"], "مقاومه": ["resistance"], "كارديو": ["cardio", "aerobic"],
    "هوائيه": ["aerobic"], "لاهوائي": ["anaerobic"], "ستريتش": ["stretching"], "تمطيط": ["stretching"],
    "احماء": ["warm-up", "warm"], "تبريد": ["cool-down"], "تضخيم": ["bulking", "hypertrophy"],
    "تنشيف": ["cutting", "fat loss"], "حرق": ["burn", "fat"], "بناء": ["building", "gain"],
    "كتله": ["mass"], "عضليه": ["muscle", "muscular"], "جسم": ["body"], "جسمي": ["body"],
    "رشاقه": ["agility"], "توازن": ["balance"], "انفجاريه": ["explosive", "power"], "ثبات": ["stability"],
    "فشل": ["failure"], "الفشل": ["failure"], "حجم": ["volume"],
    # time / frequency
    "دقيقه": ["minute", "minutes"], "دقائق": ["minutes"], "ثانيه": ["second", "seconds"], "ثواني": ["seconds"],
    "فتره": ["interval", "period"], "فترات": ["intervals"], "اسبوعيا": ["weekly", "week"], "اسبوعيه": ["weekly", "week"],
    "يوميا": ["daily"], "شهر": ["month"], "اشهر": ["months"], "مرات": ["times", "frequency"], "مره": ["time", "frequency"],
    "تكراريه": ["frequency"],
    # nutrition
    "ماكروز": ["macronutrients"], "كرب": ["carbohydrate"], "كاربوهيدرات": ["carbohydrate"], "مكمل": ["supplement"],
    "مكملات": ["supplements", "supplementation"], "فيتامين": ["vitamin"], "ماء": ["water", "hydration"],
    "مياه": ["water", "hydration"], "ترطيب": ["hydration"], "وجبه": ["meal"], "وجبات": ["meals"],
    "صيام": ["fasting"], "عجز": ["deficit"], "فائض": ["surplus"],
    # body parts
    "ركبه": ["knee"], "كتف": ["shoulder"], "اكتاف": ["shoulders", "shoulder"], "ظهر": ["back"], "اسفل": ["lower"],
    "ورك": ["hip"], "حوض": ["hip", "pelvis"], "كاحل": ["ankle"], "رقبه": ["neck"], "صدر": ["chest"],
    "ارجل": ["legs", "leg"], "رجل": ["leg"], "ساق": ["leg", "calf"], "فخذ": ["thigh", "quadriceps"],
    "ذراع": ["arm"], "بطن": ["abdominal", "core"], "جذع": ["trunk", "core"], "مؤخره": ["glute", "gluteal"],
    "ارداف": ["glute", "gluteal"], "مفصل": ["joint"], "مفاصل": ["joints", "joint"], "وتر": ["tendon"],
    "اوتار": ["tendons", "tendon"], "اربطه": ["ligaments", "ligament"], "عظام": ["bone"],
    # health / physiology
    "تمزق": ["tear", "strain"], "التهاب": ["inflammation"], "ضعف": ["weakness"], "اداء": ["performance"],
    "تحسن": ["improvement"], "تحسين": ["improvement", "improve"], "نبض": ["heart rate"], "اكسجين": ["oxygen"],
    "هرمون": ["hormone"], "هرمونات": ["hormones"], "ارهاق": ["fatigue", "overtraining"], "مدي": ["range"],
    "حركي": ["motion", "movement"], "وضعيه": ["posture"], "ميكانيكا": ["biomechanics"], "فسيولوجيا": ["physiology"],
    "تشريح": ["anatomy"], "دهني": ["fat"], "سمنه": ["obesity"], "وزنه": ["weight"],
    # populations
    "مبتدئه": ["untrained", "novice"], "سيدات": ["women"], "امراه": ["women", "female"], "بنات": ["women", "female"],
    "حامل": ["pregnant", "pregnancy"], "حوامل": ["pregnant", "pregnancy"], "مراهقين": ["adolescents", "youth"],
    "اطفال": ["children"], "رياضيين": ["athletes"], "لاعبين": ["athletes", "players"], "متدربين": ["trained", "participants"],
}


def _strip_ar_prefix(w: str) -> str:
    for pre in ("وال", "بال", "كال", "فال", "لل", "ال", "و", "ب", "ل"):
        if w.startswith(pre) and len(w) - len(pre) >= 3:
            return w[len(pre):]
    return w


def normalize_arabic(text: str) -> str:
    text = _ARABIC_DIACRITICS.sub("", text)
    text = re.sub("[إأآٱ]", "ا", text)
    text = text.replace("ى", "ي").replace("ة", "ه").replace("ؤ", "و").replace("ئ", "ي")
    return text


AR_STOP = {normalize_arabic(w) for w in AR_STOP}
AR_QUESTION_FRAME = {normalize_arabic(w) for w in AR_QUESTION_FRAME}
AR_EN_GLOSSARY = {normalize_arabic(k): v for k, v in AR_EN_GLOSSARY.items()}


def clean_text(text: str) -> str:
    """Normalise extracted text while keeping it human-readable."""
    if not text:
        return ""
    for k, v in _LIGATURES.items():
        text = text.replace(k, v)
    text = unicodedata.normalize("NFKC", text)
    text = text.replace("­", "")
    # Re-join words hyphenated across line breaks: "hyper-\ntrophy" -> "hypertrophy"
    text = re.sub(r"([a-z])-\n([a-z])", r"\1\2", text)
    text = re.sub(r"[ \t ]+", " ", text)
    text = re.sub(r" *\n *", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def fold(text: str) -> str:
    """Lowercase + Arabic normalisation + whitespace collapse (for matching)."""
    text = unicodedata.normalize("NFKC", text or "").lower()
    for k, v in _LIGATURES.items():
        text = text.replace(k, v)
    text = normalize_arabic(text)
    text = text.replace("–", "-").replace("—", "-").replace("’", "'").replace("“", '"').replace("”", '"')
    return re.sub(r"\s+", " ", text).strip()


def stem_en(w: str) -> str:
    if len(w) <= 3 or w.isdigit():
        return w
    for suf, rep in (("ational", "ate"), ("ization", "ize"), ("iveness", "ive"), ("fulness", "ful"),
                     ("ousness", "ous"), ("ically", "ic"), ("ities", "ity"), ("ments", "ment")):
        if w.endswith(suf) and len(w) - len(suf) >= 3:
            return w[: -len(suf)] + rep
    if w.endswith("ies") and len(w) > 4:
        return w[:-3] + "y"
    if w.endswith("ing") and len(w) > 5:
        w = w[:-3]
        return w[:-1] if len(w) > 3 and w[-1] == w[-2] else w
    if w.endswith("ed") and len(w) > 4:
        w = w[:-2]
        return w[:-1] if len(w) > 3 and w[-1] == w[-2] else w
    if w.endswith("es") and len(w) > 4 and w[-3] in "sxz":
        return w[:-2]
    if w.endswith("s") and not w.endswith("ss") and not w.endswith("us") and not w.endswith("is"):
        return w[:-1]
    return w


def stem_ar(w: str) -> str:
    for pre in ("وال", "بال", "كال", "فال", "لل", "ال"):
        if w.startswith(pre) and len(w) - len(pre) >= 3:
            w = w[len(pre):]
            break
    if w.startswith("و") and len(w) > 4:
        w = w[1:]
    for suf in ("هما", "كما", "ات", "ون", "ين", "ان", "ها", "هم", "يه"):
        if w.endswith(suf) and len(w) - len(suf) >= 3:
            return w[: -len(suf)]
    return w


def raw_tokens(text: str) -> list[str]:
    return _WORD.findall(fold(text))


def is_arabic(tok: str) -> bool:
    return bool(tok) and "ء" <= tok[0] <= "ي"


def stem(tok: str) -> str:
    return stem_ar(tok) if is_arabic(tok) else stem_en(tok)


def tokens(text: str, drop_stop: bool = True) -> list[str]:
    out = []
    for t in raw_tokens(text):
        if drop_stop and (t in EN_STOP or t in AR_STOP):
            continue
        if len(t) == 1 and not t.isdigit():
            continue
        out.append(stem(t))
    return out


def search_text(text: str) -> str:
    """Stemmed, folded representation stored in the FTS index."""
    return " ".join(tokens(text))


def query_concepts(question: str) -> list[set[str]]:
    """Return concept groups: each group is a set of alternative stems.

    A passage "covers" a concept when it contains any stem of that group.
    Arabic words are expanded with English equivalents from the glossary so an
    Arabic question can find English sources.
    """
    groups: list[set[str]] = []
    seen: set[str] = set()
    for t in raw_tokens(question):
        if t in EN_STOP or t in AR_STOP or t in EN_QUESTION_FRAME or t in AR_QUESTION_FRAME:
            continue
        if len(t) == 1 and not t.isdigit():
            continue
        s = stem(t)
        if s in seen:
            continue
        seen.add(s)
        group = {s}
        if is_arabic(t):
            if _strip_ar_prefix(t) in AR_QUESTION_FRAME or _strip_ar_prefix(t) in AR_STOP:
                continue
            for en in glossary_lookup(t):
                group.update(stem_en(x) for x in en.split())
            # Arabic words without a glossary entry stay as an exact-match concept;
            # untranslated_terms() reports them so the user can rephrase.
        else:
            if s in ("rir",):
                group.update({"reserve", "rir"})
            if s == "rpe":
                group.update({"rpe", "exertion"})
        groups.append(group)
    return groups


_GLOSSARY_BY_STEM: dict[str, list[str]] = {}


def glossary_lookup(token: str) -> list[str]:
    """English equivalents for an (already folded) Arabic token, tolerant of prefixes/suffixes."""
    if not _GLOSSARY_BY_STEM:
        for k, v in AR_EN_GLOSSARY.items():
            _GLOSSARY_BY_STEM.setdefault(stem_ar(k), []).extend(v)
    out: list[str] = []
    for key in (token, _strip_ar_prefix(token)):
        out += AR_EN_GLOSSARY.get(key, [])
    out += _GLOSSARY_BY_STEM.get(stem_ar(token), [])
    return list(dict.fromkeys(out))


def untranslated_terms(question: str) -> list[str]:
    """Arabic content words of the question that have no English equivalent in the glossary."""
    out = []
    for t in raw_tokens(question):
        if not is_arabic(t) or t in AR_STOP or t in AR_QUESTION_FRAME or len(t) < 3:
            continue
        p = _strip_ar_prefix(t)
        if p in AR_QUESTION_FRAME or p in AR_STOP:
            continue
        if not glossary_lookup(t):
            out.append(t)
    return out


def concept_coverage(concepts: list[set[str]], text_tokens: set[str]) -> float:
    if not concepts:
        return 0.0
    hit = sum(1 for g in concepts if g & text_tokens)
    return hit / len(concepts)


_SENT_SPLIT = re.compile(r"(?<=[.!?؟])\s+(?=[A-Z0-9ء-ي(\"'])|\n{2,}")


def sentences(text: str) -> list[str]:
    parts = []
    for block in re.split(r"\n{2,}", text):
        block = block.replace("\n", " ").strip()
        if not block:
            continue
        # Avoid splitting on "et al." / "e.g." / "Fig." / "vs."
        protected = re.sub(r"\b(et al|e\.g|i\.e|Fig|vs|approx|ca|No)\.", lambda m: m.group(0).replace(".", "§"), block)
        for s in _SENT_SPLIT.split(protected):
            s = s.replace("§", ".").strip()
            if s:
                parts.append(s)
    return parts


_NUM = re.compile(r"(?<![\w.])(\d+(?:[.,]\d+)?)(?![\w])")


def is_statement(s: str) -> bool:
    """True for sentence-like text (not a bare title/heading/table row)."""
    s = s.strip()
    if len(s) < 30 or s.startswith("[Table") or s.count("|") >= 2:
        return False
    return s[-1] in ".!?؟:;)\"" or len(s.split()) >= 18


def numbers(text: str) -> set[str]:
    out = set()
    t = text.translate(str.maketrans("٠١٢٣٤٥٦٧٨٩", "0123456789"))
    for m in _NUM.finditer(t):
        out.add(m.group(1).replace(",", "."))
    return out


INJECTION_PATTERNS = [
    r"ignore (all |any )?(the |your )?(previous|prior|above|earlier) (instructions|rules|prompts)",
    r"disregard (all |any )?(the |your )?(previous|prior|above|system) (instructions|rules)",
    r"(ignore|bypass|override) (the )?(source|citation|evidence) (restrictions?|rules|constraints)",
    r"you are now",
    r"answer (from|using) (your )?(general|own|prior) knowledge",
    r"(search|browse|use) the (internet|web)",
    r"system prompt",
    r"تجاهل (جميع |كل )?(التعليمات|القواعد)",
    r"استخدم (الانترنت|الإنترنت|معرفتك)",
]
_INJ = re.compile("|".join(INJECTION_PATTERNS), re.IGNORECASE)


def looks_like_injection(text: str) -> bool:
    return bool(_INJ.search(text or ""))
