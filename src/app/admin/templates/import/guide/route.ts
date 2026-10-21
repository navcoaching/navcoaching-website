import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import { programGuide } from "@/lib/program-import";

export const dynamic = "force-dynamic";

// دليل صيغة الاستيراد مع أسماء التمارين المعتمدة في المكتبة الآن (المدربة فقط)
export async function GET() {
  const coach = await requireCoach();
  const exercises = await withUser(coach.id, async (tx) => (await tx.query(
    `SELECT name, primary_muscle, place FROM exercises WHERE status = 'approved' ORDER BY name`)).rows);
  return new Response(programGuide(exercises), {
    headers: {
      "Content-Type": "text/markdown; charset=utf-8",
      "Content-Disposition": `attachment; filename="nav-program-format.md"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
