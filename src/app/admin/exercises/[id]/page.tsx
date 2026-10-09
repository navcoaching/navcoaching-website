import Link from "next/link";
import { notFound } from "next/navigation";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import ActionForm from "@/components/admin/ActionForm";
import { saveExerciseAction } from "@/app/actions/training";
import { ANATOMICAL_ACTIONS, EQUIPMENT, EX_STATUS, KINDS, LEVELS, MOVEMENT_SUBCATEGORIES, MUSCLES, PATTERNS, REHAB_CATEGORIES, REHAB_DISCLAIMER, REHAB_LOADS, REHAB_PHASES, REHAB_REVIEW, SECONDARY_MUSCLES, SUB_PATTERNS, muscleAr, splitPipes } from "@/lib/exercises";
import { tiktokId, youtubeId } from "@/lib/youtube";

type Ex = {
  id: string; name: string; primary_muscle: string; secondary_muscles: string[]; pattern: string | null; kind: string | null; equipment: string | null;
  level: string | null; place: string | null; video_url: string | null; instructions: string | null; notes: string | null;
  source: string | null; source_name: string | null; source_url: string | null; rehab_category: string | null; status: string;
  sub_pattern: string | null; anatomical_action: string | null; movement_subcategory: string | null;
  rehab_goal: string | null; rehab_phase: string | null; rehab_load: string | null; rehab_safety: string | null;
  rehab_evidence: string | null; rehab_refs: string | null; rehab_review: string | null;
};
type Opt = { id: string; name: string; primary_muscle: string };

