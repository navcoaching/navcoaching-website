// ترتيب التمارين المشابهة لتمرين معيّن: بدائل الكوتش (لمشترك «ناف برو») أولاً بترتيبها، ثم الأقرب بالعضلة والأداة والمكان.
// دالة خالصة بدون استيراد بيانات حتى تُختبر مباشرة.

export type SimilarInput = {
  id: string; muscle: string; secondary: string[]; kind: string | null; equipment: string | null; place: string | null;
};
export type Similar = { id: string; coach: boolean; score: number };

export function rankSimilar(target: SimilarInput, all: SimilarInput[], coachAlts: string[] = [], limit = 10): Similar[] {
  const out: Similar[] = [];
  for (const e of all) {
    if (e.id === target.id) continue;
    const ci = coachAlts.indexOf(e.id);
    const coach = ci >= 0;
    const sameMuscle = !!target.muscle && e.muscle === target.muscle;
    // نفس العضلة الأساسية شرط، إلا لو كانت العضلة الأساسية لأحدهما ثانوية في الآخر (مثل الصدر والترايسبس في الضغط)
    const crossMuscle = !sameMuscle && (e.secondary.includes(target.muscle) && target.secondary.includes(e.muscle));
    if (!coach && !sameMuscle && !crossMuscle) continue;
    let score = 0;
    if (coach) score += 100_000 - ci * 100; // ترتيب الكوتش يتقدّم على أي درجة تشابه
    if (sameMuscle) score += 10; else if (crossMuscle) score += 4;
    const shared = e.secondary.filter((m) => target.secondary.includes(m)).length;
    score += shared;
    if (target.kind && e.kind === target.kind) score += 2;
    if (target.equipment && e.equipment === target.equipment) score += 3;
    if (target.place && e.place === target.place) score += 1;
    out.push({ id: e.id, coach, score });
  }
  // ترتيب ثابت: الدرجة ثم المعرّف
  return out.sort((a, b) => b.score - a.score || a.id.localeCompare(b.id)).slice(0, limit);
}
