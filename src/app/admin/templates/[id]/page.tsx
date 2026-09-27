import Link from "next/link";
import { notFound } from "next/navigation";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import ActionForm from "@/components/admin/ActionForm";
import ProgramEditor, { type EditorDay, type ExOption } from "@/components/admin/ProgramEditor";
import { duplicateTemplateAction, saveTemplateAction } from "@/app/actions/training";
import { normalizePlan } from "@/lib/training";
import { loadExerciseOptions, loadProgramDays } from "@/lib/program-data";

type Tpl = { id: string; name: string; weeks: number; instructions: string | null; archived: boolean };

export default async function TemplatePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ created?: string }> }) {
  const coach = await requireCoach();
  const { id } = await params;
  const { created } = await searchParams;
  const isNew = id === "new";
  if (!isNew && !/^[0-9a-f-]{36}$/.test(id)) notFound();
  const data = await withUser(coach.id, async (tx) => {
    if (isNew) return { tpl: null, days: [] as EditorDay[], exercises: [] as ExOption[] };
    const tpl = (await tx.query(`SELECT id, name, weeks, instructions, archived FROM program_templates WHERE id = $1`, [id])).rows[0] as Tpl | undefined;
    if (!tpl) return null;
    const days = (await loadProgramDays(tx, "template", id)).map((d) => ({ ...d, items: d.items.map((i) => ({ ...i, plan: normalizePlan(i.plan, tpl.weeks) })) }));
    return { tpl, days, exercises: await loadExerciseOptions(tx) };
  });
  if (!data) notFound();
  const { tpl, days, exercises } = data;

  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 1000 }}>
      <nav className="small"><Link href="/admin/templates">قوالب البرامج</Link> / {tpl?.name ?? "قالب جديد"}</nav>
      <h1>{isNew ? "قالب جديد" : tpl!.name}</h1>
      {created && <p className="alert ok" role="status">تم إنشاء القالب. أضيفي الأيام والتمارين بالأسفل.</p>}
      <details className="card" open={isNew}>
        <summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>بيانات القالب</summary>
        <ActionForm action={saveTemplateAction} submit={isNew ? "إنشاء القالب" : "حفظ"}>
          <input type="hidden" name="id" value={tpl?.id ?? ""} />
          <div className="grid g2">
            <div className="field"><label htmlFor="tp-name">اسم القالب <span className="req">*</span></label>
              <input id="tp-name" name="name" type="text" required minLength={2} maxLength={120} defaultValue={tpl?.name} placeholder="مثال: متقدم — 4 أيام Upper/Lower" /></div>
            <div className="field"><label htmlFor="tp-weeks">عدد الأسابيع</label>
              <input id="tp-weeks" name="weeks" type="number" min={1} max={12} defaultValue={tpl?.weeks ?? 5} style={{ maxWidth: 120 }} />
              <span className="hint">مثل الشيت: 4 أسابيع + أسبوع تخفيف (Deload) = 5.</span></div>
          </div>
          <div className="field"><label htmlFor="tp-instr">تعليمات البلوك (تظهر للمتدرب)</label>
            <textarea id="tp-instr" name="instructions" maxLength={4000} rows={3} defaultValue={tpl?.instructions ?? ""} placeholder="الإحماء: جولتان بـ 50–60% · الراحة: 2–4 دقائق بين المجموعات…" /></div>
          {!isNew && <label className="check"><input type="checkbox" name="archived" defaultChecked={tpl?.archived} /><span>مؤرشف (لا يظهر في قائمة الإسناد)</span></label>}
        </ActionForm>
      </details>
      {!isNew && (
        <>
          <ProgramEditor kind="template" ownerId={tpl!.id} weeks={tpl!.weeks} days={days} exercises={exercises} />
          <ActionForm action={duplicateTemplateAction} className="form" submit="نسخ القالب كقالب جديد" submitClass="btn btn-ghost btn-sm">
            <input type="hidden" name="id" value={tpl!.id} />
          </ActionForm>
        </>
      )}
    </div>
  );
}
