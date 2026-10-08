import "server-only";
import { DEFAULT_REMINDERS, daysBetween, riyadhDate, subscriptionState } from "./schedule";
import { loadRenewals } from "./renewal";
import { loadAdherence } from "./program-data";
import { loadWeekState } from "./reminders";
import { cache } from "react";
import { batch, lit, withAnon, withUser } from "./db";

export type Offer = { id: string; sku: string; label: string; months: number; price_halalas: number; currency: string; active: boolean };
export type Product = {
  id: string; slug: string; category: "follow" | "files" | "consult"; name: string; audience: string;
  items: { text: string; included: boolean }[]; note: string | null; delivery: string | null; requirements: string | null;
  policy_note: string | null; recommended: boolean; image_id: string | null; status: string; sort: number; is_demo: boolean;
  offers: Offer[];
};

export type Settings = {
  hero: { eyebrow: string; title: string; title_tail: string; lead: string; tagline: string };
  badges: string[];
  why: { title: string; body: string }[];
  how_steps: { title: string; body: string }[];
  about: {
    name: string; bio: string; home_bio?: string; points: string[]; certs: string[];
    story_title?: string; story?: string[];
    pillars_title?: string; pillars?: { title: string; body: string }[];
    fit_title?: string; fit?: string[];
    notes?: { title: string; body: string; href?: string; label?: string }[];
    experience_title?: string; experience?: string[];
  };
  intro_video: { url: string; title: string; body: string };
  /** مقطع شرح استخدام الموقع بالكامل (يوتيوب، عرضي أو Shorts): قسم كامل في الصفحة الرئيسية */
  guide_video?: { url: string; title?: string; body?: string };
  /** معرّف Google Analytics 4 (G-XXXXXXXXXX). فارغ = معطّل */
  analytics?: { ga_id: string };
  /** أسئلة الاستبيان المعدّلة من لوحة الإدارة (انظر intake-config.ts) */
  intake_questions?: unknown;
  testimonials_disclaimer: string;
  prices_note: string;
  checkins: { enabled: boolean; questions: { topic: string; q: string }[] };
  contact: { whatsapp: string; instagram: string };
  response_time: string;
  legal: { name: string; cr: string };
  bank: { accountName: string; bankName: string; iban: string };
  program_shots: { src: string; w: number; h: number; title: string; caption: string; alt: string }[];
  hero_image?: { media_id: string | null };
  /** الطلب من تطبيق الجوال (الباقات والخدمات الإضافية). غير موجود = مفعّل. مفتاح احتياطي لمراجعة Apple */
  app_ordering?: { enabled: boolean };
};

export const appOrderingOn = (s: Settings) => s.app_ordering?.enabled !== false;
export const APP_ORDERING_OFF = "الطلب من التطبيق متوقف حالياً.";

const PRODUCT_SQL = `
  SELECT p.*, coalesce(json_agg(o ORDER BY o.sort) FILTER (WHERE o.id IS NOT NULL), '[]') AS offers
    FROM products p LEFT JOIN product_offers o ON o.product_id = p.id AND (o.active OR app.is_coach())`;

export const getSettings = cache(async (): Promise<Settings> =>
  withAnon(async (tx) => {
    const { rows } = await tx.query("SELECT key, value FROM site_settings WHERE is_public");
    return Object.fromEntries(rows.map((r) => [r.key, r.value])) as Settings;
  }),
);

export const getProducts = cache(async (): Promise<Product[]> =>
  withAnon(async (tx) => (await tx.query(`${PRODUCT_SQL} WHERE p.status = 'published' GROUP BY p.id ORDER BY p.sort`)).rows),
);

export const getProduct = cache(async (slug: string): Promise<Product | null> =>
  withAnon(async (tx) => (await tx.query(`${PRODUCT_SQL} WHERE p.slug = $1 AND p.status = 'published' GROUP BY p.id`, [slug])).rows[0] ?? null),
);

export async function getOfferBySku(sku: string): Promise<{ product: Product; offer: Offer } | null> {
  const products = await getProducts();
  for (const product of products) {
    const offer = product.offers.find((o) => o.sku === sku);
    if (offer) return { product, offer };
  }
  return null;
}

export const getFaqs = cache(async () =>
  withAnon(async (tx) => (await tx.query("SELECT id, question, answer FROM faqs WHERE published ORDER BY sort")).rows as { id: string; question: string; answer: string }[]),
);

export const getPolicies = cache(async () =>
  withAnon(async (tx) => (await tx.query("SELECT slug, title, body FROM policies ORDER BY sort")).rows as { slug: string; title: string; body: string }[]),
);

export type PublicReview = { id: string; source: string; product_name: string | null; rating: number | null; body: string; display_name: string; period_label: string | null; coach_reply: string | null; created_at: string };
export const getPublicReviews = cache(async (limit?: number): Promise<PublicReview[]> =>
  withAnon(async (tx) =>
    (await tx.query(
      `SELECT * FROM public_reviews ORDER BY (source = 'platform') DESC, created_at DESC, sort LIMIT $1`,
      [limit ?? 500],
    )).rows,
  ),
);

