"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { dbErrorMessage, withUser, type Tx } from "@/lib/db";
import { getFreshUser } from "@/lib/session";
import { cleanUpload, newKey, UploadError } from "@/lib/uploads";
import { storage } from "@/lib/storage";
import { CHANNEL_LABEL, RESULT_LABEL, notifyTrainee, type ChannelResult } from "@/lib/notify";
import { loadReminders, loadWeekState, reviewMessage } from "@/lib/reminders";
import { loadAdherence } from "@/lib/program-data";
import { statusLabel } from "@/lib/status";
import { addDays } from "@/lib/schedule";
import { youtubeId } from "@/lib/youtube";
import { configFromForm, parseConfig } from "@/lib/intake-config";
import type { ActionState } from "./client";

const GENERIC = "تعذّر الحفظ. حاولي مرة أخرى.";

/** تحقق على الخادم أولاً، ثم قاعدة البيانات تتحقق مرة ثانية عبر app.is_coach()/require_coach(). */
async function coach() {
  const u = await getFreshUser();
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

async function orderTarget(tx: Tx, orderNo: string) {
  const { rows: [o] } = await tx.query(
    `SELECT id, order_no, user_id, status, category, contact_name FROM orders WHERE order_no = $1`, [orderNo]);
  return o as { id: string; order_no: string; user_id: string; status: string; category: string; contact_name: string } | undefined;
}

/** ملخص نتيجة الإشعار لكل قناة، يظهر للمدربة بعد الإجراء */
function summarize(results: ChannelResult[]) {
  if (!results.length) return "";
  return " الإشعار: " + results.map((r) => `${CHANNEL_LABEL[r.channel]} — ${RESULT_LABEL[r.status]}${r.detail ? ` (${r.detail})` : ""}`).join("، ") + ".";
}

async function notifyStatus(tx: Tx, orderNo: string, note?: string) {
  const o = await orderTarget(tx, orderNo);
  if (!o) return [];
  return notifyTrainee(tx, { orderId: o.id, orderNo, userId: o.user_id }, {
    kind: "status", subject: `تحديث على طلبك ${orderNo}`,
    text: `حالة طلبك ${orderNo} الآن: ${statusLabel(o.status, o.category)}.`, note,
  });
}

// ---------- الطلبات ----------
export async function transitionAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  const to = String(fd.get("to") ?? "");
  const note = String(fd.get("note") ?? "").trim().slice(0, 500);
  const bank = fd.get("bank_confirmed") === "on";
  const date = (k: string) => { const v = String(fd.get(k) ?? ""); return /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null; };
  let results: ChannelResult[] = [];
  try {
    results = await asCoach(async (tx) => {
      // «مجاني»: قبول بدون دفع، ويتفعّل في المدة المحددة (بداية ونهاية) لاشتراكات المتابعة
      if (to === "free") await tx.query("SELECT app.coach_accept_free($1,$2,$3,$4)", [orderNo, date("free_start"), date("free_end"), note]);
      else await tx.query("SELECT app.coach_transition($1,$2,$3,$4)", [orderNo, to, note, bank]);
      return notifyStatus(tx, orderNo, note);
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}`);
  revalidatePath("/admin/orders");
  revalidatePath("/admin");
  return { ok: true, message: (to === "free" ? "تم قبول الطلب مجاناً وتسجيله." : "تم تحديث الحالة وتسجيلها.") + summarize(results) };
}

export async function setAmountAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  const amount = Number(fd.get("amount"));
  const note = String(fd.get("note") ?? "").trim().slice(0, 300);
  if (!Number.isFinite(amount) || amount < 0) return { error: "اكتبي مبلغاً صحيحاً." };
  let results: ChannelResult[] = [];
  try {
    results = await asCoach(async (tx) => {
      await tx.query("SELECT app.coach_set_amount($1,$2,$3)", [orderNo, Math.round(amount * 100), note]);
      return notifyStatus(tx, orderNo, note);
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: "تم تأكيد المبلغ." + summarize(results) };
}

export async function addDeliverableAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  const title = String(fd.get("title") ?? "").trim().slice(0, 120);
  const url = String(fd.get("url") ?? "").trim();
  const file = fd.get("file") as File | null;
  if (title.length < 2) return { error: "اكتبي عنواناً للملف." };
  let results: ChannelResult[] = [];
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
    // الإشعار فقط إذا كان المتدرب يستطيع فتح المحتوى الآن (طلب نشط أو مسلّم أو مكتمل)
    results = await asCoach(async (tx) => {
      const o = await orderTarget(tx, orderNo);
      if (!o || !["active", "delivered", "completed"].includes(o.status)) return [];
      return notifyTrainee(tx, { orderId: o.id, orderNo, userId: o.user_id }, {
        kind: "deliverable", subject: "محتوى جديد في برنامجك", text: "أضافت المدربة ملفاً أو رابطاً جديداً لبرنامجك." });
    });
  } catch (err) {
    if (err instanceof UploadError) return { error: err.message };
    return fail(err);
  }
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: (results.length ? "تمت الإضافة." : "تمت الإضافة. تظهر للعميل عندما يكون طلبه نشطاً أو مسلّماً، ويُشعَر عند التفعيل.") + summarize(results) };
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
  const video = String(fd.get("video_url") ?? "").trim();
  if (!reply && !video) return { error: "اكتبي الرد أو أضيفي رابط الفيديو." };
  if (video && (!/^https:\/\/\S+$/.test(video) || video.length > 500)) return { error: "رابط الفيديو لازم يبدأ بـ https://" };
  let results: ChannelResult[] = [];
  try {
    results = await asCoach(async (tx) => {
      await tx.query("SELECT app.reply_checkin($1,$2,$3)", [id, reply, video]);
      const o = await orderTarget(tx, orderNo);
      if (!o) return [];
      return notifyTrainee(tx, { orderId: o.id, orderNo, userId: o.user_id }, {
        kind: "checkin_reply", subject: `رد المدربة على مراجعتك — ${orderNo}`, text: video ? "وصلك رد من المدربة على مراجعتك الأسبوعية، ومعه فيديو شرح." : "وصلك رد من المدربة على مراجعتك الأسبوعية." });
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: "تم إرسال الرد." + summarize(results) };
}

/** رسالة من المدربة للمتدرب: تظهر في صفحة طلبه، والتنبيه بدون نص الرسالة (قد تكون فيها معلومات صحية) */
export async function coachMessageAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  const text = String(fd.get("text") ?? "").trim().slice(0, 2000);
  if (text.length < 2) return { error: "اكتبي الرسالة." };
  let results: ChannelResult[] = [];
  try {
    results = await asCoach(async (tx) => {
      await tx.query("SELECT app.coach_message($1,$2)", [orderNo, text]);
      const o = await orderTarget(tx, orderNo);
      if (!o) return [];
      return notifyTrainee(tx, { orderId: o.id, orderNo, userId: o.user_id }, {
        kind: "coach_message", subject: `رسالة من المدربة — ${orderNo}`, text: "وصلتك رسالة من المدربة. افتح صفحة طلبك لقراءتها." });
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: "أُرسلت الرسالة." + summarize(results) };
}

// ---------- المتابعة ----------
export async function addNoteAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  const body = String(fd.get("body") ?? "").trim();
  if (!body) return { error: "اكتبي الملاحظة أولاً." };
  if (body.length > 5000) return { error: "الملاحظة أطول من 5000 حرف." };
  try {
    await asCoach((tx) => tx.query("SELECT app.coach_add_note($1,$2)", [orderNo, body]));
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}`);
  revalidatePath("/admin/orders");
  return { ok: true, message: "أُضيفت الملاحظة." };
}

export async function deleteNoteAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  const id = Number(fd.get("id"));
  if (!Number.isInteger(id) || id <= 0) return { error: GENERIC };
  try {
    await asCoach((tx) => tx.query("SELECT app.coach_delete_note($1)", [id]));
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: "حُذفت الملاحظة." };
}