export default async function EditExercise({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ created?: string }> }) {
  const coach = await requireCoach();
  const { id } = await params;
  const { created } = await searchParams;
  const isNew = id === "new";
  if (!isNew && !/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { ex, alts, options, usage } = await withUser(coach.id, async (tx) => ({
    ex: isNew ? null : ((await tx.query(`SELECT * FROM exercises WHERE id = $1`, [id])).rows[0] as Ex | undefined),
    alts: isNew ? [] : ((await tx.query(
      `SELECT e.id, e.name, e.primary_muscle FROM exercise_alternatives a JOIN exercises e ON e.id = a.alt_id WHERE a.exercise_id = $1 ORDER BY a.position`, [id])).rows as Opt[]),
    options: (await tx.query(`SELECT id, name, primary_muscle FROM exercises WHERE status = 'approved' AND id::text <> $1 ORDER BY name`, [id])).rows as Opt[],
    usage: isNew ? { templates: 0, blocks: 0 } : ((await tx.query(
      `SELECT (SELECT count(DISTINCT d.template_id)::int FROM template_items i JOIN template_days d ON d.id = i.day_id WHERE i.exercise_id = $1) AS templates,
              (SELECT count(DISTINCT d.block_id)::int FROM block_items i JOIN block_days d ON d.id = i.day_id WHERE i.exercise_id = $1 OR i.coach_exercise_id = $1) AS blocks`, [id])).rows[0] as { templates: number; blocks: number }),
  }));
  if (!isNew && !ex) notFound();
  const chosen = new Set(alts.map((a) => a.id));
  const others = options.filter((o) => !chosen.has(o.id));
  const groups = MUSCLES.map((m) => ({ m, list: others.filter((o) => o.primary_muscle === m) })).filter((g) => g.list.length);
  const sel = (name: string, label: string, list: readonly string[], value: string | null | undefined, required = false) => (
    <div className="field"><label htmlFor={`ex-${name}`}>{label}{required && <> <span className="req">*</span></>}</label>
      <select id={`ex-${name}`} name={name} defaultValue={value ?? ""} required={required}>
        <option value="">{required ? "اختاري…" : "—"}</option>
        {list.map((o) => <option key={o} value={o}>{o}</option>)}
      </select></div>
  );
  const yt = youtubeId(ex?.video_url) ?? tiktokId(ex?.video_url);

  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 900 }}>
      <nav className="small"><Link href="/admin/exercises">مكتبة التمارين</Link> / <bdi>{ex?.name ?? "تمرين جديد"}</bdi></nav>
      <h1>{isNew ? "تمرين جديد" : <bdi dir="ltr">{ex!.name}</bdi>}</h1>
      {created && <p className="alert ok" role="status">تمت إضافة التمرين.</p>}
      {!isNew && (usage.templates > 0 || usage.blocks > 0) && (
        <p className="small muted">مستخدم في {usage.templates} قالب و{usage.blocks} برنامج متدرب. تعديل الاسم أو الفيديو أو التعليمات يظهر لهم مباشرة.</p>
      )}
      <div className="card">
        <ActionForm action={saveExerciseAction} submit={isNew ? "إضافة التمرين" : "حفظ التعديلات"}>
          <input type="hidden" name="id" value={ex?.id ?? ""} />
          <div className="grid g2">
            <div className="field"><label htmlFor="ex-name">اسم التمرين <span className="req">*</span></label>
              <input id="ex-name" name="name" type="text" dir="auto" required minLength={2} maxLength={120} defaultValue={ex?.name} /></div>
            {sel("primary_muscle", "العضلة الأساسية", MUSCLES, ex?.primary_muscle, true)}
            {sel("pattern", "تصنيف الحركة", PATTERNS, ex?.pattern)}
            <div className="field"><label htmlFor="ex-sub_pattern">النمط الفرعي / زاوية الحركة</label>
              <select id="ex-sub_pattern" name="sub_pattern" defaultValue={ex?.sub_pattern ?? ""}>
                <option value="">—</option>
                {PATTERNS.map((p) => {
                  const subs = SUB_PATTERNS.filter(([, parent]) => parent === p);
                  return subs.length ? <optgroup key={p} label={p}>{subs.map(([sp]) => <option key={sp} value={sp}>{sp}</option>)}</optgroup> : null;
                })}
              </select>
              <span className="hint">اختاري نمطاً فرعياً تابعاً لنمط الحركة المختار.</span></div>
            {sel("anatomical_action", "الحركة التشريحية الأساسية", ANATOMICAL_ACTIONS, ex?.anatomical_action)}
            {sel("movement_subcategory", "التصنيف الفرعي للحركة", MOVEMENT_SUBCATEGORIES, ex?.movement_subcategory)}
            {sel("kind", "نوع التمرين", KINDS, ex?.kind)}
            {sel("equipment", "المعدات", EQUIPMENT, ex?.equipment)}
            {sel("level", "المستوى", LEVELS, ex?.level)}
          </div>
          <p className="small muted" style={{ marginTop: -6 }}>المكان يُحسب تلقائياً من المعدات{ex?.place ? ` (الحالي: ${ex.place})` : ""}.</p>
          <fieldset className="field"><legend>العضلات الثانوية</legend>
            <div className="check-grid">
              {SECONDARY_MUSCLES.map((m) => (
                <label key={m} className="check"><input type="checkbox" name="secondary" value={m} defaultChecked={ex?.secondary_muscles.includes(m)} /><span>{muscleAr(m)}</span></label>
              ))}
            </div>
          </fieldset>
          <div className="field"><label htmlFor="ex-video">رابط الفيديو</label>
            <input id="ex-video" name="video_url" type="url" dir="ltr" maxLength={500} placeholder="https://youtu.be/… أو https://www.tiktok.com/@…/video/…" defaultValue={ex?.video_url ?? ""} />
            {ex?.video_url && <span className="hint"><a href={ex.video_url} target="_blank" rel="noopener noreferrer">فتح الفيديو ↗</a>{!yt && " · رابط غير يوتيوب/تيك توك الكامل: يفتح في صفحة خارجية (الروابط المختصرة vm.tiktok.com تفتح خارجياً، انسخي الرابط الكامل)."}</span>}</div>
          <div className="field"><label htmlFor="ex-instr">تعليمات الأداء (تظهر للمتدرب)</label>
            <textarea id="ex-instr" name="instructions" maxLength={4000} rows={4} defaultValue={ex?.instructions ?? ""} /></div>
          <div className="field"><label htmlFor="ex-notes">ملاحظات (للمدربة فقط)</label>
            <textarea id="ex-notes" name="notes" maxLength={4000} rows={2} defaultValue={ex?.notes ?? ""} /></div>

          <fieldset className="field"><legend>البدائل (تظهر للمتدرب في قائمة التبديل بهذا الترتيب)</legend>
            {alts.length > 0 ? (
              <div className="check-grid">
                {alts.map((a) => <label key={a.id} className="check"><input type="checkbox" name="alt" value={a.id} defaultChecked /><span><bdi dir="ltr">{a.name}</bdi>{a.primary_muscle !== ex?.primary_muscle && <small className="muted"> · {muscleAr(a.primary_muscle)}</small>}</span></label>)}
              </div>
            ) : <p className="small muted" style={{ margin: 0 }}>لا توجد بدائل محددة. إذا تُركت فارغة يرى المتدرب التمارين المعتمدة بنفس العضلة الأساسية ونفس تصنيف الحركة.</p>}
            <details style={{ marginTop: 8 }}>
              <summary style={{ cursor: "pointer", minHeight: 40 }}>إضافة بدائل من المكتبة</summary>
              {groups.map((g) => (
                <details key={g.m} open={g.m === ex?.primary_muscle} style={{ marginTop: 6 }}>
                  <summary style={{ cursor: "pointer", minHeight: 36 }}>{muscleAr(g.m)} ({g.list.length})</summary>
                  <div className="check-grid">
                    {g.list.map((o) => <label key={o.id} className="check"><input type="checkbox" name="alt" value={o.id} /><span><bdi dir="ltr">{o.name}</bdi></span></label>)}
                  </div>
                </details>
              ))}
            </details>
          </fieldset>

          <div className="grid g2">
            <fieldset className="field"><legend>مراجعة المدربة</legend>
              {Object.entries(EX_STATUS).map(([v, l]) => (
                <label key={v} className="check"><input type="radio" name="status" value={v} defaultChecked={(ex?.status ?? "approved") === v} /><span>{l}</span></label>
              ))}
            </fieldset>
            <div className="stack" style={{ ["--space" as string]: "10px" }}>
              <div className="field"><label htmlFor="ex-source">مصدر التمرين</label><input id="ex-source" name="source" type="text" maxLength={120} defaultValue={ex?.source ?? ""} /></div>
              <div className="field"><label htmlFor="ex-sname">اسم المصدر أو الجهة</label><input id="ex-sname" name="source_name" type="text" maxLength={200} defaultValue={ex?.source_name ?? ""} /></div>
              <div className="field"><label htmlFor="ex-surl">رابط المصدر</label><input id="ex-surl" name="source_url" type="url" dir="ltr" maxLength={500} defaultValue={ex?.source_url ?? ""} /></div>
            </div>
          </div>
          <details className="rehab-edit" open={Boolean(ex?.rehab_category)} data-testid="rehab-edit">
            <summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>التصنيف التأهيلي / العلاجي</summary>
            <div className="stack" style={{ ["--space" as string]: "12px", marginTop: 8 }}>
              <p className="small alert warn" style={{ margin: 0 }}>{REHAB_DISCLAIMER}</p>
              <fieldset className="field"><legend>التصنيف (يمكن أكثر من واحد)</legend>
                <div className="check-grid">
                  {REHAB_CATEGORIES.map((c) => (
                    <label key={c} className="check"><input type="checkbox" name="rehab_category" value={c} defaultChecked={splitPipes(ex?.rehab_category).includes(c)} /><span>{c}</span></label>
                  ))}
                </div>
              </fieldset>
              <div className="field"><label htmlFor="ex-rgoal">الهدف الحركي أو العلاجي</label>
                <input id="ex-rgoal" name="rehab_goal" type="text" maxLength={300} defaultValue={ex?.rehab_goal ?? ""} /></div>
              <div className="grid g3">
                {sel("rehab_phase", "المرحلة المقترحة", REHAB_PHASES, ex?.rehab_phase)}
                {sel("rehab_load", "مستوى التحميل", REHAB_LOADS, ex?.rehab_load)}
                <div className="field"><label htmlFor="ex-rehab_review">حالة المراجعة العلاجية</label>
                  <select id="ex-rehab_review" name="rehab_review" defaultValue={ex?.rehab_review ?? ""}>
                    <option value="">—</option>
                    {Object.entries(REHAB_REVIEW).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                  </select></div>
              </div>
              <div className="field"><label htmlFor="ex-rsafety">ملاحظات السلامة</label>
                <textarea id="ex-rsafety" name="rehab_safety" maxLength={1000} rows={2} defaultValue={ex?.rehab_safety ?? ""} /></div>
              <div className="field"><label htmlFor="ex-revidence">مصدر الدليل</label>
                <textarea id="ex-revidence" name="rehab_evidence" maxLength={1000} rows={2} dir="auto" defaultValue={ex?.rehab_evidence ?? ""} /></div>
              <div className="field"><label htmlFor="ex-rrefs">روابط المراجع</label>
                <input id="ex-rrefs" name="rehab_refs" type="text" dir="ltr" maxLength={2000} defaultValue={ex?.rehab_refs ?? ""} />
                <span className="hint">أكثر من رابط؟ افصلي بينها بـ « | ».</span></div>
            </div>
          </details>
        </ActionForm>
      </div>
    </div>
  );
}