export async function getApprovedMedia(usage: string) {
  return withAnon(async (tx) =>
    (await tx.query("SELECT id, alt, width, height FROM media_assets WHERE approved AND usage = $1 ORDER BY created_at DESC", [usage])).rows as
      { id: string; alt: string; width: number | null; height: number | null }[],
  );
}

// ---------- بيانات العميل (تمر بصلاحيات RLS) ----------
export type OrderRow = {
  /** قبول مجاني بدون دفع (خيار «مجاني» في تحديث الحالة) */
  is_free?: boolean;
  id: string; order_no: string; category: string; product_name: string; offer_label: string; months: number;
  list_price_halalas: number; amount_due_halalas: number | null; currency: string; student_discount_requested: boolean;
  status: string; contact_name: string; contact_phone: string; created_at: string; updated_at: string; paid_at: string | null;
  product_slug?: string | null; user_email?: string; is_demo: boolean; archived_at?: string | null;
  product_id?: string | null; source?: string; sub_start_at?: string | null; sub_end_at?: string | null; review_weekday?: number | null;
  offer_id?: string | null; renewal_of?: string | null; renewal_kind?: string | null; preferred_start?: string | null; video_review?: boolean;
};

export async function getMyOrders(userId: string): Promise<OrderRow[]> {
  return withUser(userId, async (tx) =>
    (await tx.query(
      `SELECT o.*, p.slug AS product_slug FROM orders o LEFT JOIN products p ON p.id = o.product_id
        WHERE o.user_id = $1 ORDER BY o.created_at DESC`, [userId])).rows,
  );
}

export async function getOrderDetail(userId: string, orderNo: string) {
  return withUser(userId, async (tx) => {
    const { rows: [order] } = await tx.query(
      `SELECT o.*, o.preferred_start::text AS preferred_start, p.slug AS product_slug, coalesce(p.video_review, false) AS video_review, u.email AS user_email
         FROM orders o LEFT JOIN products p ON p.id = o.product_id JOIN "user" u ON u.id = o.user_id
        WHERE o.order_no = $1`, [orderNo]);
    if (!order) return null;
    // ستة استعلامات مستقلة في رحلة واحدة (المعاملة الواحدة لا تنفّذ استعلامات متوازية)
    const id = lit(tx, order.id);
    const [events, proofs, deliverables, checkins, review, intake] = await batch(tx, [
      `SELECT * FROM order_events WHERE order_id = ${id} ORDER BY id`,
      `SELECT id, mime, size_bytes, review_status, review_note, created_at, reviewed_at FROM payment_proofs WHERE order_id = ${id} ORDER BY created_at DESC`,
      `SELECT id, title, kind, url, mime, size_bytes, created_at FROM deliverables WHERE order_id = ${id} ORDER BY created_at`,
      `SELECT id, answers, coach_reply, coach_video_url, replied_at, created_at FROM check_ins WHERE order_id = ${id} ORDER BY created_at DESC`,
      `SELECT id, rating, body, display_mode, display_name, consent_publish, status, coach_reply, moderation_reason, created_at FROM reviews WHERE order_id = ${id}`,
      `SELECT answers, health, health_flag, media_consent, consent_terms_at, created_at FROM intakes WHERE order_id = ${id}`,
    ]);
    return {
      order: order as OrderRow & { user_id: string; client_note: string | null },
      events: events.rows as { id: number; actor_id: string | null; from_status: string | null; to_status: string; actor_role: string; note: string | null; created_at: string; client_visible: boolean }[],
      proofs: proofs.rows as { id: string; mime: string; size_bytes: number; review_status: string; review_note: string | null; created_at: string; reviewed_at: string | null }[],
      deliverables: deliverables.rows as { id: string; title: string; kind: string; url: string | null; mime: string | null; size_bytes: number | null; created_at: string }[],
      checkins: checkins.rows as { id: string; answers: { topic: string; q: string; a: string }[]; coach_reply: string | null; coach_video_url: string | null; replied_at: string | null; created_at: string }[],
      review: (review.rows[0] ?? null) as null | { id: string; rating: number | null; body: string; display_mode: string; display_name: string; consent_publish: boolean; status: string; coach_reply: string | null; moderation_reason: string | null; created_at: string },
      intake: (intake.rows[0] ?? null) as null | { answers: Record<string, unknown>; health: Record<string, unknown>; health_flag: boolean; media_consent: string; consent_terms_at: string; created_at: string },
    };
  });
}

