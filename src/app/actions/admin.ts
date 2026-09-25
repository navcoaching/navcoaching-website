"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { dbErrorMessage, withUser, type Tx } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { cleanUpload, newKey, UploadError } from "@/lib/uploads";
import { storage } from "@/lib/storage";
import { notifySafe } from "@/lib/mail";
import { statusLabel } from "@/lib/status";
import { youtubeId } from "@/lib/youtube";
import type { ActionState } from "./client";

const GENERIC = "تعذّر الحفظ. حاولي مرة أخرى.";

/** تحقق على الخادم أولاً، ثم قاعدة البيانات تتحقق مرة ثانية عبر app.is_coach()/require_coach(). */
async function coach() {
  const u = await getCurrentUser();
  if (!u || u.role !== "coach") throw new Error("forbidden");
  return u;
}

async function asCoach<T>(fn: (tx: Tx, userId: string) => Promise<T>): Promise<T> {
  const u = await coach();
  return withUser(u.id, (tx) => fn(tx, u.id));
}

async function log(tx: Tx, userId: string, action: string, target: string, details?: unknown) {
  await tx.query("INSERT INTO admin_log (actor_id, action, target, details) VALUES ($1,$2,$3,$4)", [userId, action, target, details ? JSON.stringify(details) : null]);
}

const fail = (err: unknown): ActionState => ({ error: dbErrorMessage(err) ?? ((err as Error).message === "forbidden" ? "لا تملكين صلاحية." : GENERIC) });

async function notifyClient(tx: Tx, orderNo: string) {
  const { rows: [o] } = await tx.query(
    `SELECT o.status, o.category, u.email FROM orders o JOIN "user" u ON u.id = o.user_id WHERE o.order_no = $1`, [orderNo]);
  if (!o) return;
  const site = process.env.NEXT_PUBLIC_SITE_URL ?? "";
  await notifySafe(o.email, `تحديث على طلبك ${orderNo}`,
    `حالة طلبك ${orderNo} الآن: ${statusLabel(o.status, o.category)}.\nالتفاصيل والخطوة التالية في حسابك:\n${site}/account/orders/${orderNo}\n\nNav Coaching`);
}

// ---------- الطلبات ----------
export async function transitionAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  const to = String(fd.get("to") ?? "");
  const note = String(fd.get("note") ?? "").trim().slice(0, 500);
  const bank = fd.get("bank_confirmed") === "on";
  try {
    await asCoach(async (tx) => {
      await tx.query("SELECT app.coach_transition($1,$2,$3,$4)", [orderNo, to, note, bank]);
      await notifyClient(tx, orderNo);
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: "تم تحديث الحالة وتسجيلها." };
}

export async function setAmountAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  const amount = Number(fd.get("amount"));
  const note = String(fd.get("note") ?? "").trim().slice(0, 300);
  if (!Number.isFinite(amount) || amount < 0) return { error: "اكتبي مبلغاً صحيحاً." };
  try {
    await asCoach(async (tx) => {
      await tx.query("SELECT app.coach_set_amount($1,$2,$3)", [orderNo, Math.round(amount * 100), note]);
      await notifyClient(tx, orderNo);
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: "تم تأكيد المبلغ." };
}

export async function addDeliverableAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  const title = String(fd.get("title") ?? "").trim().slice(0, 120);
  const url = String(fd.get("url") ?? "").trim();
  const file = fd.get("file") as File | null;
  if (title.length < 2) return { error: "اكتبي عنواناً للملف." };
  try {
    await coach();
    if (file && file.size > 0) {
      const clean = await cleanUpload(file, "deliverable");
      const key = newKey("deliverables", clean.ext);
      await (await storage()).put(key, clean.data, clean.mime);
      await asCoach(async (tx, uid) => {
        await tx.query(
          `INSERT INTO deliverables (order_id, title, kind, storage_key, mime, size_bytes, created_by)
           SELECT id, $2, 'file', $3, $4, $5, $6 FROM orders WHERE order_no = $1`, [orderNo, title, key, clean.mime, clean.size, uid]);
        await log(tx, uid, "deliverable.add", orderNo, { title });
      });
    } else {
      if (!/^https:\/\/\S+$/.test(url)) return { error: "أضيفي ملفاً أو رابطاً يبدأ بـ https://" };
      await asCoach(async (tx, uid) => {
        await tx.query(
          `INSERT INTO deliverables (order_id, title, kind, url, created_by) SELECT id, $2, 'link', $3, $4 FROM orders WHERE order_no = $1`,
          [orderNo, title, url, uid]);
        await log(tx, uid, "deliverable.add", orderNo, { title, url });
      });
    }
  } catch (err) {
    if (err instanceof UploadError) return { error: err.message };
    return fail(err);
  }
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: "تمت الإضافة. تظهر للعميل عندما يكون طلبه نشطاً أو مسلّماً." };
}

