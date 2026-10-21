// استيراد قالب برنامج من ملف Markdown (يكتبه الذكاء الاصطناعي أو المدربة): تحليل النص فقط، بدون قاعدة بيانات.
// يفهم صيغتين: صيغة الدليل (programGuide: عمود لكل أسبوع وخلية «3x10 @2»)، وجداول البرامج الجاهزة
// (أعمدة «الأسبوع 1–2» و«3 × 8–12» وعمود RIR منفصل والإيقاع والراحة، وأقسام نصية مثل قواعد السلامة والإحماء).

import { DEFAULT_WEEK_RIR, MAX_SETS, MAX_WEEKS, parseReps, parseRir, type PlanWeek } from "./training.ts";
import { normalizeName } from "./workout-import.ts";
import { painLabelFrom } from "./pain.ts";

/** name: الاسم كما في الملف، match: الجزء الإنجليزي للمطابقة مع المكتبة، pain: اسم مقياس الألم إذا ذُكر التمرين في عمود ألم */
export type ImportedItem = { name: string; match: string; plan: PlanWeek[]; note: string | null; pain: string | null };
export type ImportedDay = { title: string; items: ImportedItem[] };
/**
 * instructions: تعليمات البلوك للمتدرب (بدون بيانات المتدرب). notes: كل معلومات الملف النصية مع بيانات المتدرب لملاحظات المدربة الخاصة.
 * skipped: ما تُرك أو اختُصر (يُعرض للمدربة بعد الإنشاء)
 */
export type ImportedProgram = { name: string; weeks: number; place: "نادي" | "منزل"; instructions: string | null; notes: string | null; days: ImportedDay[]; skipped: string[] };

export const MAX_DAYS = 14;
export const MAX_ITEMS = 30;
const MAX_ERRORS = 15;
const MAX_INSTR = 4000;

