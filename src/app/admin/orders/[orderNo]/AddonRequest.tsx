import { withUser } from "@/lib/db";

type Snapshot = {
  exercise?: string;
  program?: { name: string; days: { title: string; items: { name: string; sets: number; reps: string; target_weight: number | null }[] }[] };
  sessions?: { date: string; title: string; exercises: { name: string; sets: { kind: string; weight: number; reps: number }[] }[] }[];
};

// طلب خدمة إضافية من التطبيق: البرنامج وسجل الجلسات (راجعي جدولي) أو مقطع الفيديو (تصحيح الأداء)
export default async function AddonRequest({ coachId, orderId }: { coachId: string; orderId: string }) {
  const r = await withUser(coachId, async (tx) => (await tx.query(
    `SELECT kind, payload, note, video_key IS NOT NULL AS has_video, video_size, created_at FROM addon_requests WHERE order_id = $1`, [orderId])).rows[0]);
  if (!r) return null;
  const p = (r.payload ?? {}) as Snapshot;
  const title = r.kind === "program_review" ? "راجعي جدولي: برنامج المتدرب وسجله" : r.kind === "form_check" ? "تصحيح أداء تمرين" : "وجباتي";
  return (
    <div className="card stack" data-testid="addon-request" style={{ ["--space" as string]: "10px" }}>
      <h2 style={{ fontSize: 19 }}>{title}</h2>
      {p.exercise && <p style={{ margin: 0 }}><b>التمرين:</b> <bdi>{p.exercise}</bdi></p>}
      {r.note && <p style={{ whiteSpace: "pre-wrap", margin: 0 }}><b>ملاحظة المتدرب:</b> {r.note}</p>}
      {r.has_video && (
        <video controls preload="metadata" playsInline style={{ width: "100%", maxWidth: 420, borderRadius: 12 }} src={`/api/files/addon/${orderId}`} />
      )}
      {p.program && (
        <details open>
          <summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>البرنامج: {p.program.name}</summary>
          {p.program.days.map((d, i) => (
            <div key={i} style={{ marginBlock: 8 }}>
              <b>{d.title}</b>
              <ul style={{ margin: "4px 0" }}>
                {d.items.map((it, j) => <li key={j}><bdi>{it.name}</bdi> — {it.sets} × {it.reps}{it.target_weight != null ? ` · ${it.target_weight} كغ` : ""}</li>)}
              </ul>
            </div>
          ))}
        </details>
      )}
      {p.sessions && p.sessions.length > 0 && (
        <details>
          <summary style={{ cursor: "pointer", minHeight: 40, fontWeight: 700 }}>سجل آخر 4 أسابيع ({p.sessions.length} تمرين)</summary>
          {p.sessions.map((s, i) => (
            <div key={i} style={{ marginBlock: 8 }}>
              <b><bdi className="num">{s.date}</bdi> · {s.title}</b>
              <ul style={{ margin: "4px 0" }}>
                {s.exercises.map((e, j) => (
                  <li key={j}><bdi>{e.name}</bdi>: <bdi dir="ltr">{e.sets.map((x) => `${x.weight}×${x.reps}${x.kind === "warmup" ? "(w)" : ""}`).join("  ")}</bdi></li>
                ))}
              </ul>
            </div>
          ))}
        </details>
      )}
    </div>
  );
}