export async function setSubscriptionAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  const start = String(fd.get("start") ?? "");
  let end = String(fd.get("end") ?? "");
  let wd = String(fd.get("weekday") ?? "");
  const auto = fd.get("auto") === "on";
  if (!/^\d{4}-\d{2}-\d{2}$/.test(start) || (!auto && !/^\d{4}-\d{2}-\d{2}$/.test(end))) return { error: "اختاري تاريخ البدء والانتهاء." };
  try {
    await asCoach(async (tx) => {
      if (auto) {
        // بالأسابيع من أول يوم: الشهر = 4 أسابيع، ويوم المراجعة = يوم البداية
        const { rows: [o] } = await tx.query("SELECT months FROM orders WHERE order_no = $1", [orderNo]);
        const months = Math.max(1, Number(o?.months ?? 1));
        end = addDays(start, 28 * months);
        wd = String(new Date(`${start}T00:00:00Z`).getUTCDay());
      }
      // التاريخ يُفسَّر بتوقيت الرياض (+03:00)
      await tx.query("SELECT app.coach_set_subscription($1,$2,$3,$4)",
        [orderNo, `${start}T00:00:00+03:00`, `${end}T23:59:00+03:00`, wd === "" ? null : Number(wd)]);
    });
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: "حُفظت تواريخ الاشتراك." };
}

