// استيراد قالب برنامج من ملف Markdown (يكتبه الذكاء الاصطناعي أو المدربة): تحليل النص فقط، بدون قاعدة بيانات.
// الصيغة نفسها موضّحة في ملف الدليل (programGuide) اللي تنزّله المدربة من «استيراد قالب».

import { DEFAULT_WEEK_RIR, MAX_WEEKS, parseReps, parseRir, type PlanWeek } from "./training.ts";

export type ImportedItem = { name: string; plan: PlanWeek[]; note: string | null };
export type ImportedDay = { title: string; items: ImportedItem[] };
export type ImportedProgram = { name: string; weeks: number; place: "نادي" | "منزل"; instructions: string | null; days: ImportedDay[] };

export const MAX_DAYS = 14;
export const MAX_ITEMS = 30;
const MAX_ERRORS = 15;

const toLatin = (s: string) => s.replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d)));
// إزالة تنسيق Markdown البسيط من الخلية: **عريض** و`كود`
const clean = (s: string) => s.replace(/\*\*|__|`/g, "").trim();
const cells = (line: string) => line.trim().replace(/^\||\|$/g, "").split("|").map(clean);
const EMPTY = /^(|-|—|–|_)$/;

/** خلية أسبوع: «3x10 @2» أو «3x10 RIR 2» أو «12-10-8 @1» أو «3x10». فارغ أو «—» = لا شيء هذا الأسبوع */
export function parseCell(cell: string): { reps: number[]; rir: number | null } | null {
  const s = toLatin(cell).trim();
  if (EMPTY.test(s)) return { reps: [], rir: null };
  const m = s.match(/^(.*?)(?:\s*(?:@|rir)\s*([\d.,]+))?$/i);
  const reps = parseReps(m?.[1] ?? "");
  const rir = m?.[2] ? parseRir(m[2]) : null;
  if (!reps || !reps.length || rir === undefined) return null;
  return { reps, rir };
}

/** يحلّل الملف كاملاً. أي خطأ = لا شيء يُنشأ، مع قائمة أخطاء بمكانها */
export function parseProgram(text: string): { program: ImportedProgram } | { errors: string[] } {
  const errors: string[] = [];
  const err = (m: string) => { if (errors.length < MAX_ERRORS) errors.push(m); };
  let name = "", weeksMeta: number | null = null, place: "نادي" | "منزل" = "نادي";
  const instr: string[] = [];
  const days: (ImportedDay & { cols: { week: number[]; note: number } | null; rows: string[][] })[] = [];
  let section: "meta" | "instructions" | "day" = "meta";

  for (const raw of text.replace(/^﻿/, "").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("```") || line.startsWith(">")) continue;
    if (/^#\s/.test(line)) { name = clean(line.slice(2)).replace(/^(اسم القالب|القالب)\s*[:：]\s*/, ""); continue; }
    if (/^##\s/.test(line)) {
      const h = clean(line.replace(/^#+\s*/, ""));
      if (/^التعليمات/.test(h)) { section = "instructions"; continue; }
      section = "day";
      const title = h.replace(/^(اليوم|يوم|day)\s*\d+\s*[:：\-–—]?\s*/i, "").trim() || h;
      days.push({ title: title.slice(0, 80), items: [], cols: null, rows: [] });
      continue;
    }
    if (section === "instructions") { instr.push(line.replace(/^[-*]\s+/, "")); continue; }
    if (section === "meta") {
      const kv = line.replace(/^[-*]\s+/, "").match(/^([^:：]+)[:：]\s*(.+)$/);
      if (!kv) continue;
      const [k, v] = [clean(kv[1]), clean(kv[2])];
      if (/الأسابيع/.test(k)) {
        const n = Number(toLatin(v).match(/\d+/)?.[0]);
        if (Number.isInteger(n) && n >= 1 && n <= MAX_WEEKS) weeksMeta = n; else err(`عدد الأسابيع من 1 إلى ${MAX_WEEKS}.`);
      } else if (/المكان/.test(k)) {
        if (/بيت|منزل/.test(v)) place = "منزل"; else if (/ناد/.test(v)) place = "نادي"; else err("المكان: النادي أو البيت.");
      }
      continue;
    }
    if (!line.startsWith("|")) continue;
    const day = days[days.length - 1], c = cells(line);
    if (c.every((x) => /^:?-{2,}:?$/.test(x))) continue;
    if (!day.cols && /التمرين|exercise/i.test(c[0])) {
      const week: number[] = [];
      c.forEach((x, i) => { if (/الأسبوع|week|الخطة|plan/i.test(x)) week.push(i); });
      day.cols = { week, note: c.findIndex((x) => /ملاحظ|note/i.test(x)) };
      continue;
    }
    day.rows.push(c);
  }

  if (!name || name.length < 2) err("اكتبي اسم القالب في أول سطر: # اسم القالب");
  if (!days.length) err("لا توجد أيام. كل يوم يبدأ بسطر مثل: ## اليوم 1: UPPER");
  if (days.length > MAX_DAYS) err(`الحد الأعلى ${MAX_DAYS} يوماً.`);
  const weekCols = Math.max(0, ...days.map((d) => d.cols?.week.length ?? 0));
  const weeks = weeksMeta ?? (weekCols > 1 ? weekCols : 5);

  days.forEach((d, di) => {
    const where = `اليوم ${di + 1} (${d.title})`;
    if (!d.cols || !d.cols.week.length) { err(`${where}: الجدول يحتاج سطر عناوين فيه «التمرين» و«الأسبوع 1»…`); return; }
    const wc = d.cols.week;
    if (wc.length !== 1 && wc.length !== weeks) { err(`${where}: في الجدول ${wc.length} أسابيع والقالب ${weeks}. اكتبي ${weeks} أعمدة أو عموداً واحداً للكل.`); return; }
    if (!d.rows.length) err(`${where}: لا توجد تمارين.`);
    if (d.rows.length > MAX_ITEMS) err(`${where}: الحد الأعلى ${MAX_ITEMS} تمريناً في اليوم.`);
    for (const r of d.rows) {
      const ex = r[0] ?? "";
      if (!ex || ex.length > 120) { err(`${where}: اسم تمرين فارغ أو طويل.`); continue; }
      const plan: PlanWeek[] = [];
      let bad = false;
      for (let w = 0; w < weeks; w++) {
        const cell = r[wc.length === 1 ? wc[0] : wc[w]] ?? "";
        const p = parseCell(cell);
        if (!p) { err(`${where} · ${ex} · الأسبوع ${w + 1}: «${cell}» غير مفهوم. الصيغة: 3x10 @2`); bad = true; break; }
        plan.push({ sets: p.reps.length, reps: p.reps, rir: p.reps.length ? p.rir ?? DEFAULT_WEEK_RIR[Math.min(w, DEFAULT_WEEK_RIR.length - 1)] : null });
      }
      if (bad) continue;
      if (plan.every((p) => !p.reps.length)) { err(`${where} · ${ex}: لا توجد مجموعات في أي أسبوع.`); continue; }
      const note = d.cols.note >= 0 ? (r[d.cols.note] ?? "").trim() : "";
      d.items.push({ name: ex, plan, note: note && !EMPTY.test(note) ? note.slice(0, 500) : null });
    }
  });

  if (errors.length) return { errors };
  return { program: { name: name.slice(0, 120), weeks, place, instructions: instr.join("\n").slice(0, 4000) || null, days: days.map(({ title, items }) => ({ title, items })) } };
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
