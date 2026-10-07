import { getApprovedMedia, getFaqs, getFreePlans, getPolicies, getProducts, getPublicReviews, getSettings } from "@/lib/data";

export const dynamic = "force-dynamic";

// محتوى الموقع العام للتطبيق (البرامج، عن المدربة، التقييمات، الأسئلة، السياسات، الجداول المجانية).
// حقول محددة فقط من الإعدادات العامة (بدون بيانات البنك أو التحليلات).
export async function GET() {
  const [s, products, faqs, policies, reviews, freePlans, photos] = await Promise.all([
    getSettings(), getProducts(), getFaqs(), getPolicies(), getPublicReviews(60), getFreePlans(null), getApprovedMedia("about"),
  ]);
  return Response.json({
    hero: s.hero, badges: s.badges, why: s.why, how_steps: s.how_steps, about: s.about,
    prices_note: s.prices_note, testimonials_disclaimer: s.testimonials_disclaimer,
    contact: s.contact, response_time: s.response_time, legal: s.legal, intro_video: s.intro_video,
    // صور المدربة المعتمدة (تُعرض من /api/files/media/<id>)
    about_photos: (photos as { id: string; alt?: string }[]).slice(0, 6).map((m) => ({ id: m.id, alt: m.alt ?? "" })),
    // البرامج المعروضة في صفحة البرامج (بدون الخدمات الإضافية للتطبيق وبدون منتجات التطوير)
    products: products.filter((p) => !p.is_demo && !(p as { app_addon?: string | null }).app_addon).map((p) => ({
      slug: p.slug, category: p.category, name: p.name, audience: p.audience, items: p.items, note: p.note, delivery: p.delivery,
      requirements: p.requirements, policy_note: p.policy_note, recommended: p.recommended, image_id: p.image_id,
      offers: p.offers.filter((o) => o.active).map((o) => ({ sku: o.sku, label: o.label, months: o.months, price_halalas: o.price_halalas })),
    })),
    faqs: faqs.map((f) => ({ q: f.question, a: f.answer })),
    policies,
    reviews: reviews.map((r) => ({ id: r.id, rating: r.rating, body: r.body, name: r.display_name, product: r.product_name, period: r.period_label, reply: r.coach_reply, source: r.source })),
    free_plans: freePlans.map((p) => ({ slug: p.slug, title: p.title, summary: p.summary, audience: p.audience, image_id: p.image_id })),
  }, { headers: { "Cache-Control": "public, max-age=300, s-maxage=300" } });
}