export async function removeDeliverableAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const id = String(fd.get("id") ?? "");
  const orderNo = String(fd.get("order_no") ?? "");
  try {
    const key = await asCoach(async (tx, uid) => {
      const { rows: [d] } = await tx.query("DELETE FROM deliverables WHERE id = $1 RETURNING storage_key, title", [id]);
      if (d) await log(tx, uid, "deliverable.remove", orderNo, { title: d.title });
      return d?.storage_key as string | undefined;
    });
    if (key) await (await storage()).remove(key);
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: "تم الحذف." };
}

export async function replyCheckinAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const id = String(fd.get("id") ?? "");
  const orderNo = String(fd.get("order_no") ?? "");
  const reply = String(fd.get("reply") ?? "").trim().slice(0, 2000);
  if (!reply) return { error: "اكتبي الرد." };
  try {
    await asCoach(async (tx) => {
      await tx.query("SELECT app.reply_checkin($1,$2)", [id, reply]);
      const { rows: [o] } = await tx.query(`SELECT u.email FROM orders o JOIN "user" u ON u.id = o.user_id WHERE o.order_no = $1`, [orderNo]);
      await notifySafe(o?.email, `رد المدربة على مراجعتك — ${orderNo}`, `وصلك رد على مراجعتك الأسبوعية. اقرأه من حسابك:\n${process.env.NEXT_PUBLIC_SITE_URL ?? ""}/account/orders/${orderNo}`);
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: "تم إرسال الرد." };
}

// ---------- التقييمات ----------
export async function moderateReviewAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const id = String(fd.get("id") ?? "");
  const action = String(fd.get("action") ?? "");
  const reason = String(fd.get("reason") ?? "").trim().slice(0, 300);
  const reply = String(fd.get("reply") ?? "").trim().slice(0, 1000);
  if (action === "publish" && fd.get("checked") !== "on")
    return { error: "أكدي أن التقييم خالٍ من أرقام الهواتف والبيانات الصحية أو الخاصة قبل النشر." };
  try {
    await asCoach((tx) => tx.query("SELECT app.moderate_review($1,$2,$3,$4)", [id, action, reason, reply]));
  } catch (err) { return fail(err); }
  revalidatePath("/admin/reviews");
  revalidatePath("/");
  revalidatePath("/reviews");
  return { ok: true, message: "تم." };
}

