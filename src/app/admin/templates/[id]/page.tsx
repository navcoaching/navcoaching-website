import Link from "next/link";
import { notFound } from "next/navigation";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import ActionForm from "@/components/admin/ActionForm";
import ProgramEditor, { type EditorDay, type ExOption } from "@/components/admin/ProgramEditor";
import { duplicateTemplateAction, saveTemplateAction } from "@/app/actions/training";
import { normalizePlan } from "@/lib/training";
import { loadExerciseOptions, loadProgramDays, loadVolumeSetup } from "@/lib/program-data";
import VolumeTable from "@/components/admin/VolumeTable";

type Tpl = { id: string; name: string; weeks: number; instructions: string | null; archived: boolean; public: boolean; public_summary: string | null; place: string };

export default async function TemplatePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ created?: string; imported?: string; skipped?: string }> }) {
  const coach = await requireCoach();
  const { id } = await params;
  const { created, imported, skipped } = await searchParams;
  const isNew = id === "new";
  if (!isNew && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) notFound();
  const data = await withUser(coach.id, async (tx) => {
    if (isNew) return { tpl: null, days: [] as EditorDay[], exercises: [] as ExOption[], volume: { limits: {}, saved: {}, muscles: [] as string[], sessionCap: 10 } };
    const tpl = (await tx.query(`SELECT id, name, weeks, instructions, archived, public, public_summary, place FROM program_templates WHERE id = $1`, [id])).rows[0] as Tpl | undefined;
    if (!tpl) return null;
    const days = (await loadProgramDays(tx, "template", id)).map((d) => ({ ...d, items: d.items.map((i) => ({ ...i, plan: normalizePlan(i.plan, tpl.weeks) })) }));
    return { tpl, days, exercises: await loadExerciseOptions(tx, tpl.place, days.flatMap((d) => d.items.map((i) => i.exercise_id).filter((x): x is string => Boolean(x)))), volume: await loadVolumeSetup(tx) };
  });
  if (!data) notFound();
  const { tpl, days, exercises, volume } = data;

  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 1000 }}>
      <nav className="small"><Link href="/admin/templates">قوالب البرامج</Link> / {tpl?.name ?? "قالب جديد"}</nav>
      <h1>{isNew ? "قالب جديد" : tpl!.name}</h1>
      {created && <p className="alert ok" role="status">تم إنشاء القالب. أضيفي الأيام والتمارين بالأسفل.</p>}
      {imported && <p className="alert ok" role="status" data-testid="imported">تم استيراد القالب من الملف. راجعي الأيام والتمارين بالأسفل وعدّلي ما تحتاجين.</p>}
      {imported && skipped && (
        <div className="alert warn" style={{ display: "block" }} data-testid="import-skipped">
          <b>لم يُستورد من الملف:</b>
          <ul style={{ margin: "6px 0 0", paddingInlineStart: 20 }}>{skipped.slice(0, 800).split("\n").map((l) => <li key={l}>{l}</li>)}</ul>
        </div>
      )}
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
            <div className="field"><label htmlFor="tp-place">مكان التمرين</label>
              <select id="tp-place" name="place" defaultValue={tpl?.place ?? "نادي"} data-testid="template-place">
                <option value="نادي">النادي</option><option value="منزل">البيت</option>
              </select>
              <span className="hint">قالب البيت: الإضافة وبدائل المتدرب من تمارين البيت فقط (بنش، أوزان، باند، وزن الجسم).</span></div>
          </div>
          <div className="field"><label htmlFor="tp-instr">تعليمات البلوك (تظهر للمتدرب)</label>
            <textarea id="tp-instr" name="instructions" maxLength={4000} rows={3} defaultValue={tpl?.instructions ?? ""} placeholder="الإحماء: جولتان بـ 50–60% · الراحة: 2–4 دقائق بين المجموعات…" /></div>
          {!isNew && <label className="check"><input type="checkbox" name="archived" defaultChecked={tpl?.archived} /><span>مؤرشف (لا يظهر في قائمة الإسناد)</span></label>}
          {!isNew && (
            <fieldset className="stack" style={{ ["--space" as string]: "8px" }}>
              <label className="check"><input type="checkbox" name="public" defaultChecked={tpl?.public} /><span>برنامج مجاني في تطبيق الجوال (يراه أي مستخدم ويبدأه كنسخة على جواله)</span></label>
              <span className="hint">يظهر للمستخدم الأسبوع الأول فقط: التمارين والجولات والتكرارات وRIR، مع تعليمات البلوك. لا تظهر ملاحظاتك.</span>
              <div className="field"><label htmlFor="tp-summary">وصف قصير في التطبيق</label>
                <input id="tp-summary" name="public_summary" type="text" maxLength={300} defaultValue={tpl?.public_summary ?? ""} placeholder="مثال: 3 أيام في النادي للمبتدئين — علوي، سفلي، شامل" /></div>
            </fieldset>
          )}
        </ActionForm>
      </details>
      {!isNew && (
        <>
          <ProgramEditor kind="template" ownerId={tpl!.id} weeks={tpl!.weeks} days={days} exercises={exercises} sessionCap={volume.sessionCap} />
          <VolumeTable items={days.flatMap((d) => d.items)} weeks={tpl!.weeks} limits={volume.limits} saved={volume.saved} muscles={volume.muscles} sessionCap={volume.sessionCap} />
          <ActionForm action={duplicateTemplateAction} className="form" submit="نسخ القالب كقالب جديد" submitClass="btn btn-ghost btn-sm">
            <input type="hidden" name="id" value={tpl!.id} />
          </ActionForm>
        </>
      )}
    </div>
  );
}
