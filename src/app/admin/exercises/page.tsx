import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { EQUIPMENT, EX_STATUS, LEVELS, TAXONOMY_LEVELS, arPart, cascade, muscleAr, type ExStatus, type TaxonomyKey } from "@/lib/exercises";
import VideoCheck from "@/components/admin/VideoCheck";
import AutoSubmitForm from "@/components/admin/AutoSubmitForm";

type SP = Partial<Record<TaxonomyKey | "q" | "equipment" | "level" | "status" | "place", string>>;
type Row = {
  id: string; name: string; primary_muscle: string; pattern: string | null; sub_pattern: string | null; anatomical_action: string | null; movement_subcategory: string | null;
  equipment: string | null; place: string | null; level: string | null; status: ExStatus; video_url: string | null; alts: number;
};

const STATUS_CLASS: Record<ExStatus, string> = { approved: "ok", review: "action", rejected: "muted" };

/** مكتبة التمارين — المصدر الوحيد لتمارين القوالب والبدائل */
export default async function Exercises({ searchParams }: { searchParams: Promise<SP> }) {
  const coach = await requireCoach();
  const sp = await searchParams;
  const q = (sp.q ?? "").trim().slice(0, 80);
  const pick = (v: string | undefined, list: readonly string[]) => (v && list.includes(v) ? v : "");
  const f = {
    equipment: pick(sp.equipment, EQUIPMENT), level: pick(sp.level, LEVELS),
    status: pick(sp.status, Object.keys(EX_STATUS)), place: pick(sp.place, ["نادي", "منزل", "بدون معدات"]),
  };
  const { all, stats } = await withUser(coach.id, async (tx) => ({
    all: (await tx.query(
      `SELECT e.id, e.name, e.primary_muscle, e.pattern, e.sub_pattern, e.anatomical_action, e.movement_subcategory,
              e.equipment, e.place, e.level, e.status, e.video_url,
              (SELECT count(*)::int FROM exercise_alternatives a WHERE a.exercise_id = e.id) AS alts
         FROM exercises e ORDER BY e.name`)).rows as Row[],
    stats: (await tx.query(
      `SELECT count(*)::int AS total, count(*) FILTER (WHERE status = 'approved')::int AS approved,
              count(*) FILTER (WHERE status = 'review')::int AS review, count(*) FILTER (WHERE video_url IS NOT NULL)::int AS video
         FROM exercises`)).rows[0] as { total: number; approved: number; review: number; video: number },
  }));
  // التصفية المتسلسلة: العضلة ← النمط ← النمط الفرعي ← الحركة التشريحية ← التصنيف الفرعي
  const chosen = Object.fromEntries(TAXONOMY_LEVELS.map(({ key }) => [key, sp[key] ?? ""]).filter(([, v]) => v)) as Partial<Record<TaxonomyKey, string>>;
  const { options, matches, applied } = cascade(all, chosen);
  const ql = q.toLowerCase();
  const rows = matches.filter((e) =>
    (!ql || e.name.toLowerCase().includes(ql) || (e.pattern ?? "").toLowerCase().includes(ql) || (e.sub_pattern ?? "").toLowerCase().includes(ql))
    && (!f.equipment || e.equipment === f.equipment) && (!f.level || e.level === f.level)
    && (!f.status || e.status === f.status) && (!f.place || e.place === f.place));
  const sel = (name: keyof typeof f, label: string, opts: readonly (string | [string, string])[]) => (
    <div className="field"><label htmlFor={`ex-${name}`}>{label}</label>
      <select id={`ex-${name}`} name={name} defaultValue={f[name]}>
        <option value="">الكل</option>
        {opts.map((o) => { const [v, l] = Array.isArray(o) ? o : [o, o]; return <option key={v} value={v}>{l}</option>; })}
      </select></div>
  );

  return (
    <div className="stack" style={{ ["--space" as string]: "18px" }}>
      <div className="row" style={{ justifyContent: "space-between" }}>
        <h1>مكتبة التمارين</h1>
        <Link className="btn btn-sm" href="/admin/exercises/new">+ تمرين جديد</Link>
      </div>
      <p className="muted">المعتمد فقط يظهر في القوائم عند بناء القوالب وفي بدائل المتدرب. المتدرب يرى الاسم والفيديو وتعليمات الأداء فقط، ولا يرى الملاحظات والمصادر.</p>
      <div className="grid g4">
        <div className="card stat"><span className="muted">كل التمارين</span><b>{stats.total}</b></div>
        <div className="card stat"><span className="muted">معتمد</span><b>{stats.approved}</b></div>
        <div className="card stat"><span className="muted">يحتاج مراجعة</span><b>{stats.review}</b></div>
        <div className="card stat"><span className="muted">فيها فيديو</span><b>{stats.video}</b></div>
      </div>
      <VideoCheck />
      <AutoSubmitForm className="filters ex-filters">
        <div className="field"><label htmlFor="ex-q">بحث بالاسم</label><input id="ex-q" name="q" type="search" dir="auto" defaultValue={q} /></div>
        {TAXONOMY_LEVELS.map(({ key, label }, i) => (
          <div key={key} className="field"><label htmlFor={`ex-${key}`}><span className="picker-step">{i + 1}</span> {label}</label>
            <select id={`ex-${key}`} name={key} defaultValue={applied[key] ?? ""} disabled={options[key].length === 0} key={`${key}-${applied[key] ?? ""}`}>
              <option value="">الكل</option>
              {options[key].map((o) => <option key={o.value} value={o.value}>{o.value} ({o.count})</option>)}
            </select></div>
        ))}
        {sel("equipment", "المعدات", EQUIPMENT)}
        {sel("place", "المكان", ["نادي", "منزل", "بدون معدات"])}
        {sel("level", "المستوى", LEVELS)}
        {sel("status", "المراجعة", Object.entries(EX_STATUS) as [string, string][])}
        <button className="btn btn-sm">عرض</button>
      </AutoSubmitForm>
      <p className="small muted" data-testid="ex-count">{rows.length} تمرين</p>
      <div className="table-wrap">
        <table className="t" data-testid="admin-exercises">
          <thead><tr><th>التمرين</th><th>العضلة الأساسية</th><th>المعدات</th><th>المستوى</th><th>المراجعة</th><th>بدائل</th><th><span className="sr-only">إجراء</span></th></tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={7} className="muted">لا توجد نتائج.</td></tr>}
            {rows.map((e) => (
              <tr key={e.id}>
                <td><bdi dir="ltr"><b>{e.name}</b></bdi>{e.video_url && <> <a href={e.video_url} target="_blank" rel="noopener noreferrer" className="small" aria-label={`فيديو ${e.name}`}>▶</a></>}
                  {e.pattern && <div className="small muted">{arPart(e.pattern)}{e.sub_pattern ? ` · ${arPart(e.sub_pattern)}` : ""}</div>}
                  {e.anatomical_action && <div className="small muted">{arPart(e.anatomical_action)}</div>}</td>
                <td>{muscleAr(e.primary_muscle)}</td>
                <td className="small">{e.equipment ?? "—"}{e.place && <div className="muted">{e.place}</div>}</td>
                <td className="small">{e.level ?? "—"}</td>
                <td><span className={`status ${STATUS_CLASS[e.status]}`}>{EX_STATUS[e.status]}</span></td>
                <td className="num">{e.alts}</td>
                <td><Link className="btn btn-ghost btn-sm" href={`/admin/exercises/${e.id}`}>تعديل</Link></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
