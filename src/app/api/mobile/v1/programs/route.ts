import { withAnon } from "@/lib/db";

export const dynamic = "force-dynamic";

// برامج المدربة المجانية لتطبيق الجوال (عامة، بدون دخول). معرّف التمرين بنفس صيغة مكتبة التطبيق
// المضمّنة (mobile/scripts/build-exercises.mjs) حتى يظهر شرحه وفيديوه من الجوال بدون إنترنت.
const slug = (s: string) => s.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");

type Week = { sets?: number; reps?: number[]; rir?: number | null } | null;
type Row = { id: string; name: string; summary: string | null; instructions: string | null; days: { title: string; items: { exercise: string; week1: Week }[] }[] };

function repsText(reps: number[]): string {
  if (reps.length === 0) return "10";
  const lo = Math.min(...reps), hi = Math.max(...reps);
  return lo === hi ? String(lo) : `${lo}-${hi}`;
}

export async function GET() {
  const rows = await withAnon(async (tx) => (await tx.query<{ p: Row[] }>("SELECT app.public_programs() AS p")).rows[0].p);
  const programs = rows.map((p) => ({
    id: p.id,
    name: p.name,
    summary: p.summary,
    instructions: p.instructions,
    days: p.days.map((d) => ({
      title: d.title,
      items: d.items.map((i) => {
        const reps = (i.week1?.reps ?? []).filter((r) => Number.isFinite(r) && r > 0);
        return {
          exercise_id: slug(i.exercise),
          name: i.exercise,
          sets: Math.min(10, Math.max(1, reps.length || Number(i.week1?.sets) || 3)),
          reps: repsText(reps),
          rir: typeof i.week1?.rir === "number" ? i.week1.rir : null,
        };
      }),
    })),
  }));
  return Response.json({ programs }, { headers: { "Cache-Control": "public, max-age=300, s-maxage=300" } });
}