/** اشتراك المتدرب وسجل مراجعاته الأسبوعية (يُقرأ بصلاحيته؛ نصوص التذكير لا تُكشف له) */
export async function getMyFollowUp(userId: string, o: { id: string; order_no: string; user_id: string; contact_name: string; product_name: string; status: string; category: string; months: number; list_price_halalas: number; offer_id?: string | null; renewal_kind?: string | null; sub_start_at?: string | null; sub_end_at?: string | null; review_weekday?: number | null }) {
  const start = o.sub_start_at, end = o.sub_end_at;
  if (!start || !end) return null;
  return withUser(userId, async (tx) => {
    const { rows: [{ s }] } = await tx.query("SELECT app.review_schedule() AS s");
    const r = { ...DEFAULT_REMINDERS, ...(s ?? {}) };
    const weeks = await loadWeekState(tx, { ...o, sub_start_at: start, sub_end_at: end, review_weekday: o.review_weekday ?? null }, r);
    const soonDays = Math.max(0, ...r.sub_expiry_days);
    const today = riyadhDate();
    const renewal = (await loadRenewals(tx, [o], () => daysBetween(today, riyadhDate(end)))).get(o.id) ?? null;
    const adherence = o.category === "follow" ? await loadAdherence(tx, { ...o, sub_start_at: start, sub_end_at: end }, r.review_window_days, today) : null;
    return { weeks, soonDays, renewal, adherence, state: subscriptionState({ status: o.status, sub_start_at: start, sub_end_at: end }, soonDays) };
  });
}

export async function getMyPrefs(userId: string) {
  const row = await withUser(userId, async (tx) =>
    (await tx.query("SELECT email_enabled, whatsapp_enabled, push_enabled FROM user_prefs WHERE user_id = $1", [userId])).rows[0]);
  // saved=false: لم يحفظ تفضيلاته بعد (تظهر له بطاقة التفضيلات أعلى «حسابي» مرة واحدة)
  return { ...(row ?? { email_enabled: true, whatsapp_enabled: true, push_enabled: true }), saved: Boolean(row) } as { email_enabled: boolean; whatsapp_enabled: boolean; push_enabled: boolean; saved: boolean };
}

// ---------- الجداول المجانية ----------
export type FreePlan = { id: string; slug: string; title: string; summary: string; audience: string | null; image_id: string | null; owned: boolean };

/** الجداول المنشورة (RLS تمنع المخفية)، مع حالة «موجود في جداولي» للمستخدم الحالي */
export async function getFreePlans(userId: string | null, slug?: string): Promise<FreePlan[]> {
  const run = async (tx: import("./db").Tx) => (await tx.query(
    `SELECT p.id, p.slug, p.title, p.summary, p.audience, p.image_id,
            ${userId ? "EXISTS (SELECT 1 FROM free_plan_requests r WHERE r.plan_id = p.id AND r.user_id = $2)" : "false"} AS owned
       FROM free_plans p
      WHERE p.status = 'published' AND ($1::text IS NULL OR p.slug = $1)
      ORDER BY p.sort, p.created_at`, userId ? [slug ?? null, userId] : [slug ?? null])).rows as FreePlan[];
  return userId ? withUser(userId, run) : withAnon(run);
}

export type MyFreePlan = { request_id: string; requested_at: string; slug: string; title: string; summary: string; has_file: boolean };
export async function getMyFreePlans(userId: string): Promise<MyFreePlan[]> {
  return withUser(userId, async (tx) => (await tx.query("SELECT * FROM app.my_free_plans()")).rows as MyFreePlan[]);
}

export type MyBooklet = { id: string; title: string; description: string | null; file_size: number };
/** الكتيبات المتاحة للمتدرب (RLS: المنشورة لمن عنده اشتراك) */
export async function getMyBooklets(userId: string): Promise<MyBooklet[]> {
  return withUser(userId, async (tx) => (await tx.query(
    `SELECT id, title, description, file_size FROM booklets WHERE published ORDER BY sort, created_at`)).rows as MyBooklet[]);
}

/** أول طلب فعّال أو مكتمل لم يكتب عليه المتدرب تقييماً بعد (لبطاقة «قيّم تجربتك» في حسابي) */
export async function getReviewableOrder(userId: string): Promise<{ order_no: string; product_name: string } | null> {
  return withUser(userId, async (tx) => (await tx.query(
    `SELECT o.order_no, o.product_name FROM orders o
      WHERE o.user_id = $1 AND o.status IN ('active', 'delivered', 'completed')
        AND NOT EXISTS (SELECT 1 FROM reviews r WHERE r.order_id = o.id)
      ORDER BY o.created_at DESC LIMIT 1`, [userId])).rows[0] ?? null);
}

/** هل عنده استبيان محفوظ (بدون طلب أو مع طلب)؟ لتسمية الزر: «تعبئة» أو «تحديث» */
export async function hasIntake(userId: string): Promise<boolean> {
  return withUser(userId, async (tx) => (await tx.query(
    `SELECT EXISTS (SELECT 1 FROM member_profiles WHERE user_id = $1) OR EXISTS (SELECT 1 FROM intakes WHERE user_id = $1) AS x`, [userId])).rows[0].x as boolean);
}