export async function markWeekAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  const week = Number(fd.get("week"));
  const done = fd.get("done") === "1";
  try {
    await asCoach((tx) => tx.query("SELECT app.coach_mark_week($1,$2,$3)", [orderNo, week, done]));
  } catch (err) { return fail(err); }
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: done ? "عُلّم الأسبوع كمكتمل." : "أُلغيت العلامة." };
}

/** زر «إرسال تنبيه المراجعة الآن»: نفس النص المعروض في المعاينة، مع فترة تباعد لمنع التكرار */
export async function sendReviewNowAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  try {
    const out = await asCoach(async (tx) => {
      const o = await orderTarget(tx, orderNo);
      if (!o) return { error: "الطلب غير موجود." };
      const r = await loadReminders(tx);
      const { rows: [recent] } = await tx.query(
        `SELECT created_at FROM notification_log WHERE order_id = $1 AND kind = 'review_manual' AND created_at > now() - make_interval(mins => $2) ORDER BY id DESC LIMIT 1`,
        [o.id, r.manual_cooldown_minutes]);
      if (recent) return { error: `أُرسل تنبيه لهذا المتدرب قبل أقل من ${r.manual_cooldown_minutes} دقائق. انتظري قليلاً.` };
      const { rows: [sub] } = await tx.query("SELECT sub_start_at, sub_end_at, review_weekday FROM orders WHERE id = $1", [o.id]);
      const weeks = sub?.sub_start_at ? await loadWeekState(tx, { ...o, product_name: "", ...sub }, r) : [];
      const next = weeks.find((w) => w.status !== "done" && w.status !== "missed") ?? weeks.find((w) => w.status !== "done");
      const text = reviewMessage(r, o.contact_name.trim().split(/\s+/)[0], next);
      const results = await notifyTrainee(tx, { orderId: o.id, orderNo, userId: o.user_id }, { kind: "review_manual", subject: "تذكير بالمراجعة الأسبوعية", text });
      return { results };
    });
    if ("error" in out) return { error: out.error };
    revalidatePath(`/admin/orders/${orderNo}`);
    const failed = out.results.every((x) => x.status === "failed" || x.status === "skipped");
    return { ok: !failed, error: failed ? "لم يُرسل التنبيه عبر أي قناة." + summarize(out.results) : undefined, message: "تم." + summarize(out.results) };
  } catch (err) { return fail(err); }
}

/** طلب تحديث الوزن والطول من متدرب أرسل الاستبيان قبل أن يصبحا إلزاميين */
export async function requestMeasurementsAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  let results: ChannelResult[] = [];
  try {
    results = await asCoach(async (tx) => {
      const o = await orderTarget(tx, orderNo);
      if (!o) return [];
      return notifyTrainee(tx, { orderId: o.id, orderNo, userId: o.user_id }, {
        kind: "measurements", subject: "طلب تحديث بياناتك", text: "نحتاج وزنك وطولك الحاليين لتحديث برنامجك. تقدر تضيفها من صفحة طلبك." });
    });
  } catch (err) { return fail(err); }
  return { ok: true, message: "أُرسل الطلب." + summarize(results) };
}

