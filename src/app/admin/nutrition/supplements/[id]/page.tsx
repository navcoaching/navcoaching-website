import Link from "next/link";
import { notFound } from "next/navigation";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import ActionForm from "@/components/admin/ActionForm";
import SupplementEditor from "@/components/admin/SupplementEditor";
import { deleteRoutineAction, saveRoutineAction } from "@/app/actions/nutrition";
import { loadRoutine } from "@/lib/nutrition-data";

export default async function RoutinePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ created?: string }> }) {
  const coach = await requireCoach();
  const { id } = await params;
  const { created } = await searchParams;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const data = await withUser(coach.id, async (tx) => {
    const routine = await loadRoutine(tx, { id });
    if (!routine) return null;
    const owner = routine.order_id ? (await tx.query(`SELECT order_no, contact_name FROM orders WHERE id = $1`, [routine.order_id])).rows[0] : null;
    return { routine, owner: owner as { order_no: string; contact_name: string } | null };
  });
  if (!data) notFound();
  const { routine, owner } = data;
  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 1000 }}>
      <nav className="small">
        {owner ? <><Link href={`/admin/orders/${owner.order_no}/nutrition`}>التغذية — {owner.contact_name}</Link> / المكملات</>
          : <><Link href="/admin/nutrition">التغذية والمكملات</Link> / {routine.name}</>}
      </nav>
      <h1>{routine.name}</h1>
      {owner && <p className="alert info">نسخة خاصة بالمتدرب {owner.contact_name}. التعديل هنا يظهر له مباشرة ولا يغيّر القالب.</p>}
      {created && <p className="alert ok" role="status">تم إنشاء الروتين. أضيفي الأقسام والمكملات بالأسفل.</p>}
      <details className="card">
        <summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>الاسم والمقدمة</summary>
        <ActionForm action={saveRoutineAction}>
          <input type="hidden" name="id" value={routine.id} />
          <div className="field"><label htmlFor="rt-name">الاسم</label><input id="rt-name" name="name" type="text" required maxLength={120} defaultValue={routine.name} /></div>
          <div className="field"><label htmlFor="rt-intro">مقدمة (تظهر للمتدرب)</label><textarea id="rt-intro" name="intro" maxLength={2000} rows={2} defaultValue={routine.intro ?? ""} /></div>
        </ActionForm>
        <ActionForm action={deleteRoutineAction} className="form" submit="حذف الروتين" submitClass="btn btn-ghost btn-sm danger" confirm="حذف الروتين نهائياً؟">
          <input type="hidden" name="id" value={routine.id} />
        </ActionForm>
      </details>
      <SupplementEditor routine={routine} />
    </div>
  );
}