// ---------- المنتجات ----------
const offerSchema = z.object({
  id: z.string().optional().default(""),
  sku: z.string().regex(/^[A-Za-z0-9_-]{1,40}$/, "رمز العرض: حروف إنجليزية وأرقام فقط"),
  label: z.string().trim().min(1, "اسم العرض مطلوب").max(40),
  months: z.coerce.number().int().min(0).max(24),
  price: z.coerce.number().min(0, "السعر غير صالح").max(100000),
  active: z.boolean(),
});
const productSchema = z.object({
  id: z.string().optional().default(""),
  slug: z.string().regex(/^[a-z0-9-]{2,60}$/, "الرابط: حروف إنجليزية صغيرة وأرقام وشرطة فقط"),
  category: z.enum(["follow", "files", "consult"]),
  name: z.string().trim().min(2).max(80),
  audience: z.string().trim().max(300),
  items: z.string().max(4000),
  note: z.string().trim().max(200),
  delivery: z.string().trim().max(600),
  requirements: z.string().trim().max(600),
  policy_note: z.string().trim().max(600),
  recommended: z.boolean(),
  status: z.enum(["draft", "published", "archived"]),
  sort: z.coerce.number().int().min(0).max(999),
  image_id: z.string().optional().default(""),
});

export async function saveProductAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const get = (k: string) => String(fd.get(k) ?? "");
  const parsed = productSchema.safeParse({
    id: get("id"), slug: get("slug"), category: get("category"), name: get("name"), audience: get("audience"),
    items: get("items"), note: get("note"), delivery: get("delivery"), requirements: get("requirements"),
    policy_note: get("policy_note"), recommended: fd.get("recommended") === "on", status: get("status"), sort: get("sort"),
    image_id: get("image_id"),
  });
  if (!parsed.success) return { error: parsed.error.issues[0].message };
  const p = parsed.data;
  // كل سطر عنصر؛ السطر الذي يبدأ بـ "-" يعني «غير مشمول»
  const items = p.items.split("\n").map((l) => l.trim()).filter(Boolean)
    .map((l) => (l.startsWith("-") ? { text: l.replace(/^-\s*/, ""), included: false } : { text: l.replace(/^\+\s*/, ""), included: true }));

  const offers: z.infer<typeof offerSchema>[] = [];
  const skus = fd.getAll("offer_sku");
  for (let i = 0; i < skus.length; i++) {
    if (!String(skus[i]).trim()) continue;
    const o = offerSchema.safeParse({
      id: String(fd.getAll("offer_id")[i] ?? ""), sku: String(skus[i]).trim(), label: String(fd.getAll("offer_label")[i] ?? ""),
      months: String(fd.getAll("offer_months")[i] ?? "0"), price: String(fd.getAll("offer_price")[i] ?? ""),
      active: fd.getAll("offer_active").map(String).includes(String(i)),
    });
    if (!o.success) return { error: o.error.issues[0].message };
    offers.push(o.data);
  }
  if (p.status === "published" && !offers.some((o) => o.active)) return { error: "لا يمكن نشر منتج بدون عرض سعر مفعّل." };

  let id = p.id;
  try {
    await asCoach(async (tx, uid) => {
      const vals = [p.slug, p.category, p.name, p.audience, JSON.stringify(items), p.note || null, p.delivery || null,
        p.requirements || null, p.policy_note || null, p.recommended, p.status, p.sort, p.image_id || null];
      if (id) {
        await tx.query(
          `UPDATE products SET slug=$1, category=$2, name=$3, audience=$4, items=$5, note=$6, delivery=$7, requirements=$8,
             policy_note=$9, recommended=$10, status=$11, sort=$12, image_id=$13, updated_at=now() WHERE id=$14`, [...vals, id]);
      } else {
        id = (await tx.query(
          `INSERT INTO products (slug, category, name, audience, items, note, delivery, requirements, policy_note, recommended, status, sort, image_id)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13) RETURNING id`, vals)).rows[0].id;
      }
      for (const [i, o] of offers.entries()) {
        await tx.query(
          `INSERT INTO product_offers (id, product_id, sku, label, months, price_halalas, active, sort)
           VALUES (coalesce(nullif($1,'')::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, $7, $8)
           ON CONFLICT (id) DO UPDATE SET sku=EXCLUDED.sku, label=EXCLUDED.label, months=EXCLUDED.months,
             price_halalas=EXCLUDED.price_halalas, active=EXCLUDED.active, sort=EXCLUDED.sort`,
          [o.id, id, o.sku, o.label, o.months, Math.round(o.price * 100), o.active, i]);
      }
      await log(tx, uid, "product.save", p.slug, { status: p.status, offers: offers.map((o) => ({ sku: o.sku, price: o.price, active: o.active })) });
    });
  } catch (err) {
    const e = err as { code?: string };
    if (e.code === "23505") return { error: "الرابط أو رمز العرض مستخدم لمنتج آخر." };
    return fail(err);
  }
  revalidatePath("/", "layout");
  if (!p.id) redirect(`/admin/products/${id}?saved=1`);
  return { ok: true, message: "تم حفظ المنتج. الطلبات السابقة تحتفظ بسعرها وقت الطلب." };
}