export async function archiveOrderAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  const archive = fd.get("archive") === "1";
  try {
    await asCoach((tx) => tx.query("SELECT app.coach_archive_order($1,$2)", [orderNo, archive]));
  } catch (err) { return fail(err); }
  revalidatePath("/admin/orders");
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: archive ? "أُخفي الطلب من القائمة." : "رجع الطلب للقائمة." };
}

export async function deleteOrderAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  if (String(fd.get("confirm") ?? "").trim() !== orderNo) return { error: "اكتبي رقم الطلب كما هو للتأكيد." };
  let keys: string[] = [];
  try {
    keys = await asCoach(async (tx) => (await tx.query("SELECT app.coach_delete_order($1) AS k", [orderNo])).rows[0].k ?? []);
  } catch (err) { return fail(err); }
  const store = await storage();
  await Promise.all(keys.map((k) => store.remove(k).catch(() => {})));
  revalidatePath("/admin/orders");
  redirect("/admin/orders?deleted=1");
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
  video_review: z.boolean(),
  status: z.enum(["draft", "published", "archived"]),
  sort: z.coerce.number().int().min(0).max(999),
  image_id: z.string().optional().default(""),
});

export async function saveProductAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const get = (k: string) => String(fd.get(k) ?? "");
  const parsed = productSchema.safeParse({
    id: get("id"), slug: get("slug"), category: get("category"), name: get("name"), audience: get("audience"),
    items: get("items"), note: get("note"), delivery: get("delivery"), requirements: get("requirements"),
    policy_note: get("policy_note"), recommended: fd.get("recommended") === "on", video_review: fd.get("video_review") === "on", status: get("status"), sort: get("sort"),
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
        p.requirements || null, p.policy_note || null, p.recommended, p.status, p.sort, p.image_id || null, p.video_review];
      if (id) {
        await tx.query(
          `UPDATE products SET slug=$1, category=$2, name=$3, audience=$4, items=$5, note=$6, delivery=$7, requirements=$8,
             policy_note=$9, recommended=$10, status=$11, sort=$12, image_id=$13, video_review=$14, updated_at=now() WHERE id=$15`, [...vals, id]);
      } else {
        id = (await tx.query(
          `INSERT INTO products (slug, category, name, audience, items, note, delivery, requirements, policy_note, recommended, status, sort, image_id, video_review)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14) RETURNING id`, vals)).rows[0].id;
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
    case "tutorial_video": {
      const url = g("url");
      if (url && !youtubeId(url)) return { error: "الرابط غير صالح. الصقي رابط يوتيوب مثل https://youtu.be/XXXXXXXXXXX" };
      value = { url, label: g("label").slice(0, 60) };
      break;
    }
    case "guide_video": {
      const url = g("url");
      if (url && !youtubeId(url)) return { error: "الرابط غير صالح. الصقي رابط يوتيوب مثل https://youtu.be/XXXXXXXXXXX" };
      value = { url, title: g("title").slice(0, 80), body: g("body").slice(0, 400) };
      break;
    }
    case "analytics": {
      const id = g("ga_id").toUpperCase();
      if (id && !/^G-[A-Z0-9]{6,12}$/.test(id)) return { error: "المعرّف غير صالح. الصيغة: G- ثم أحرف وأرقام، مثل G-ABC123XYZ4 (تلقينه من Google Analytics ← Admin ← Data streams)." };
      value = { ga_id: id };
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
    case "about": {
      const pairs = (v: string) => lines(v).map((l) => l.split("|").map((x) => x.trim()));
      value = {
        name: g("name"), bio: g("bio"), home_bio: g("home_bio"), points: lines(g("points")), certs: lines(g("certs")),
        story_title: g("story_title"), story: lines(g("story")),
        pillars_title: g("pillars_title"), pillars: pairs(g("pillars")).map(([title, ...b]) => ({ title, body: b.join(" | ") })),
        fit_title: g("fit_title"), fit: lines(g("fit")),
        notes: pairs(g("notes")).map(([title, body = "", href = "", label = ""]) => ({ title, body, href: href.startsWith("/") || href.startsWith("https://") ? href : "", label })),
        experience_title: g("experience_title"), experience: lines(g("experience")),
      };
      break;
    }
    case "badges":
      value = lines(g("value")).slice(0, 6);
      break;
    case "checkins":
      value = { enabled: fd.get("enabled") === "on", questions: lines(g("questions")).map((l) => { const [topic, ...q] = l.split("|"); return q.length ? { topic: topic.trim(), q: q.join("|").trim() } : { topic: "", q: topic.trim() }; }) };
      break;
    case "reminders": {
      const nums = g("sub_expiry_days").split(/[,،\s]+/).map(Number).filter((n) => Number.isInteger(n) && n >= 1 && n <= 60);
      const int = (k: string, min: number, max: number) => Math.min(max, Math.max(min, Math.round(Number(g(k)) || 0)));
      if (!nums.length) return { error: "اكتبي أيام التذكير قبل الانتهاء، مثل: 7، 3" };
      value = {
        sub_expiry_days: [...new Set(nums)].sort((a, b) => b - a),
        sub_expiry_text: g("sub_expiry_text").slice(0, 400),
        review_lead_days: int("review_lead_days", 0, 6),
        review_window_days: int("review_window_days", 0, 6),
        review_text: g("review_text").slice(0, 400),
        missed_review_text: g("missed_review_text").slice(0, 400),
        manual_cooldown_minutes: int("manual_cooldown_minutes", 1, 1440),
        coach_digest: fd.get("coach_digest") === "on",
      };
      break;
    }
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
  if (!["hero", "about", "gallery", "product", "free_plan"].includes(usage)) return { error: "نوع الاستخدام غير صالح." };
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

// ---------- طلب يدوي: برنامج لمتدرب بدون استبيان الموقع ----------
const manualSchema = z.object({
  email: z.string().trim().toLowerCase().email("اكتبي بريداً صحيحاً للمتدرب.").max(200),
  name: z.string().trim().min(2, "اكتبي اسم المتدرب (حرفين على الأقل).").max(80),
  phone: z.string().trim().max(20).regex(/^\+?[\d\s-]*$/, "رقم الجوال بالأرقام فقط، مثل +9665XXXXXXXX.").optional().default(""),
  sku: z.string().min(1, "اختاري الباقة والمدة.").max(40),
  status: z.enum(["awaiting_payment", "preparing", "active", "delivered"], { message: "اختاري الحالة." }),
  amount: z.union([z.literal(""), z.coerce.number().min(0).max(100000)]).optional().default(""),
  note: z.string().trim().max(500).optional().default(""),
  notify: z.enum(["", "on"]).optional().default(""),
});

export async function createManualOrderAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const parsed = manualSchema.safeParse(Object.fromEntries([...fd.entries()].filter(([k]) => !k.startsWith("$ACTION"))));
  if (!parsed.success) {
    const fieldErrors: Record<string, string> = {};
    for (const i of parsed.error.issues) fieldErrors[String(i.path[0])] ??= i.message;
    return { error: Object.values(fieldErrors)[0] ?? "راجعي الحقول.", fieldErrors };
  }
  const v = parsed.data;
  const phone = v.phone.replace(/[\s-]/g, "");
  let orderNo: string;
  let results: ChannelResult[] = [];
  try {
    ({ orderNo, results } = await asCoach(async (tx) => {
      const { rows: [r] } = await tx.query("SELECT app.coach_create_manual_order($1,$2,$3,$4,$5,$6,$7) AS no",
        [v.email, v.name, phone, v.sku, v.status, v.amount === "" ? null : Math.round(v.amount * 100), v.note]);
      const no = r.no as string;
      let res: ChannelResult[] = [];
      if (v.notify === "on") {
        const o = await orderTarget(tx, no);
        if (o) res = await notifyTrainee(tx, { orderId: o.id, orderNo: no, userId: o.user_id }, {
          kind: "status", subject: "برنامجك في Nav Coaching", channels: ["email"],
          text: "أضافت المدربة برنامجك إلى حسابك في Nav Coaching. ادخل ببريدك هذا لتشوف التفاصيل والملفات." });
      }
      return { orderNo: no, results: res };
    }));
  } catch (err) { return fail(err); }
  revalidatePath("/admin/orders");
  revalidatePath("/admin/members");
  // نتيجة الإشعار تظهر في «سجل الإشعارات» بصفحة الطلب
  void results;
  redirect(`/admin/orders/${orderNo}?created=1`);
}

// ---------- الجداول المجانية (المدربة فقط) ----------
const freePlanSchema = z.object({
  id: z.union([z.literal(""), z.string().uuid()]),
  slug: z.string().trim().toLowerCase().regex(/^[a-z0-9]+(-[a-z0-9]+)*$/, "الرابط بالإنجليزي: حروف صغيرة وأرقام وشرطات فقط، مثل home-beginner.").max(60),
  title: z.string().trim().min(3, "اكتبي اسم الجدول.").max(120),
  summary: z.string().trim().min(10, "اكتبي وصفاً مختصراً (10 أحرف على الأقل).").max(600, "الوصف أطول من 600 حرف."),
  audience: z.string().trim().max(120).optional().default(""),
  image_id: z.union([z.literal(""), z.string().uuid()]),
  status: z.enum(["published", "hidden"]),
  sort: z.coerce.number().int().min(-1000).max(1000).catch(0),
});

export async function saveFreePlanAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const g = (k: string) => String(fd.get(k) ?? "");
  const parsed = freePlanSchema.safeParse({ id: g("id"), slug: g("slug"), title: g("title"), summary: g("summary"), audience: g("audience"), image_id: g("image_id"), status: g("status"), sort: g("sort") });
  if (!parsed.success) return { error: parsed.error.issues[0].message };
  const v = parsed.data;
  const file = fd.get("file") as File | null;
  let uploaded: { key: string; mime: string; size: number; sha256: string } | null = null;
  let id: string;
  try {
    await coach();
    if (file && typeof file !== "string" && file.size > 0) {
      const clean = await cleanUpload(file, "pdf");
      const key = newKey("free-plans", "pdf");
      await (await storage()).put(key, clean.data, clean.mime);
      uploaded = { key, mime: clean.mime, size: clean.size, sha256: clean.sha256 };
    }
    const r = await asCoach(async (tx) => (await tx.query(
      "SELECT app.coach_save_free_plan($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) AS r",
      [v.id || null, v.slug, v.title, v.summary, v.audience, v.image_id || null, v.status, v.sort,
       uploaded?.key ?? null, uploaded?.mime ?? null, uploaded?.size ?? null, uploaded?.sha256 ?? null])).rows[0].r as { id: string; old_file_key: string | null });
    id = r.id;
    if (r.old_file_key) await (await storage()).remove(r.old_file_key).catch(() => {});
  } catch (err) {
    if (uploaded) await (await storage()).remove(uploaded.key).catch(() => {});
    if (err instanceof UploadError) return { error: err.message };
    if ((err as { code?: string }).code === "23505") return { error: "هذا الرابط مستخدم لجدول آخر. اختاري رابطاً مختلفاً." };
    return fail(err);
  }
  revalidatePath("/free-plans");
  revalidatePath(`/free-plans/${v.slug}`);
  revalidatePath("/admin/free-plans");
  if (!v.id) redirect(`/admin/free-plans/${id}?created=1`);
  return { ok: true, message: uploaded ? "تم الحفظ ورفع ملف PDF الجديد." : "تم الحفظ." };
}

// ---------- حذف عضو مسجّل (حتى لو عنده طلبات: لحسابات التجربة). المدربة لا تُحذف، والقاعدة تتحقق ----------
export async function deleteMemberAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const user = String(fd.get("user_id") ?? "");
  if (!user || user.length > 100) return { error: GENERIC };
  let res: { email: string; keys: string[] };
  try {
    res = await asCoach(async (tx) => (await tx.query("SELECT app.coach_delete_member($1) AS r", [user])).rows[0].r as { email: string; keys: string[] });
  } catch (err) { return fail(err); }
  const email = res.email;
  const store = await storage();
  await Promise.all(res.keys.map((k) => store.remove(k).catch(() => {})));
  revalidatePath("/admin/members");
  revalidatePath("/admin");
  return { ok: true, message: `تم حذف العضو ${email}.` };
}

