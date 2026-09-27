// منطق منصة التدريب (بدون واجهة): مطابق لمعادلات ملف التدريب في Google Sheets.
//   VLU = مجموع التكرارات × الوزن × (1 − RIR × 0.05)
//   الالتزام الأسبوعي = عدد التمارين المسجّل لها وزن ÷ عدد تمارين البرنامج
//   التغيّر عن الأسبوع السابق = VLU الأسبوع ÷ VLU السابق − 1
//   الرقم القياسي = أعلى وزن مسجّل للتمرين عبر كل البرامج

export type PlanWeek = { sets: number; reps: number[]; rir: number | null };
export const MAX_SETS = 10;
export const MAX_WEEKS = 12;

const toLatin = (s: string) => s.replace(/[٠-٩]/g, (d) => String("٠١٢٣٤٥٦٧٨٩".indexOf(d))).replace(/[۰-۹]/g, (d) => String("۰۱۲۳۴۵۶۷۸۹".indexOf(d)));

/** «3x12» أو «3×12» ← [12,12,12]؛ «12,10,8» أو «12-10-8» أو «12 10 8» ← [12,10,8]. فارغ ← []. غير صالح ← null */
export function parseReps(input: string): number[] | null {
  const s = toLatin(input).trim().replace(/[×*xX]/g, "x").replace(/،/g, ",");
  if (!s) return [];
  const m = s.match(/^(\d{1,2})\s*x\s*(\d{1,3})$/);
  let reps: number[];
  if (m) reps = Array(Number(m[1])).fill(Number(m[2]));
  else {
    const parts = s.split(/[\s,\-/]+/).filter(Boolean);
    if (!parts.every((p) => /^\d{1,3}$/.test(p))) return null;
    reps = parts.map(Number);
  }
  if (reps.length === 0 || reps.length > MAX_SETS || reps.some((r) => r < 1 || r > 100)) return null;
  return reps;
}

/** [12,12,12] ← «3×12»؛ [12,10,8] ← «12-10-8» */
export function formatReps(reps: number[]): string {
  if (!reps.length) return "";
  return reps.every((r) => r === reps[0]) ? `${reps.length}×${reps[0]}` : reps.join("-");
}

export function parseRir(input: string): number | null | undefined {
  const s = toLatin(input).trim().replace(",", ".");
  if (!s) return null;
  const n = Number(s);
  return Number.isFinite(n) && n >= 0 && n <= 10 ? n : undefined;
}

/** يضمن أن الخطة بطول عدد الأسابيع (يكمل بآخر أسبوع معروف أو فارغ) */
export function normalizePlan(plan: unknown, weeks: number): PlanWeek[] {
  const arr = Array.isArray(plan) ? plan : [];
  const out: PlanWeek[] = [];
  for (let w = 0; w < weeks; w++) {
    const p = arr[w] as Partial<PlanWeek> | undefined;
    const reps = Array.isArray(p?.reps) ? p!.reps.filter((r) => Number.isFinite(r)).map(Number) : [];
    out.push({ sets: reps.length || Number(p?.sets) || 0, reps, rir: typeof p?.rir === "number" ? p.rir : null });
  }
  return out;
}

export function planLabel(p: PlanWeek | undefined): string {
  if (!p || !p.reps.length) return "—";
  return `${formatReps(p.reps)}${p.rir != null ? ` · RIR ${p.rir}` : ""}`;
}

/** الحجم التدريبي (نفس معادلة الشيت) */
export function vlu(reps: number[], weight: number, rir: number | null | undefined): number {
  const total = reps.reduce((a, b) => a + b, 0);
  return total * weight * (1 - (rir ?? 0) * 0.05);
}

export type LogLite = { block_item_id: string; week_no: number; weight: number; reps: number[]; rir: number | null };
export type ItemLite = { id: string; plan: PlanWeek[] };

/** التكرارات والـ RIR الفعلية؛ إن لم يكتبها المتدرب نأخذ المستهدف (كما في الشيت) */
export function effective(log: LogLite, plan: PlanWeek | undefined) {
  const reps = log.reps.length ? log.reps : plan?.reps ?? [];
  const rir = log.rir ?? plan?.rir ?? null;
  return { reps, rir, vlu: vlu(reps, Number(log.weight), rir) };
}

export type WeekSummary = { week: number; logged: number; total: number; adherence: number; vlu: number; change: number | null };

export function weeklySummary(items: ItemLite[], logs: LogLite[], weeks: number): WeekSummary[] {
  const byItem = new Map(items.map((i) => [i.id, i]));
  const out: WeekSummary[] = [];
  for (let w = 1; w <= weeks; w++) {
    const wl = logs.filter((l) => l.week_no === w && byItem.has(l.block_item_id));
    const v = wl.reduce((a, l) => a + effective(l, byItem.get(l.block_item_id)!.plan[w - 1]).vlu, 0);
    const prev = out[w - 2];
    out.push({
      week: w, logged: wl.length, total: items.length,
      adherence: items.length ? wl.length / items.length : 0,
      vlu: v,
      change: prev && prev.vlu > 0 && wl.length ? v / prev.vlu - 1 : null,
    });
  }
  return out;
}

/** الأسبوع الحالي من تاريخ البداية (1..weeks)، أو 0 قبل البداية */
export function currentWeek(startDate: string, today: string, weeks: number): number {
  const d = Math.floor((Date.parse(`${today}T00:00:00Z`) - Date.parse(`${startDate}T00:00:00Z`)) / 86_400_000);
  if (d < 0) return 0;
  return Math.min(weeks, Math.floor(d / 7) + 1);
}

export type PrRow = { exercise_id: string; name: string; best: number; best_at: string; previous: number | null; status: "first" | "new" | "same" };
/** أعلى وزن لكل تمرين، والرقم السابق قبله، وحالته (أول تسجيل / رقم جديد) */
export function personalRecords(logs: { exercise_id: string; name: string; weight: number; logged_at: string }[]): PrRow[] {
  const byEx = new Map<string, typeof logs>();
  for (const l of logs) byEx.set(l.exercise_id, [...(byEx.get(l.exercise_id) ?? []), l]);
  const out: PrRow[] = [];
  for (const [id, list] of byEx) {
    const sorted = [...list].sort((a, b) => a.logged_at.localeCompare(b.logged_at));
    let best = sorted[0], previous: number | null = null;
    for (const l of sorted.slice(1)) if (Number(l.weight) > Number(best.weight)) { previous = Number(best.weight); best = l; }
    out.push({
      exercise_id: id, name: best.name, best: Number(best.weight), best_at: best.logged_at, previous,
      status: sorted.length === 1 ? "first" : previous != null ? "new" : "same",
    });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

/** متوسط الوزن لكل أسبوع (أسابيع تبدأ من تاريخ البداية) */
export function weeklyAverages(entries: { date: string; value: number }[], startDate: string): { week: number; avg: number; n: number }[] {
  const m = new Map<number, number[]>();
  for (const e of entries) {
    const w = currentWeek(startDate, e.date, 999);
    if (w < 1) continue;
    m.set(w, [...(m.get(w) ?? []), Number(e.value)]);
  }
  return [...m.entries()].sort((a, b) => a[0] - b[0]).map(([week, v]) => ({ week, avg: v.reduce((a, b) => a + b, 0) / v.length, n: v.length }));
}