// ---------- الإعدادات والمحتوى ----------
const lines = (s: string) => s.split("\n").map((l) => l.trim()).filter(Boolean);

export async function saveSettingAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const key = String(fd.get("key") ?? "");
  const g = (k: string) => String(fd.get(k) ?? "").trim();
  let value: unknown;
  switch (key) {
    case "intro_video": {
      const url = g("url");
      if (url && !youtubeId(url)) return { error: "الرابط غير صالح. الصقي رابط YouTube Shorts مثل https://youtube.com/shorts/XXXXXXXXXXX" };
      value = { url, title: g("title").slice(0, 80), body: g("body").slice(0, 400) };
      break;
    }
    case "hero":
      value = { eyebrow: g("eyebrow"), title: g("title"), title_tail: g("title_tail"), lead: g("lead"), tagline: g("tagline") };
      break;
    case "response_time":
      if (g("value").length < 3) return { error: "اكتبي مدة الرد." };
      value = g("value").slice(0, 120);
      break;
    case "contact": {
      const wa = g("whatsapp").replace(/\D/g, "");
      if (!/^\d{9,15}$/.test(wa)) return { error: "رقم واتساب بالصيغة الدولية بدون + مثل 9665XXXXXXXX" };
      const ig = g("instagram");
      if (ig && !/^https:\/\/(www\.)?instagram\.com\/\S+$/.test(ig)) return { error: "رابط انستقرام غير صالح." };
      value = { whatsapp: wa, instagram: ig };
      break;
    }
    case "bank": {
      const iban = g("iban").replace(/\s/g, "").toUpperCase();
      if (!/^SA\d{22}$/.test(iban)) return { error: "الآيبان السعودي يبدأ بـ SA ويتكون من 24 خانة." };
      value = { accountName: g("accountName"), bankName: g("bankName"), iban };
      break;
    }
    case "about":
      value = { name: g("name"), bio: g("bio"), points: lines(g("points")), certs: lines(g("certs")) };
      break;
    case "badges":
      value = lines(g("value")).slice(0, 6);
      break;
    case "checkins":
      value = { enabled: fd.get("enabled") === "on", questions: lines(g("questions")).map((l) => { const [topic, ...q] = l.split("|"); return q.length ? { topic: topic.trim(), q: q.join("|").trim() } : { topic: "", q: topic.trim() }; }) };
      break;
    case "hero_image":
      value = { media_id: g("media_id") || null };
      break;
    default:
      return { error: "إعداد غير معروف." };
  }
  try {
    await asCoach(async (tx, uid) => {
      await tx.query(
        `INSERT INTO site_settings (key, value, updated_by) VALUES ($1,$2,$3)
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now()`,
        [key, JSON.stringify(value), uid]);
      await log(tx, uid, "setting.save", key, key === "bank" ? { iban_last4: (value as { iban: string }).iban.slice(-4) } : value);
    });
  } catch (err) { return fail(err); }
  revalidatePath("/", "layout");
  return { ok: true, message: "تم الحفظ." };
}