// ---------- مكافأة الالتزام: 3 أشهر مجاناً (يُعاد حساب الاستحقاق هنا قبل المنح) ----------
export async function grantRewardAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  let res: { no: string; results: ChannelResult[] } | { error: string };
  try {
    res = await asCoach(async (tx) => {
      const { rows: [o] } = await tx.query(
        `SELECT id, order_no, user_id, category, months, status, sub_start_at, sub_end_at, review_weekday, renewal_kind FROM orders WHERE order_no = $1`, [orderNo]);
      if (!o) return { error: "الطلب غير موجود." };
      const r = await loadReminders(tx);
      const a = await loadAdherence(tx, o, r.review_window_days);
      if (!a?.eligible || a.avg == null) return { error: "المتدرب غير مستحق حالياً (يلزم التزام 90% فأكثر خلال 12 أسبوعاً مكتملاً)." };
      const no = (await tx.query("SELECT app.coach_grant_reward($1, $2) AS no", [orderNo, a.avg])).rows[0].no as string;
      const results = await notifyTrainee(tx, { orderId: o.id, orderNo: no, userId: o.user_id }, {
        kind: "reward", subject: "مكافأة التزامك 🎁",
        text: "مبروك! بسبب التزامك خلال اشتراكك، أضفنا لك 3 أشهر مجاناً تبدأ بعد نهاية اشتراكك الحالي." });
      return { no, results };
    });
  } catch (err) { return fail(err); }
  if ("error" in res) return { error: res.error };
  revalidatePath("/admin");
  revalidatePath(`/admin/orders/${orderNo}`);
  // العنصر يختفي من القائمة بعد المنح، فالنتيجة تظهر في الصفحة عبر الرابط
  const back = String(fd.get("back") ?? "");
  const sent = res.results.some((r) => r.status === "sent") ? "1" : "0";
  redirect(`${back.startsWith("/admin") && !back.startsWith("//") ? back : "/admin"}?granted=${encodeURIComponent(res.no)}&sent=${sent}`);
}

