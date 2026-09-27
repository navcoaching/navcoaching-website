import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { EQUIPMENT, EX_STATUS, LEVELS, MUSCLES, muscleAr, type ExStatus } from "@/lib/exercises";

type SP = { q?: string; muscle?: string; equipment?: string; level?: string; status?: string; place?: string };
type Row = { id: string; name: string; primary_muscle: string; pattern: string | null; equipment: string | null; place: string | null; level: string | null; status: ExStatus; video_url: string | null; alts: number };

const STATUS_CLASS: Record<ExStatus, string> = { approved: "ok", review: "action", rejected: "muted" };

/** مكتبة التمارين — المصدر الوحيد لتمارين القوالب والبدائل */
export default async function Exercises({ searchParams }: { searchParams: Promise<SP> }) {
  const coach = await requireCoach();
  const sp = await searchParams;
  const q = (sp.q ?? "").trim().slice(0, 80);
  const pick = (v: string | undefined, list: readonly string[]) => (v && list.includes(v) ? v : "");
  const f = {
    muscle: pick(sp.muscle, MUSCLES), equipment: pick(sp.equipment, EQUIPMENT), level: pick(sp.level, LEVELS),
    status: pick(sp.status, Object.keys(EX_STATUS)), place: pick(sp.place, ["نادي", "منزل", "بدون معدات"]),
  };
  const { rows, stats } = await withUser(coach.id, async (tx) => ({
    rows: (await tx.query(
      `SELECT e.id, e.name, e.primary_muscle, e.pattern, e.equipment, e.place, e.level, e.status, e.video_url,
              (SELECT count(*)::int FROM exercise_alternatives a WHERE a.exercise_id = e.id) AS alts
         FROM exercises e
        WHERE ($1 = '' OR e.name ILIKE '%' || $1 || '%' OR e.pattern ILIKE '%' || $1 || '%')
          AND ($2 = '' OR e.primary_muscle = $2) AND ($3 = '' OR e.equipment = $3) AND ($4 = '' OR e.level = $4)
          AND ($5 = '' OR e.status = $5) AND ($6 = '' OR e.place = $6)
        ORDER BY array_position($7::text[], e.primary_muscle), e.name`,
      [q, f.muscle, f.equipment, f.level, f.status, f.place, MUSCLES])).rows as Row[],
    stats: (await tx.query(
      `SELECT count(*)::int AS total, count(*) FILTER (WHERE status = 'approved')::int AS approved,
              count(*) FILTER (WHERE status = 'review')::int AS review, count(*) FILTER (WHERE video_url IS NOT NULL)::int AS video
         FROM exercises`)).rows[0] as { total: number; approved: number; review: number; video: number },
  }));
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
      <form className="filters" role="search">
        <div className="field"><label htmlFor="ex-q">بحث بالاسم</label><input id="ex-q" name="q" type="search" dir="auto" defaultValue={q} /></div>
        {sel("muscle", "العضلة الأساسية", MUSCLES.map((m) => [m, muscleAr(m)] as [string, string]))}
        {sel("equipment", "المعدات", EQUIPMENT)}
        {sel("place", "المكان", ["نادي", "منزل", "بدون معدات"])}
        {sel("level", "المستوى", LEVELS)}
        {sel("status", "المراجعة", Object.entries(EX_STATUS) as [string, string][])}
        <button className="btn btn-sm">عرض</button>
      </form>
      <p className="small muted" data-testid="ex-count">{rows.length} تمرين</p>
      <div className="table-wrap">
        <table className="t" data-testid="admin-exercises">
          <thead><tr><th>التمرين</th><th>العضلة الأساسية</th><th>المعدات</th><th>المستوى</th><th>المراجعة</th><th>بدائل</th><th><span className="sr-only">إجراء</span></th></tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={7} className="muted">لا توجد نتائج.</td></tr>}
            {rows.map((e) => (
              <tr key={e.id}>
                <td><bdi dir="ltr"><b>{e.name}</b></bdi>{e.video_url && <> <a href={e.video_url} target="_blank" rel="noopener noreferrer" className="small" aria-label={`فيديو ${e.name}`}>▶</a></>}
                  {e.pattern && <div className="small muted">{e.pattern.split(" / ")[1] ?? e.pattern}</div>}</td>
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
