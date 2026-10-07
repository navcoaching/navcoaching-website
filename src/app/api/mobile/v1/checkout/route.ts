import { getCurrentUser } from "@/lib/session";
import { getProducts, getSettings } from "@/lib/data";
import { CATEGORY_LABEL } from "@/lib/format";
import { AGE_MAX, AGE_MIN, NUTRITION_SKUS, OPT } from "@/lib/intake";
import { activeCustom, BUILTIN_QUESTIONS, hintOf, isHidden, labelOf, parseConfig } from "@/lib/intake-config";
import { startPrefRange } from "@/lib/schedule";

export const dynamic = "force-dynamic";

// استبيان الطلب لتطبيق الجوال: نفس أسئلة الموقع وخياراته ونصوص لوحة الإدارة، حتى لا تُنسخ في التطبيق.
// الإرسال عبر عملية create-order (نفس تحقق الموقع وقاعدة البيانات). الدفع بتحويل بنكي: خدمة تدريب شخصية (Apple 3.1.3(d)).
export async function GET(req: Request) {
  const user = await getCurrentUser().catch(() => null);
  if (!user) return Response.json({ error: "login" }, { status: 401 });
  const sku = new URL(req.url).searchParams.get("sku") ?? "";
  const [products, s] = await Promise.all([getProducts(), getSettings()]);
  // الباقات فقط: لا الخدمات الإضافية (لها مسارها) ولا التجريبية
  const list = products.filter((p) => !p.is_demo && !(p as { app_addon?: string | null }).app_addon);
  const offers = list.flatMap((p) => p.offers.filter((o) => o.active).map((o) => ({
    sku: o.sku, product: p.name, label: o.label, group: CATEGORY_LABEL[p.category] ?? "", price_halalas: o.price_halalas,
  })));
  if (!offers.some((o) => o.sku === sku)) return Response.json({ error: "الباقة غير متاحة." }, { status: 404 });
  const cfg = parseConfig(s.intake_questions);
  return Response.json({
    sku,
    offers,
    defaultName: user.name.includes("@") ? "" : user.name,
    email: user.email,
    responseTime: s.response_time,
    opt: OPT, ageMin: AGE_MIN, ageMax: AGE_MAX, nutritionSkus: NUTRITION_SKUS,
    questions: Object.fromEntries(BUILTIN_QUESTIONS.map((q) => [q.key, { label: labelOf(cfg, q.key), hint: hintOf(cfg, q.key), hidden: isHidden(cfg, q.key) }])),
    custom: activeCustom(cfg).map(({ id, step, type, label, hint, options, required }) => ({ id, step, type, label, hint, options, required })),
    startRange: startPrefRange(),
  }, { headers: { "Cache-Control": "private, no-store" } });
}
