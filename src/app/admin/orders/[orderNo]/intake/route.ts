import { requireCoach } from "@/lib/session";
import { getOrderDetail } from "@/lib/data";
import { intakeMarkdown } from "@/lib/intake-export";
import { logSecurity } from "@/lib/ops";

export const dynamic = "force-dynamic";

// تنزيل استبيان المتدرب ملف Markdown (المدربة فقط). فيه بيانات صحية: لا تخزين مؤقت، ويُسجَّل في سجل الأمان.
export async function GET(_req: Request, { params }: { params: Promise<{ orderNo: string }> }) {
  const coach = await requireCoach();
  const { orderNo } = await params;
  if (!/^[A-Z0-9-]{4,40}$/.test(orderNo)) return new Response("Not found", { status: 404 });
  const detail = await getOrderDetail(coach.id, orderNo);
  if (!detail?.intake) return new Response("Not found", { status: 404 });

  await logSecurity("intake_exported", { email: coach.email, userId: coach.id, detail: orderNo });
  return new Response(intakeMarkdown(detail.order, detail.intake), {
    headers: {
      "Content-Type": "text/markdown; charset=utf-8",
      "Content-Disposition": `attachment; filename="intake-${orderNo}.md"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