const toLatin = (s: string) => s.replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)));
// إزالة تنسيق Markdown البسيط: **عريض** و`كود`
const clean = (s: string) => s.replace(/\*\*|__|`/g, "").replace(/^\*(?!\s)(.+)\*$/, "$1").trim();
const cells = (line: string) => line.trim().replace(/^\||\|$/g, "").split("|").map(clean);
const EMPTY = /^(|-|—|–|_)$/;
const RANGE = "\\s*[–\\-—~]\\s*";
const ORDINAL = "الأول|الثاني|الثالث|الرابع|الخامس|السادس|السابع|الثامن|التاسع|العاشر";
// أقسام نصية لا تصير تعليمات للمتدرب: بيانات المتدرب الصحية، وطريقة تعبئة شيت خارجي. ولا لملاحظات المدربة: طريقة التعبئة
const NOT_INSTRUCTIONS = /بيانات|التعبئة|سجل/;
const NOT_NOTES = /التعبئة|سجل/;

/** الاسم الإنجليزي للمطابقة، والباقي (كلمات عربية أو ما بين أقواس) وصف يُضاف للملاحظة */
export function splitName(raw: string): { match: string; extra: string } {
  const paren = [...raw.matchAll(/\(([^)]*)\)/g)].map((m) => m[1].trim()).filter(Boolean);
  const base = raw.replace(/\([^)]*\)/g, " ");
  const LATIN = /[A-Za-z0-9][A-Za-z0-9'’\-&/ ]*[A-Za-z0-9]|[A-Za-z]/g;
  const latin = (base.match(LATIN) ?? []).filter((w) => /[A-Za-z]/.test(w)).join(" ").replace(/\s+/g, " ").trim();
  if (!latin) return { match: raw.trim(), extra: "" };
  const arabic = base.replace(LATIN, " ").replace(/\s+/g, " ").trim();
  return { match: latin, extra: [arabic, ...paren].filter(Boolean).join(" · ") };
}

export type Cell = { reps: number[]; rir: number | null; range: string | null; side: boolean; secs: boolean };

/**
 * خلية أسبوع: «3x10 @2»، «3x10 RIR 2»، «12-10-8 @1»، «3 × 8–12» (نطاق: يُحفظ الأدنى)، «2 × 15–20 لكل رجل»، «3x30 ث».
 * فارغ أو «—» = لا شيء هذا الأسبوع. «10 د» = مدة (كارديو) لا تُمثَّل كمجموعات. غير المفهوم = null.
 */
export function parseCell(cell: string): Cell | "duration" | null {
  let s = toLatin(cell).replace(/[×*]/g, "x").trim();
  if (EMPTY.test(s)) return { reps: [], rir: null, range: null, side: false, secs: false };
  if (!/x/i.test(s) && /\d\s*(د|دقيقة|دقائق|min)/i.test(s)) return "duration";
  const side = /لكل\s*(رجل|ساق|يد|جهة|جانب|طرف)|each|per side/i.test(s);
  s = s.replace(/لكل\s*(رجل|ساق|يد|جهة|جانب|طرف)|each( side| leg| arm)?|per side/gi, "").trim();
  const m = s.match(/^(.*?)(?:\s*(?:@|rir)\s*([\d.,]+))?$/i);
  let body = (m?.[1] ?? "").trim();
  const rir = m?.[2] ? parseRir(m[2]) : null;
  if (rir === undefined) return null;
  const secs = /\d\s*(ث|ثانية|ثوان|ثواني|sec|s)$/i.test(body);
  body = body.replace(/\s*(ث|ثانية|ثوانٍ|ثوان|ثواني|sec|s)$/i, "");
  const r = body.match(new RegExp(`^(\\d{1,2})\\s*x\\s*(\\d{1,3})${RANGE}(\\d{1,3})$`, "i"));
  if (r) {
    const [sets, lo, hi] = [Number(r[1]), Number(r[2]), Number(r[3])];
    if (sets < 1 || sets > MAX_SETS || lo < 1 || hi > 100 || lo > hi) return null;
    return { reps: Array(sets).fill(lo), rir, range: `${lo}–${hi}`, side, secs };
  }
  const reps = parseReps(body);
  if (!reps || !reps.length) return null;
  return { reps, rir, range: null, side, secs };
}

type Span = { col: number; from: number; to: number | null }; // to = null: كل الأسابيع
type Cols = { ex: number; spans: Span[]; rir: number; tempo: number; rest: number; note: number; pain: string | null };
// pain: جدول فيه عمود ألم (سجل الأسبوع أو جدول البرنامج نفسه): اسم المقياس ومفاتيح التمارين المذكورة فيه
type Section = { heading: string; text: string[]; rows: string[][]; cols: Cols | null; pain: { label: string; keys: Set<string>; all: boolean } | null };

/** سطر عناوين الجدول: عمود التمرين إلزامي، وأعمدة الأسابيع («الأسبوع 1» أو «الأسبوع 1–2» أو «الخطة») تجعله جدول برنامج */
function headerOf(c: string[]): Cols | null {
  const ex = c.findIndex((x) => /^(التمرين|اسم التمرين|exercise)/i.test(x));
  if (ex < 0) return null;
  const spans: Span[] = [];
  c.forEach((x, i) => {
    const w = toLatin(x).match(new RegExp(`(?:الأسبوع|الاسبوع|أسبوع|week)\\s*(\\d{1,2})(?:${RANGE}(\\d{1,2}))?`, "i"));
    if (w) spans.push({ col: i, from: Number(w[1]), to: Number(w[2] ?? w[1]) });
    else if (/^(الخطة|plan)/i.test(x)) spans.push({ col: i, from: 1, to: null });
  });
  const find = (re: RegExp) => c.findIndex((x) => re.test(x));
  return { ex, spans, rir: find(/^rir$/i), tempo: find(/الإيقاع|الايقاع|tempo/i), rest: find(/الراحة|rest/i), note: find(/ملاحظ|note/i),
    pain: c.map(painLabelFrom).find(Boolean) ?? null };
}

const rirRange = (v: string): [number, number] | null => {
  const m = toLatin(v).match(new RegExp(`^(\\d+(?:[.,]\\d)?)(?:${RANGE}(\\d+(?:[.,]\\d)?))?$`));
  if (!m) return null;
  const a = parseRir(m[1]), b = parseRir(m[2] ?? m[1]);
  return a == null || b == null ? null : [Math.min(a, b), Math.max(a, b)];
};

/** يحلّل الملف كاملاً. أي خطأ = لا شيء يُنشأ، مع قائمة أخطاء بمكانها */
export function parseProgram(text: string): { program: ImportedProgram } | { errors: string[] } {
  const errors: string[] = [];
  const err = (m: string) => { if (errors.length < MAX_ERRORS) errors.push(m); };
  let name = "", weeksMeta: number | null = null, weeksText: number | null = null, place: "نادي" | "منزل" | null = null;
  const preamble: string[] = [];
  const sections: Section[] = [];
  let table: "plan" | "pain" | "skip" | null = null, painEx = 0;

  for (const raw of text.replace(/^﻿/, "").split(/\r?\n/)) {
    const line = raw.trim();
    const sec = sections[sections.length - 1];
    if (!line.startsWith("|")) table = null;
    if (!line || line.startsWith("```") || line.startsWith(">") || /^(-{3,}|\*{3,})$/.test(line)) continue;
    if (/^#\s/.test(line)) { if (!name) name = clean(line.slice(2)).replace(/^(اسم القالب|القالب)\s*[:：]\s*/, ""); continue; }
    if (/^##\s/.test(line)) { sections.push({ heading: clean(line.replace(/^#+\s*/, "")), text: [], rows: [], cols: null, pain: null }); continue; }
    if (/^#{3,}\s/.test(line)) continue;
    if (line.startsWith("|")) {
      if (!sec) continue;
      const c = cells(line);
      if (c.every((x) => /^:?-{2,}:?$/.test(x))) continue;
      if (table === null) {
        const h = headerOf(c);
        // أول جدول برنامج في القسم يُقرأ؛ جدول آخر فيه عمود ألم (مثل «سجل الأسبوع») يحدد تمارين مقياس الألم؛ والباقي يُتجاهل
        table = h && h.spans.length && !sec.cols ? "plan" : h?.pain ? "pain" : "skip";
        if (table === "plan") { sec.cols = h; if (h!.pain) sec.pain = { label: h!.pain, keys: new Set(), all: true }; }
        if (table === "pain") { painEx = h!.ex; sec.pain ??= { label: h!.pain!, keys: new Set(), all: false }; }
        continue;
      }
      if (table === "plan") sec.rows.push(c);
      if (table === "pain" && c[painEx]) sec.pain!.keys.add(canon(splitName(c[painEx]).match));
      continue;
    }
    const txt = clean(line).replace(/^[-*]\s+/, "• ");
    if (!sec) {
      const kv = clean(line).replace(/^[-*]\s+/, "").match(/^([^:：]+)[:：]\s*(.+)$/);
      if (kv && /الأسابيع/.test(kv[1])) {
        const n = Number(toLatin(kv[2]).match(/\d+/)?.[0]);
        if (Number.isInteger(n) && n >= 1 && n <= MAX_WEEKS) weeksMeta = n; else err(`عدد الأسابيع من 1 إلى ${MAX_WEEKS}.`);
        continue;
      }
      if (kv && /المكان/.test(kv[1])) {
        if (/بيت|منزل/.test(kv[2])) place = "منزل"; else if (/ناد/.test(kv[2])) place = "نادي"; else err("المكان: النادي أو البيت.");
        continue;
      }
      const w = toLatin(txt).match(/(\d{1,2})\s*(أسابيع|أسبوع|weeks?)/i);
      if (w && !weeksText) weeksText = Number(w[1]);
      preamble.push(txt);
      continue;
    }
    sec.text.push(txt);
  }

  if (!name || name.length < 2) err("اكتبي اسم القالب في أول سطر: # اسم القالب");
  place ??= /البيت|المنزل/.test([name, ...preamble].join(" ")) ? "منزل" : "نادي";
  const daySecs = sections.filter((s) => s.cols);
  if (!daySecs.length) err("لا توجد أيام. كل يوم قسم يبدأ بـ ## وتحته جدول فيه «التمرين» و«الأسبوع 1»…");
  if (daySecs.length > MAX_DAYS) err(`الحد الأعلى ${MAX_DAYS} يوماً.`);
  // عمود «الأسبوع 1» وحيد في كل الجداول = خطة واحدة لكل الأسابيع (مثل «الخطة»)
  const all = daySecs.flatMap((s) => s.cols!.spans);
  if (all.every((sp) => sp.from === 1 && sp.to === 1)) all.forEach((sp) => { sp.to = null; });
  const maxEnd = Math.max(0, ...all.map((sp) => sp.to ?? 0));
  const weeks = weeksMeta ?? (weeksText && weeksText <= MAX_WEEKS ? weeksText : null) ?? (maxEnd || 5);
  if (maxEnd > MAX_WEEKS) err(`عدد الأسابيع من 1 إلى ${MAX_WEEKS}.`);

  const skipped: string[] = [];
  const dayNotes: string[] = [];
  const days: ImportedDay[] = daySecs.map((s, di) => {
    const title = (s.heading.replace(new RegExp(`^(اليوم|يوم|day)\\s*(\\d+|${ORDINAL})\\s*[:：\\-–—]?\\s*`, "i"), "").trim() || s.heading).slice(0, 80);
    const where = `اليوم ${di + 1} (${title})`;
    const cols = s.cols!;
    const spans = [...cols.spans].sort((a, b) => a.from - b.from);
    // كل أسبوع من 1 إلى weeks يغطيه عمود واحد بالضبط
    const spanOf = (w: number) => spans.find((sp) => sp.to === null || (w >= sp.from && w <= sp.to));
    const missing = Array.from({ length: weeks }, (_, i) => i + 1).filter((w) => !spanOf(w));
    if (missing.length) { err(`${where}: الجدول لا يغطي الأسبوع ${missing.join("، ")} والقالب ${weeks} أسابيع.`); return { title, items: [] }; }
    if (spans.some((sp) => (sp.to ?? 0) > weeks)) { err(`${where}: الجدول فيه أسابيع أكثر من ${weeks}.`); return { title, items: [] }; }
    for (const t of s.text) if (!dayNotes.includes(t)) dayNotes.push(t);
    if (!s.rows.length) err(`${where}: لا توجد تمارين.`);
    if (s.rows.length > MAX_ITEMS) err(`${where}: الحد الأعلى ${MAX_ITEMS} تمريناً في اليوم.`);
    const items: ImportedItem[] = [];
    for (const r of s.rows) {
      const ex = r[cols.ex] ?? "";
      if (!ex || ex.length > 120) { err(`${where}: اسم تمرين فارغ أو طويل.`); continue; }
      const parsed = spans.map((sp) => ({ sp, cell: r[sp.col] ?? "", p: parseCell(r[sp.col] ?? "") }));
      const bad = parsed.find((x) => x.p === null);
      if (bad) { err(`${where} · ${ex} · ${bad.sp.to === null ? "الخطة" : `الأسبوع ${bad.sp.from}${bad.sp.to !== bad.sp.from ? `–${bad.sp.to}` : ""}`}: «${bad.cell}» غير مفهوم. الصيغة: 3x10 @2 أو 3 × 8–12`); continue; }
      if (parsed.every((x) => x.p === "duration" || (x.p as Cell).reps.length === 0)) {
        if (parsed.some((x) => x.p === "duration")) { skipped.push(`${title}: ${ex} (مدة وليس مجموعات)`); continue; }
        err(`${where} · ${ex}: لا توجد مجموعات في أي أسبوع.`); continue;
      }
      if (parsed.some((x) => x.p === "duration")) { err(`${where} · ${ex}: خليط من مدة ومجموعات.`); continue; }
      const rr = cols.rir >= 0 ? rirRange(r[cols.rir] ?? "") : null;
      const plan: PlanWeek[] = Array.from({ length: weeks }, (_, i) => {
        const x = parsed.find((q) => q.sp === spanOf(i + 1))!;
        const c = x.p as Cell;
        if (!c.reps.length) return { sets: 0, reps: [], rir: null };
        // عمود RIR بنطاق «2–3»: الأعلى (الأحوط) لأول فترة، والأدنى لما بعدها
        const rir = c.rir ?? (rr ? (spans.indexOf(x.sp) === 0 ? rr[1] : rr[0]) : DEFAULT_WEEK_RIR[Math.min(i, DEFAULT_WEEK_RIR.length - 1)]);
        return { sets: c.reps.length, reps: c.reps, rir };
      });
      const cellsOk = parsed.map((x) => ({ sp: x.sp, c: x.p as Cell }));
      const ranges = cellsOk.filter((x) => x.c.range);
      const rangeText = !ranges.length ? "" : new Set(ranges.map((x) => x.c.range)).size === 1 || spans.length === 1
        ? `التكرارات: ${ranges[0].c.range}`
        : `التكرارات: ${ranges.map((x) => `${x.c.range} (الأسابيع ${x.sp.from}–${x.sp.to})`).join("، ")}`;
      const { match, extra } = splitName(ex);
      const val = (i: number) => (i >= 0 && !EMPTY.test(r[i] ?? "") ? r[i] : "");
      const note = [
        extra,
        cellsOk.some((x) => x.c.side) ? "لكل جهة" : "",
        cellsOk.some((x) => x.c.secs) ? "التكرار بالثواني" : "",
        rangeText,
        val(cols.tempo) && `الإيقاع: ${val(cols.tempo)}`,
        val(cols.rest) && `الراحة: ${val(cols.rest)}`,
        val(cols.note),
      ].filter(Boolean).join(" · ").slice(0, 500);
      const pain = s.pain && (s.pain.all || s.pain.keys.has(canon(match))) ? s.pain.label : null;
      items.push({ name: ex, match, plan, note: note || null, pain });
    }
    return { title, items };
  });

  // الأقسام النصية (قواعد السلامة، الإحماء، طريقة التقدم…) تصير تعليمات البلوك للمتدرب،
  // وكلها مع بيانات المتدرب تصير ملاحظة خاصة للمدربة. المقدمة أولاً، وملاحظات الأيام العامة (السوبرست…) في الآخر
  const build = (skip: RegExp) => {
    const out: string[] = [...preamble];
    for (const s of sections) {
      if (s.cols || skip.test(s.heading) || !s.text.length) continue;
      out.push("", ...(/^التعليمات/.test(s.heading) ? [] : [`${s.heading}:`]), ...s.text.filter((t) => !out.includes(t)));
    }
    if (dayNotes.length) out.push("", ...dayNotes.filter((t) => !out.includes(t)));
    return out.join("\n").replace(/\n{3,}/g, "\n\n").trim();
  };
  let instructions = build(NOT_INSTRUCTIONS);
  if (instructions.length > MAX_INSTR) {
    instructions = instructions.slice(0, instructions.lastIndexOf("\n", MAX_INSTR) > 0 ? instructions.lastIndexOf("\n", MAX_INSTR) : MAX_INSTR);
    skipped.push(`التعليمات اختُصرت إلى ${MAX_INSTR} حرف`);
  }
  const notes = build(NOT_NOTES);

  if (errors.length) return { errors };
  return { program: { name: name.slice(0, 120), weeks, place, instructions: instructions || null, notes: notes || null, days, skipped } };
}

// =====================================================================
// مطابقة أسماء الملف مع مكتبة التمارين
// =====================================================================

export type LibEx = { id: string; name: string; place: string | null };
export type LibMatch = { name: string; key: string; id: string | null; how: "alias" | "name" | null; suggestions: LibEx[] };

// مرادفات شائعة في أسماء التمارين بعد التطبيع (الأسماء في المكتبة تستخدم الاختصار)
const SYN: [RegExp, string][] = [
  [/\bdumbbell\b/g, "db"], [/\bbarbell\b/g, "bb"], [/\bromanian deadlift\b/g, "rdl"], [/\bstiff leg(ged)? deadlift\b/g, "sldl"],
  [/\bpush ?ups?\b/g, "push up"], [/\bpull ?ups?\b/g, "pull up"], [/\bchin ?ups?\b/g, "chin up"], [/\btricep\b/g, "triceps"], [/\bbicep\b/g, "biceps"],
];
/** مفتاح المطابقة: الاسم بعد التطبيع والمرادفات («Dumbbell Romanian Deadlift» = «DB RDL») */
export const canon = (s: string) => SYN.reduce((a, [re, r]) => a.replace(re, r), normalizeName(s)).replace(/\s+/g, " ").trim();

/**
 * تشابه الاسمين: الكلمات المشتركة موزونة بطولها (الكلمة المميّزة مثل adduction أثقل من hip)،
 * والكلمتان بنفس الجذر (أول 5 أحرف: adduction/adductor) تُحسبان مشتركة
 */
export function similarity(a: string, b: string): number {
  const A = [...new Set(canon(a).split(" ").filter(Boolean))], B = [...new Set(canon(b).split(" ").filter(Boolean))];
  if (!A.length || !B.length) return 0;
  const same = (x: string, y: string) => x === y || (x.length >= 5 && y.length >= 5 && x.slice(0, 5) === y.slice(0, 5));
  const len = (ws: string[]) => ws.reduce((n, w) => n + w.length, 0);
  const shared = len(A.filter((x) => B.some((y) => same(x, y))));
  return shared / (len(A) + len(B) - shared);
}

/**
 * لكل اسم مختلف في الملف: ربط سابق حفظته المدربة، ثم نفس الاسم (بعد التطبيع والمرادفات، إذا كان تمريناً واحداً).
 * غير المطابق يرجع بأقرب 5 تمارين لتختار المدربة. لا تُقبل المطابقة التقريبية تلقائياً حتى لا يدخل تمرين خاطئ بصمت.
 */
export function matchLibrary(names: string[], lib: LibEx[], aliases: Record<string, string>): LibMatch[] {
  const byKey = new Map<string, LibEx[]>();
  for (const e of lib) byKey.set(canon(e.name), [...(byKey.get(canon(e.name)) ?? []), e]);
  const ids = new Set(lib.map((e) => e.id));
  const seen = new Set<string>();
  const out: LibMatch[] = [];
  for (const name of names) {
    const key = canon(name);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    const alias = aliases[key];
    if (alias && ids.has(alias)) { out.push({ name, key, id: alias, how: "alias", suggestions: [] }); continue; }
    const hits = byKey.get(key);
    if (hits?.length === 1) { out.push({ name, key, id: hits[0].id, how: "name", suggestions: [] }); continue; }
    const suggestions = lib.map((e) => ({ e, s: similarity(name, e.name) })).filter((x) => x.s > 0)
      .sort((a, b) => b.s - a.s || a.e.name.length - b.e.name.length).slice(0, 5).map((x) => x.e);
    out.push({ name, key, id: null, how: null, suggestions });
  }
  return out;
}

/** ملف الدليل: الصيغة ومثال وأسماء تمارين المكتبة كما هي، يُعطى للذكاء الاصطناعي مع طلب البرنامج */
export function programGuide(exercises: { name: string; primary_muscle: string | null; place: string | null }[]): string {
  // مثال منطقي ليوم علوي: أول تمرين صدر وأول تمرين ظهر في المكتبة
  const first = (re: RegExp, fallback: string) => exercises.find((e) => re.test(e.primary_muscle ?? ""))?.name ?? fallback;
  const [ex1, ex2] = [first(/chest|الصدر/i, "Bench Press"), first(/back|الظهر/i, "Lat Pulldown")];
  const byMuscle = new Map<string, string[]>();
  for (const e of exercises) {
    const k = e.primary_muscle || "أخرى";
    byMuscle.set(k, [...(byMuscle.get(k) ?? []), `${e.name}${e.place === "منزل" ? " (بيت)" : ""}`]);
  }
  return [
    "# دليل صيغة قالب برنامج Nav Coaching",
    "",
    "صمّم البرنامج المطلوب واكتب الناتج **ملف Markdown بهذه الصيغة بالضبط**، ليُستورد تلقائياً في لوحة الإدارة.",
    "",
    "## القواعد",
    "",
    "1. أول سطر: `# اسم القالب`.",
    "2. بعده: `- الأسابيع: 5` (من 1 إلى 12) و`- المكان: النادي` أو `- المكان: البيت`.",
    "3. اختياري: قسم `## التعليمات` وتحته أسطر تظهر للمتدرب (الإحماء، الراحة…).",
    "4. كل يوم يبدأ بـ `## اليوم 1: عنوان اليوم` وتحته جدول واحد.",
    "5. أعمدة الجدول: `التمرين`، ثم `الأسبوع 1` … حتى آخر أسبوع (أو عمود واحد `الخطة` يُطبّق على كل الأسابيع)، ثم `ملاحظة` (اختياري).",
    "6. خلية الأسبوع: `3x10 @2` = 3 مجموعات × 10 تكرارات و RIR 2. تكرارات مختلفة: `12-10-8 @1`. اكتب RIR دائماً، خصوصاً لأسبوع التخفيف (بدونه يُملأ تلقائياً 3·2·1·0 ثم 0 لما بعده). أسبوع بلا هذا التمرين: `—`.",
    "7. **اسم التمرين يُنسخ حرفياً من القائمة بالأسفل.** أي اسم غير موجود يوقف الاستيراد. قالب البيت يستخدم تمارين (بيت) فقط.",
    "8. الحدود: 14 يوماً، و30 تمريناً في اليوم، و10 مجموعات في الأسبوع للتمرين.",
    "",
    "## مثال",
    "",
    "```markdown",
    "# متوسط — 4 أيام علوي/سفلي",
    "",
    "- الأسابيع: 5",
    "- المكان: النادي",
    "",
    "## التعليمات",
    "الإحماء: جولتان خفيفتان قبل أول تمرين.",
    "الراحة: 2–3 دقائق بين المجموعات.",
    "",
    "## اليوم 1: UPPER",
    "| التمرين | الأسبوع 1 | الأسبوع 2 | الأسبوع 3 | الأسبوع 4 | الأسبوع 5 | ملاحظة |",
    "|---|---|---|---|---|---|---|",
    `| ${ex1} | 3x10 @3 | 3x10 @2 | 3x10 @1 | 3x10 @0 | 2x10 @3 | نزول بطيء |`,
    `| ${ex2} | 12-10-8 @2 | 12-10-8 @2 | 12-10-8 @1 | 12-10-8 @0 | — | |`,
    "```",
    "",
    "## أسماء تمارين المكتبة (انسخ الاسم كما هو)",
    "",
    ...[...byMuscle].sort(([a], [b]) => a.localeCompare(b)).flatMap(([m, list]) => [`### ${m}`, ...list.sort().map((n) => `- ${n}`), ""]),
  ].join("\n");
}