export async function saveFaqAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const id = String(fd.get("id") ?? "");
  const q = String(fd.get("question") ?? "").trim();
  const a = String(fd.get("answer") ?? "").trim();
  const sort = Number(fd.get("sort") ?? 0) || 0;
  const published = fd.get("published") === "on";
  const del = fd.get("delete") === "1";
  if (!del && (q.length < 3 || a.length < 3)) return { error: "السؤال والجواب مطلوبان." };
  try {
    await asCoach(async (tx, uid) => {
      if (del) await tx.query("DELETE FROM faqs WHERE id = $1", [id]);
      else if (id) await tx.query("UPDATE faqs SET question=$1, answer=$2, sort=$3, published=$4, updated_at=now() WHERE id=$5", [q, a, sort, published, id]);
      else await tx.query("INSERT INTO faqs (question, answer, sort, published) VALUES ($1,$2,$3,$4)", [q, a, sort, published]);
      await log(tx, uid, del ? "faq.delete" : "faq.save", q || id);
    });
  } catch (err) { return fail(err); }
  revalidatePath("/", "layout");
  return { ok: true, message: del ? "تم الحذف." : "تم الحفظ." };
}

export async function savePolicyAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const slug = String(fd.get("slug") ?? "");
  const title = String(fd.get("title") ?? "").trim();
  const body = String(fd.get("body") ?? "").trim();
  if (title.length < 2 || body.length < 10) return { error: "العنوان والنص مطلوبان." };
  try {
    await asCoach(async (tx, uid) => {
      const r = await tx.query("UPDATE policies SET title=$1, body=$2, updated_at=now() WHERE slug=$3", [title, body, slug]);
      if (!r.rowCount) throw new Error("not found");
      await log(tx, uid, "policy.save", slug);
    });
  } catch (err) { return fail(err); }
  revalidatePath("/", "layout");
  return { ok: true, message: "تم الحفظ." };
}

// ---------- الصور ----------
export async function uploadMediaAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const alt = String(fd.get("alt") ?? "").trim().slice(0, 200);
  const usage = String(fd.get("usage") ?? "gallery");
  const rights = String(fd.get("rights_note") ?? "").trim().slice(0, 300);
  if (!["hero", "about", "gallery", "product"].includes(usage)) return { error: "نوع الاستخدام غير صالح." };
  if (alt.length < 3) return { error: "اكتبي وصفاً للصورة (للقارئ الآلي ومحركات البحث)." };
  if (rights.length < 3) return { error: "اكتبي مصدر الصورة أو إذن النشر (مثال: تصويري الشخصي، أو ترخيص من موقع كذا)." };
  try {
    await coach();
    const clean = await cleanUpload(fd.get("file") as File | null, "image");
    const key = newKey("media", clean.ext);
    await (await storage()).put(key, clean.data, clean.mime);
    await asCoach(async (tx, uid) => {
      await tx.query(
        `INSERT INTO media_assets (storage_key, mime, size_bytes, width, height, alt, usage, rights_note, approved, created_by)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
        [key, clean.mime, clean.size, clean.width ?? null, clean.height ?? null, alt, usage, rights, fd.get("approved") === "on", uid]);
      await log(tx, uid, "media.upload", key, { usage, rights });
    });
  } catch (err) {
    if (err instanceof UploadError) return { error: err.message };
    return fail(err);
  }
  revalidatePath("/admin/media");
  return { ok: true, message: "تم رفع الصورة." };
}

export async function updateMediaAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const id = String(fd.get("id") ?? "");
  const op = String(fd.get("op") ?? "");
  try {
    const key = await asCoach(async (tx, uid) => {
      await log(tx, uid, `media.${op}`, id);
      if (op === "delete") return (await tx.query("DELETE FROM media_assets WHERE id = $1 RETURNING storage_key", [id])).rows[0]?.storage_key as string | undefined;
      await tx.query("UPDATE media_assets SET approved = $1 WHERE id = $2", [op === "approve", id]);
      return undefined;
    });
    if (key) await (await storage()).remove(key);
  } catch (err) { return fail(err); }
  revalidatePath("/", "layout");
  return { ok: true, message: "تم." };
}