// ---------- استبيان نهاية البرنامج: «اطّلعت عليه» ----------
export async function markSurveySeenAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const orderNo = String(fd.get("order_no") ?? "");
  try {
    await asCoach((tx) => tx.query("SELECT app.coach_mark_survey_seen($1)", [orderNo]));
  } catch (err) { return fail(err); }
  revalidatePath("/admin");
  revalidatePath(`/admin/orders/${orderNo}`);
  return { ok: true, message: "تم." };
}

// ---------- أسئلة الاستبيان (تتحدث في الموقع مباشرة) ----------
export async function saveIntakeQuestionsAction(_: ActionState, fd: FormData): Promise<ActionState> {
  try {
    await asCoach(async (tx, uid) => {
      const old = parseConfig((await tx.query("SELECT value FROM site_settings WHERE key = 'intake_questions'")).rows[0]?.value);
      const r = configFromForm((k) => String(fd.get(k) ?? ""), old.custom.map((c) => c.id));
      if ("error" in r) throw new Error(`user:${r.error}`);
      await tx.query(
        `INSERT INTO site_settings (key, value, updated_by) VALUES ('intake_questions',$1,$2)
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now()`,
        [JSON.stringify(r.config), uid]);
      await log(tx, uid, "setting.save", "intake_questions", { edited: Object.keys(r.config.labels).length, custom: r.config.custom.length });
    });
  } catch (err) {
    const m = (err as Error).message ?? "";
    if (m.startsWith("user:")) return { error: m.slice(5) };
    return fail(err);
  }
  revalidatePath("/", "layout");
  revalidatePath("/admin/content/intake");
  return { ok: true, message: "تم حفظ الأسئلة، وتظهر الآن في استبيان الموقع." };
}
