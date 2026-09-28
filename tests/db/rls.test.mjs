// اختبارات الصلاحيات على مستوى قاعدة البيانات (بدون الواجهة).
// تعمل على قاعدة اختبار منفصلة TEST_DATABASE_URL_OWNER / TEST_DATABASE_URL وتُعاد تهيئتها بالكامل.
import { test, before, after, describe } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import pg from "pg";

const OWNER = process.env.TEST_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_test";
const APP = process.env.TEST_DATABASE_URL ?? "postgres://nav_app:nav_app_dev@localhost:5432/nav_test";

let owner, app;
const A = "user_a", B = "user_b", COACH = "user_coach";

async function as(userId, sql, params = []) {
  const c = await app.connect();
  try {
    await c.query("BEGIN");
    await c.query("SELECT set_config('app.user_id', $1, true)", [userId ?? ""]);
    const r = await c.query(sql, params);
    await c.query("COMMIT");
    return r;
  } catch (e) {
    await c.query("ROLLBACK");
    throw e;
  } finally {
    c.release();
  }
}
const newOrder = (user, key, sku = "int1", student = false) =>
  as(user, "SELECT app.create_order($1,$2,$3,'اسم تجريبي','+966500000000',$4,$5,false,'لا، أفضّل الخصوصية','') AS no",
    [sku, key, student, JSON.stringify({ goal: "لياقة وقوة" }), JSON.stringify({ injury: "لا" })]).then((r) => r.rows[0].no);

before(async () => {
  owner = new pg.Client({ connectionString: OWNER });
  await owner.connect();
  await owner.query("DROP SCHEMA IF EXISTS app CASCADE; DROP SCHEMA public CASCADE; CREATE SCHEMA public;");
  const env = { ...process.env, DATABASE_URL_OWNER: OWNER, ENV_FILE: "/dev/null" };
  execFileSync("node", ["scripts/migrate.mjs"], { env, stdio: "inherit" });
  execFileSync("node", ["scripts/seed.mjs"], { env, stdio: "inherit" });
  for (const [id, role] of [[A, "client"], [B, "client"], [COACH, "coach"]]) {
    await owner.query(`INSERT INTO "user" (id, name, email, "emailVerified", role) VALUES ($1, $1, $1 || '@test.local', true, $2)`, [id, role]);
  }
  app = new pg.Pool({ connectionString: APP, max: 3 });
});
after(async () => { await app?.end(); await owner?.end(); });

describe("الزائر", () => {
  test("يرى المنتجات المنشورة والتقييمات المنشورة فقط", async () => {
    const p = await as(null, "SELECT count(*)::int n FROM products");
    assert.equal(p.rows[0].n, 8);
    const r = await as(null, "SELECT count(*)::int n FROM public_reviews");
    assert.equal(r.rows[0].n, 12);
  });
  test("لا يرى أي طلبات ولا يستطيع إنشاء طلب", async () => {
    await newOrder(A, "k-visitor-check-0001");
    const r = await as(null, "SELECT count(*)::int n FROM orders");
    assert.equal(r.rows[0].n, 0);
    await assert.rejects(newOrder(null, "k-anon-000000000001"), /تسجيل الدخول/);
  });
  test("لا يرى جدول التقييمات الخام (بدون معرّفات المستخدمين)", async () => {
    const r = await as(null, "SELECT count(*)::int n FROM reviews");
    assert.equal(r.rows[0].n, 0);
  });
});

describe("عزل بيانات العملاء", () => {
  test("العميل B لا يرى طلب A ولا تقييمه الصحي ولا سجله", async () => {
    const no = await newOrder(A, "k-isolation-000000001");
    const orders = await as(B, "SELECT * FROM orders WHERE order_no = $1", [no]);
    assert.equal(orders.rowCount, 0);
    const intakes = await as(B, "SELECT * FROM intakes");
    assert.equal(intakes.rowCount, 0);
    const events = await as(B, "SELECT * FROM order_events");
    assert.equal(events.rowCount, 0);
    const mine = await as(A, "SELECT * FROM orders WHERE order_no = $1", [no]);
    assert.equal(mine.rowCount, 1);
  });
  test("العميل B لا يستطيع رفع إيصال أو إلغاء طلب A", async () => {
    const no = await newOrder(A, "k-isolation-000000002");
    await assert.rejects(as(B, "SELECT app.submit_payment_proof($1,'k','image/png',10,'abc')", [no]), /غير موجود/);
    await assert.rejects(as(B, "SELECT app.client_cancel($1)", [no]), /غير موجود/);
  });
  test("لا كتابة مباشرة على الطلبات أو السجل", async () => {
    const no = await newOrder(A, "k-direct-write-00001");
    await assert.rejects(as(A, "UPDATE orders SET status = 'active' WHERE order_no = $1", [no]), /permission denied/);
    await assert.rejects(as(A, "INSERT INTO orders (order_no) VALUES ('x')"), /permission denied/);
    await assert.rejects(as(A, "DELETE FROM order_events"), /permission denied/);
    await assert.rejects(as(COACH, "UPDATE order_events SET note = 'x'"), /permission denied/);
  });
  test("السجل للإضافة فقط حتى لمالك قاعدة البيانات", async () => {
    await assert.rejects(owner.query("UPDATE order_events SET note = 'x'"), /للإضافة فقط/);
  });
});

describe("الطلب والدفع", () => {
  test("السعر من قاعدة البيانات، وتكرار الإرسال لا ينشئ طلباً ثانياً", async () => {
    const n1 = await newOrder(A, "k-idempotent-0000001", "adv3");
    const n2 = await newOrder(A, "k-idempotent-0000001", "adv3");
    assert.equal(n1, n2);
    const r = await as(A, "SELECT amount_due_halalas, status FROM orders WHERE order_no = $1", [n1]);
    assert.equal(r.rows[0].amount_due_halalas, 125000);
    assert.equal(r.rows[0].status, "awaiting_payment");
  });
  test("منتج غير منشور لا يُطلب", async () => {
    await owner.query("UPDATE products SET status = 'draft' WHERE slug = 'nutrition'");
    await assert.rejects(newOrder(A, "k-draft-product-00001", "nut1"), /غير متاح/);
    await owner.query("UPDATE products SET status = 'published' WHERE slug = 'nutrition'");
  });
  test("خصم الطالب: بانتظار تأكيد المبلغ، ولا يمكن رفع إيصال قبل التأكيد", async () => {
    const no = await newOrder(A, "k-student-0000000001", "bas1", true);
    const r = await as(A, "SELECT status, amount_due_halalas FROM orders WHERE order_no = $1", [no]);
    assert.deepEqual(r.rows[0], { status: "awaiting_quote", amount_due_halalas: null });
    await assert.rejects(as(A, "SELECT app.submit_payment_proof($1,'s1','image/png',10,'h1')", [no]), /حالة الطلب/);
    await assert.rejects(as(A, "SELECT app.coach_set_amount($1, 100, '')", [no]), /للمدربة فقط/);
    await as(COACH, "SELECT app.coach_set_amount($1, 31410, 'خصم طالب')", [no]);
    const r2 = await as(A, "SELECT status, amount_due_halalas FROM orders WHERE order_no = $1", [no]);
    assert.deepEqual(r2.rows[0], { status: "awaiting_payment", amount_due_halalas: 31410 });
  });
  test("رفع الإيصال لا يعني الدفع؛ الاعتماد للمدربة فقط وبعد تأكيد وصول المبلغ", async () => {
    const no = await newOrder(A, "k-payment-flow-00001");
    await as(A, "SELECT app.submit_payment_proof($1,'p1','image/webp',100,'sha-1')", [no]);
    let r = await as(A, "SELECT status, paid_at FROM orders WHERE order_no = $1", [no]);
    assert.equal(r.rows[0].status, "payment_review");
    assert.equal(r.rows[0].paid_at, null);
    await assert.rejects(as(A, "SELECT app.coach_transition($1,'preparing','',true)", [no]), /للمدربة فقط/);
    await assert.rejects(as(COACH, "SELECT app.coach_transition($1,'preparing','',false)", [no]), /كشف الحساب/);
    await as(COACH, "SELECT app.coach_transition($1,'preparing','تم التحقق',true)", [no]);
    r = await as(A, "SELECT status, paid_at FROM orders WHERE order_no = $1", [no]);
    assert.equal(r.rows[0].status, "preparing");
    assert.ok(r.rows[0].paid_at);
    const proof = await as(A, "SELECT review_status FROM payment_proofs WHERE storage_key = 'p1'");
    assert.equal(proof.rows[0].review_status, "approved");
  });
  test("رفض الإيصال يتطلب سبباً ويعيد الطلب لانتظار الدفع", async () => {
    const no = await newOrder(A, "k-reject-proof-00001");
    await as(A, "SELECT app.submit_payment_proof($1,'p2','image/webp',100,'sha-2')", [no]);
    await assert.rejects(as(COACH, "SELECT app.coach_transition($1,'awaiting_payment','',false)", [no]), /سبب/);
    await as(COACH, "SELECT app.coach_transition($1,'awaiting_payment','المبلغ لم يصل',false)", [no]);
    const r = await as(A, "SELECT status FROM orders WHERE order_no = $1", [no]);
    assert.equal(r.rows[0].status, "awaiting_payment");
  });
  test("الانتقالات تتبع نوع المنتج", async () => {
    const no = await newOrder(A, "k-transitions-000001", "diy");
    await as(COACH, "SELECT app.coach_transition($1,'preparing','',true)", [no]);
    await assert.rejects(as(COACH, "SELECT app.coach_transition($1,'active','',false)", [no]), /غير مسموح/);
    await as(COACH, "SELECT app.coach_transition($1,'delivered','',false)", [no]);
  });
});

describe("الملفات والتسليم", () => {
  test("الملفات لا تظهر للعميل قبل استحقاقها، ولا تظهر لغيره أبداً", async () => {
    const no = await newOrder(A, "k-deliverables-00001");
    const { rows: [{ id }] } = await as(A, "SELECT id FROM orders WHERE order_no = $1", [no]);
    await as(COACH, "INSERT INTO deliverables (order_id, title, kind, url) VALUES ($1, 'ملف البرنامج', 'link', 'https://example.com/plan')", [id]);
    await assert.rejects(as(A, "INSERT INTO deliverables (order_id, title, kind, url) VALUES ($1, 'x', 'link', 'https://x.y')", [id]), /row-level security/);
    assert.equal((await as(A, "SELECT * FROM deliverables WHERE order_id = $1", [id])).rowCount, 0);
    await as(COACH, "SELECT app.coach_transition($1,'preparing','',true)", [no]);
    assert.equal((await as(A, "SELECT * FROM deliverables WHERE order_id = $1", [id])).rowCount, 0);
    await as(COACH, "SELECT app.coach_transition($1,'active','',false)", [no]);
    assert.equal((await as(A, "SELECT * FROM deliverables WHERE order_id = $1", [id])).rowCount, 1);
    assert.equal((await as(B, "SELECT * FROM deliverables WHERE order_id = $1", [id])).rowCount, 0);
  });
});

describe("التقييمات", () => {
  test("لا تقييم قبل بدء الخدمة، وتقييم واحد لكل طلب، ويمر بالمراجعة", async () => {
    const no = await newOrder(A, "k-review-flow-000001");
    await assert.rejects(as(A, "SELECT app.submit_review($1, 5, 'تجربة ممتازة جداً مع المدربة', 'first', true)", [no]), /بعد بدء الخدمة/);
    await as(COACH, "SELECT app.coach_transition($1,'preparing','',true)", [no]);
    await as(COACH, "SELECT app.coach_transition($1,'active','',false)", [no]);
    await assert.rejects(as(B, "SELECT app.submit_review($1, 5, 'تقييم وهمي من شخص آخر', 'first', true)", [no]), /غير موجود/);
    await assert.rejects(as(A, "SELECT app.submit_review($1, 5, 'كلموني على 0555 123 456 للتفاصيل', 'first', true)", [no]), /أرقام الهواتف/);
    await as(A, "SELECT app.submit_review($1, 5, 'تجربة ممتازة جداً مع المدربة', 'first', true)", [no]);
    await assert.rejects(as(A, "SELECT app.submit_review($1, 4, 'تقييم ثاني لنفس الطلب', 'first', true)", [no]), /مسبقاً/);
    const pub = await as(null, "SELECT count(*)::int n FROM public_reviews");
    assert.equal(pub.rows[0].n, 12, "لا يظهر قبل الاعتماد");
    const { rows: [rv] } = await as(COACH, "SELECT id FROM reviews WHERE source = 'platform'");
    await assert.rejects(as(A, "SELECT app.moderate_review($1,'publish',null,null)", [rv.id]), /للمدربة فقط/);
    await as(COACH, "SELECT app.moderate_review($1,'publish',null,null)", [rv.id]);
    assert.equal((await as(null, "SELECT count(*)::int n FROM public_reviews")).rows[0].n, 13);
    await assert.rejects(owner.query("UPDATE reviews SET body = 'نص معدّل ليبدو أفضل' WHERE id = $1", [rv.id]), /مضمون التقييم/);
    await assert.rejects(as(COACH, "SELECT app.moderate_review($1,'hide','',null)", [rv.id]), /سبب/);
  });
  test("لا يُنشر تقييم بدون موافقة صاحبه على النشر", async () => {
    const no = await newOrder(A, "k-review-consent-001", "cN");
    await as(COACH, "SELECT app.coach_transition($1,'preparing','',true)", [no]);
    await as(COACH, "SELECT app.coach_transition($1,'completed','',false)", [no]);
    await as(A, "SELECT app.submit_review($1, null, 'الجلسة كانت مفيدة وواضحة', 'anon', false)", [no]);
    const { rows: [rv] } = await as(A, "SELECT r.id FROM reviews r JOIN orders o ON o.id = r.order_id WHERE o.order_no = $1", [no]);
    await assert.rejects(as(COACH, "SELECT app.moderate_review($1,'publish',null,null)", [rv.id]), /لم يوافق/);
  });
});

describe("المحتوى وحدود الطلبات", () => {
  test("العميل لا يعدّل المنتجات أو الإعدادات", async () => {
    const r = await as(A, "UPDATE product_offers SET price_halalas = 100");
    assert.equal(r.rowCount, 0);
    await assert.rejects(as(A, "INSERT INTO site_settings (key, value) VALUES ('x', '1')"), /row-level security/);
    const c = await as(COACH, "UPDATE site_settings SET value = value WHERE key = 'bank'");
    assert.equal(c.rowCount, 1);
  });
  test("حد الطلبات", async () => {
    for (let i = 0; i < 3; i++) assert.equal((await as(A, "SELECT app.rate_limit('t:1', 3, 60) ok")).rows[0].ok, true);
    assert.equal((await as(A, "SELECT app.rate_limit('t:1', 3, 60) ok")).rows[0].ok, false);
    await assert.rejects(as(A, "SELECT * FROM rate_hits"), /permission denied/);
  });
});

describe("أرشفة وحذف الطلبات", () => {
  test("الإخفاء للمدربة فقط، والطلب يبقى ظاهراً لصاحبه", async () => {
    const no = await newOrder(A, "k-archive-000000001");
    await assert.rejects(as(A, "SELECT app.coach_archive_order($1, true)", [no]), /للمدربة فقط/);
    await as(COACH, "SELECT app.coach_archive_order($1, true)", [no]);
    const r = await as(A, "SELECT archived_at FROM orders WHERE order_no = $1", [no]);
    assert.ok(r.rows[0].archived_at);
    await as(COACH, "SELECT app.coach_archive_order($1, false)", [no]);
    assert.equal((await as(A, "SELECT archived_at FROM orders WHERE order_no = $1", [no])).rows[0].archived_at, null);
  });
  test("الحذف النهائي للملغاة فقط، ويحذف السجل والإيصال", async () => {
    const no = await newOrder(A, "k-delete-0000000001");
    await as(A, "SELECT app.submit_payment_proof($1,'del-key','image/webp',10,'sha-del')", [no]);
    await assert.rejects(as(COACH, "SELECT app.coach_delete_order($1)", [no]), /الملغاة فقط/);
    await assert.rejects(as(A, "SELECT app.coach_delete_order($1)", [no]), /للمدربة فقط/);
    await as(COACH, "SELECT app.coach_transition($1,'cancelled','طلب تجريبي',false)", [no]);
    const keys = (await as(COACH, "SELECT app.coach_delete_order($1) AS k", [no])).rows[0].k;
    assert.deepEqual(keys, ["del-key"]);
    assert.equal((await owner.query("SELECT count(*)::int n FROM orders WHERE order_no = $1", [no])).rows[0].n, 0);
    // السجل مازال للإضافة فقط خارج دالة الحذف
    await assert.rejects(owner.query("DELETE FROM order_events"), /للإضافة فقط/);
    await assert.rejects(as(A, "SELECT set_config('app.allow_purge','1',true); DELETE FROM orders"), /permission denied|cannot insert multiple/);
  });
});

describe("قراءات الزائر بدون معاملة", () => {
  test("اتصال أُعيد للمجموعة بعد معاملة مستخدم لا يحمل هويته", async () => {
    await newOrder(A, "k-anon-reuse-0000001");
    const single = new pg.Pool({ connectionString: APP, max: 1 });
    const c = await single.connect();
    await c.query("BEGIN");
    await c.query("SELECT set_config('app.user_id', $1, true)", [A]);
    assert.ok((await c.query("SELECT count(*)::int n FROM orders")).rows[0].n > 0);
    await c.query("COMMIT");
    c.release();
    const anon = await single.query("SELECT count(*)::int n FROM orders");
    assert.equal(anon.rows[0].n, 0);
    await single.end();
  });
});

describe("المتابعة: الملاحظات والاشتراك والإشعارات", () => {
  test("ملاحظات المدربة لا يقرأها صاحب الطلب ولا يكتبها", async () => {
    const no = await newOrder(A, "k-notes-00000000001");
    await as(COACH, "SELECT app.coach_save_note($1, 'ملاحظة سرية: يحتاج متابعة لصيقة')", [no]);
    assert.equal((await as(A, "SELECT * FROM order_admin_notes")).rowCount, 0);
    await assert.rejects(as(A, "SELECT app.coach_save_note($1, 'x')", [no]), /للمدربة فقط/);
    await assert.rejects(as(A, "INSERT INTO order_admin_notes (order_id, body) SELECT id, 'x' FROM orders WHERE order_no = $1", [no]), /permission denied/);
    const r = await as(COACH, "SELECT n.body, n.updated_by FROM order_admin_notes n JOIN orders o ON o.id = n.order_id WHERE o.order_no = $1", [no]);
    assert.equal(r.rows[0].updated_by, COACH);
  });
  test("تاريخ البدء والانتهاء يُسجلان تلقائياً عند التفعيل", async () => {
    const no = await newOrder(A, "k-subdates-00000001", "int3");
    await as(COACH, "SELECT app.coach_transition($1,'preparing','',true)", [no]);
    assert.equal((await as(A, "SELECT sub_start_at FROM orders WHERE order_no = $1", [no])).rows[0].sub_start_at, null);
    await as(COACH, "SELECT app.coach_transition($1,'active','',false)", [no]);
    const { rows: [o] } = await as(A, "SELECT sub_start_at, sub_end_at, review_weekday, (sub_end_at - sub_start_at) > interval '88 days' AS three_months FROM orders WHERE order_no = $1", [no]);
    assert.ok(o.sub_start_at && o.sub_end_at && o.review_weekday !== null && o.three_months);
    await assert.rejects(as(A, "SELECT app.coach_set_subscription($1, now(), now() + interval '1 day', 2)", [no]), /للمدربة فقط/);
    await as(COACH, "SELECT app.coach_set_subscription($1, now() - interval '80 days', now() + interval '5 days', 2)", [no]);
    await as(COACH, "SELECT app.coach_mark_week($1, 1, true)", [no]);
    assert.equal((await as(A, "SELECT count(*)::int n FROM review_weeks")).rows[0].n, 1);
    await assert.rejects(as(A, "SELECT app.coach_mark_week($1, 2, true)", [no]), /للمدربة فقط/);
  });
  test("الإشعار لنفس المناسبة لا يتكرر، والعميل لا يقرأ السجل", async () => {
    const no = await newOrder(A, "k-notify-0000000001");
    const { rows: [o] } = await as(A, "SELECT id FROM orders WHERE order_no = $1", [no]);
    const first = (await as(COACH, "SELECT app.notify_claim($1,$2,'sub_expiry','email','sub_expiry:2026-10-01:7','نص') AS id", [o.id, A])).rows[0].id;
    const again = (await as(COACH, "SELECT app.notify_claim($1,$2,'sub_expiry','email','sub_expiry:2026-10-01:7','نص') AS id", [o.id, A])).rows[0].id;
    assert.ok(first);
    assert.equal(again, null);
    await as(COACH, "SELECT app.notify_finish($1,'sent',null)", [first]);
    assert.equal((await as(A, "SELECT * FROM notification_log")).rowCount, 0);
    await assert.rejects(as(A, "SELECT app.notify_claim($1,$2,'x','email',null,'x')", [o.id, A]), /للمدربة فقط/);
    const sys = (await as("system-scheduler", "SELECT app.notify_claim($1,$2,'review_upcoming','email','r:1','نص') AS id", [o.id, A])).rows[0].id;
    assert.ok(sys, "مستخدم النظام يسجل التذكيرات المجدولة");
  });
  test("التفضيلات: كل مستخدم يعدّل تفضيلاته فقط", async () => {
    await as(A, "INSERT INTO user_prefs (user_id, whatsapp_enabled) VALUES ($1, false)", [A]);
    await assert.rejects(as(A, "INSERT INTO user_prefs (user_id) VALUES ($1)", [B]), /row-level security/);
    assert.equal((await as(B, "UPDATE user_prefs SET email_enabled = false WHERE user_id = $1", [A])).rowCount, 0);
    assert.equal((await as(COACH, "SELECT whatsapp_enabled FROM user_prefs WHERE user_id = $1", [A])).rows[0].whatsapp_enabled, false);
  });
  test("تحديث الوزن والطول لصاحب الطلب فقط وبقيم منطقية", async () => {
    const no = await newOrder(A, "k-measure-000000001");
    await assert.rejects(as(A, "SELECT app.update_intake_measurements($1, 10, 170)", [no]), /وزناً/);
    await assert.rejects(as(B, "SELECT app.update_intake_measurements($1, 70, 170)", [no]), /غير موجود/);
    await as(A, "SELECT app.update_intake_measurements($1, 70.5, 168)", [no]);
    const h = (await as(COACH, "SELECT i.health FROM intakes i JOIN orders o ON o.id = i.order_id WHERE o.order_no = $1", [no])).rows[0].health;
    assert.equal(Number(h.weight), 70.5);
  });
  test("المتدرب يقرأ جدول المراجعة فقط، ونصوص التذكير تبقى للمدربة", async () => {
    const sch = (await as(A, "SELECT app.review_schedule() AS s")).rows[0].s;
    assert.equal(typeof sch.review_window_days, "number");
    assert.equal(sch.review_text, undefined);
    assert.equal((await as(A, "SELECT value FROM site_settings WHERE key = 'reminders'")).rowCount, 0);
    assert.equal((await as(COACH, "SELECT value FROM site_settings WHERE key = 'reminders'")).rowCount, 1);
  });
});

describe("الطلبات اليدوية من المدربة", () => {
  const create = (who, email, sku, status, amount = null) =>
    as(who, "SELECT app.coach_create_manual_order($1,'متدرب يدوي','+966511111111',$2,$3,$4,'اتفاق واتساب') AS no", [email, sku, status, amount]).then((r) => r.rows[0].no);

  test("للمدربة فقط", async () => {
    await assert.rejects(create(A, "x@test.local", "int1", "active"), /للمدربة فقط/);
  });
  test("ينشئ حساباً جديداً ويفعّل الاشتراك بتواريخه", async () => {
    const no = await create(COACH, "  New.Trainee@Test.Local ", "int3", "active", 0);
    const { rows: [o] } = await owner.query(
      `SELECT o.status, o.source, o.amount_due_halalas, o.sub_start_at, o.sub_end_at, o.paid_at, u.email, u.role
         FROM orders o JOIN "user" u ON u.id = o.user_id WHERE o.order_no = $1`, [no]);
    assert.equal(o.status, "active");
    assert.equal(o.source, "manual");
    assert.equal(o.amount_due_halalas, 0);
    assert.equal(o.email, "new.trainee@test.local");
    assert.equal(o.role, "client");
    assert.ok(o.sub_start_at && o.sub_end_at && o.paid_at);
    const ev = (await owner.query("SELECT to_status FROM order_events e JOIN orders o ON o.id = e.order_id WHERE o.order_no = $1 ORDER BY e.id", [no])).rows.map((r) => r.to_status);
    assert.deepEqual(ev, ["preparing", "active"]);
  });
  test("يستخدم الحساب الموجود، والطلب يظهر لصاحبه فقط", async () => {
    const no = await create(COACH, "user_a@test.local", "diy", "delivered");
    assert.equal((await as(A, "SELECT count(*)::int n FROM orders WHERE order_no = $1", [no])).rows[0].n, 1);
    assert.equal((await as(B, "SELECT count(*)::int n FROM orders WHERE order_no = $1", [no])).rows[0].n, 0);
    assert.equal((await owner.query(`SELECT count(*)::int n FROM "user" WHERE lower(email) = 'user_a@test.local'`)).rows[0].n, 1);
  });
  test("يرفض الحالة غير المناسبة والبريد الإداري", async () => {
    await assert.rejects(create(COACH, "y@test.local", "diy", "active"), /لا تناسب/);
    await assert.rejects(create(COACH, "user_coach@test.local", "int1", "active"), /إداري/);
    await assert.rejects(create(COACH, "not-an-email", "int1", "active"), /بريداً صحيحاً/);
  });
});

describe("سجل ملاحظات المدربة", () => {
  test("كل ملاحظة سطر بتاريخه، للمدربة فقط", async () => {
    const no = await newOrder(A, "k-notelog-00000001");
    await as(COACH, "SELECT app.coach_add_note($1, 'أولى')", [no]);
    await as(COACH, "SELECT app.coach_add_note($1, 'ثانية')", [no]);
    const rows = (await as(COACH, "SELECT n.id, n.body, n.created_by, n.created_at FROM order_note_entries n JOIN orders o ON o.id = n.order_id WHERE o.order_no = $1 ORDER BY n.id", [no])).rows;
    assert.deepEqual(rows.map((r) => r.body), ["أولى", "ثانية"]);
    assert.ok(rows.every((r) => r.created_by === COACH && r.created_at));
    assert.equal((await as(A, "SELECT * FROM order_note_entries")).rowCount, 0);
    await assert.rejects(as(A, "SELECT app.coach_add_note($1, 'x')", [no]), /للمدربة فقط/);
    await assert.rejects(as(A, "SELECT app.coach_delete_note($1)", [rows[0].id]), /للمدربة فقط/);
    await assert.rejects(as(COACH, "SELECT app.coach_add_note($1, '   ')", [no]), /اكتبي الملاحظة/);
    await as(COACH, "SELECT app.coach_delete_note($1)", [rows[0].id]);
    assert.equal((await as(COACH, "SELECT count(*)::int n FROM order_note_entries n JOIN orders o ON o.id = n.order_id WHERE o.order_no = $1", [no])).rows[0].n, 1);
  });
});

describe("الجداول المجانية", () => {
  const save = (who, id, slug, status, withFile = true) =>
    as(who, "SELECT app.coach_save_free_plan($1,$2,'جدول اختبار','وصف مختصر للاختبار فقط','مبتدئ',NULL,$3,0,$4,$5,$6,'x') AS r",
      [id, slug, status, withFile ? `free-plans/${slug}.pdf` : null, withFile ? "application/pdf" : null, withFile ? 1234 : null]).then((r) => r.rows[0].r);
  let pub, hidden;
  before(async () => {
    pub = (await save(COACH, null, "test-published", "published")).id;
    hidden = (await save(COACH, null, "test-hidden", "hidden")).id;
  });

  test("الإضافة للمدربة فقط، ولا نشر بدون ملف", async () => {
    await assert.rejects(save(A, null, "x-client", "published"), /للمدربة فقط/);
    await assert.rejects(save(COACH, null, "no-file", "published", false), /ارفعي ملف PDF/);
    await assert.rejects(as(A, "INSERT INTO free_plans (slug, title, summary) VALUES ('a','abc','abcdefghijk')"), /permission denied/);
  });
  test("الزائر يرى المنشور فقط، ومفتاح الملف غير قابل للقراءة", async () => {
    const slugs = (await as(null, "SELECT slug FROM free_plans")).rows.map((r) => r.slug);
    assert.ok(slugs.includes("test-published"));
    assert.ok(!slugs.includes("test-hidden"));
    await assert.rejects(as(A, "SELECT file_key FROM free_plans"), /permission denied/);
    await assert.rejects(as(COACH, "SELECT file_key FROM free_plans"), /permission denied/);
  });
  test("الطلب: يلزم الدخول، منشور فقط، بدون تكرار", async () => {
    await assert.rejects(as(null, "SELECT app.request_free_plan('test-published')"), /تسجيل الدخول/);
    await assert.rejects(as(A, "SELECT app.request_free_plan('test-hidden')"), /غير متاح/);
    const r1 = (await as(A, "SELECT app.request_free_plan('test-published') AS r")).rows[0].r;
    const r2 = (await as(A, "SELECT app.request_free_plan('test-published') AS r")).rows[0].r;
    assert.equal(r1.created, true);
    assert.equal(r2.created, false);
    assert.equal(r1.request_id, r2.request_id);
    assert.equal((await owner.query("SELECT count(*)::int n FROM free_plan_requests WHERE plan_id = $1", [pub])).rows[0].n, 1);
    await assert.rejects(as(A, "INSERT INTO free_plan_requests (plan_id, user_id) VALUES ($1, $2)", [hidden, A]), /permission denied/);
  });
  test("التنزيل وجداولي لصاحب الطلب فقط", async () => {
    const req = (await as(A, "SELECT request_id FROM app.my_free_plans()")).rows[0].request_id;
    assert.equal((await as(A, "SELECT file_key FROM app.free_plan_file($1)", [req])).rows[0].file_key, "free-plans/test-published.pdf");
    assert.equal((await as(B, "SELECT * FROM app.free_plan_file($1)", [req])).rowCount, 0);
    assert.equal((await as(null, "SELECT * FROM app.free_plan_file($1)", [req])).rowCount, 0);
    assert.equal((await as(B, "SELECT * FROM app.my_free_plans()")).rowCount, 0);
    assert.equal((await as(B, "SELECT * FROM free_plan_requests")).rowCount, 0);
    // إخفاء الجدول لاحقاً لا يسحبه ممن طلبه
    await save(COACH, pub, "test-published", "hidden", false);
    assert.equal((await as(A, "SELECT * FROM app.my_free_plans()")).rowCount, 1);
    assert.equal((await as(A, "SELECT * FROM app.free_plan_file($1)", [req])).rowCount, 1);
    await assert.rejects(as(B, "SELECT app.request_free_plan('test-published')"), /غير متاح/);
  });
  test("استبدال الملف يرجع المفتاح القديم لحذفه", async () => {
    const r = await as(COACH, "SELECT app.coach_save_free_plan($1,'test-hidden','جدول اختبار','وصف مختصر للاختبار فقط',NULL,NULL,'hidden',0,'free-plans/new.pdf','application/pdf',99,'y') AS r", [hidden]);
    assert.equal(r.rows[0].r.old_file_key, "free-plans/test-hidden.pdf");
    await assert.rejects(as(COACH, "SELECT app.coach_save_free_plan($1,'test-hidden','جدول اختبار','وصف مختصر للاختبار فقط',NULL,NULL,'hidden',0,'k.exe','application/x-msdownload',9,'z')", [hidden]), /PDF/);
  });
});

describe("منصة التدريب", () => {
  let noA, tpl, block, item, item2, day, squat, boxSquat, notAlt, legExt;
  const exId = async (name) => (await owner.query("SELECT id FROM exercises WHERE name = $1", [name])).rows[0].id;
  before(async () => {
    noA = await newOrder(A, "k-training-000000001");
    await owner.query("UPDATE orders SET status = 'active' WHERE order_no = $1", [noA]);
    [squat, boxSquat, legExt] = [await exId("Back Squat"), await exId("Box Squat"), await exId("Leg Extension")];
    notAlt = await exId("Barbell Bench Press").catch(() => null) ?? (await owner.query("SELECT id FROM exercises WHERE primary_muscle LIKE 'Chest%' AND status = 'approved' LIMIT 1")).rows[0].id;
  });
  test("المكتبة للمدربة فقط (المتدرب لا يقرأها ولا يعدّلها)", async () => {
    assert.equal((await as(COACH, "SELECT count(*)::int n FROM exercises")).rows[0].n, 219);
    assert.equal((await as(A, "SELECT count(*)::int n FROM exercises")).rows[0].n, 0);
    assert.equal((await as(null, "SELECT count(*)::int n FROM exercises")).rows[0].n, 0);
    await assert.rejects(as(A, "INSERT INTO exercises (name, primary_muscle) VALUES ('x','y')"), /row-level security/);
    const alts = (await as(COACH, "SELECT count(*)::int n FROM exercise_alternatives WHERE exercise_id = $1", [squat])).rows[0].n;
    assert.equal(alts, 5);
  });
  test("المدربة تبني قالباً وتسنده؛ المتدرب لا يرى القوالب", async () => {
    tpl = (await as(COACH, "INSERT INTO program_templates (name, weeks) VALUES ('قالب اختبار', 5) RETURNING id")).rows[0].id;
    const d = (await as(COACH, "INSERT INTO template_days (template_id, day_no, title) VALUES ($1, 1, 'DAY 1 — LOWER') RETURNING id", [tpl])).rows[0].id;
    const plan = JSON.stringify(Array(5).fill({ sets: 3, reps: [12, 12, 12], rir: 3 }));
    await as(COACH, "INSERT INTO template_items (day_id, position, exercise_id, plan) VALUES ($1,0,$2,$3), ($1,1,$4,$3)", [d, squat, plan, legExt]);
    assert.equal((await as(A, "SELECT count(*)::int n FROM program_templates")).rows[0].n, 0);
    await assert.rejects(as(A, "SELECT app.coach_assign_template($1,$2,current_date,NULL)", [noA, tpl]), /للمدربة فقط/);
    block = (await as(COACH, "SELECT app.coach_assign_template($1,$2,current_date,'Block 1') AS id", [noA, tpl])).rows[0].id;
    const items = (await owner.query("SELECT i.id, i.day_id FROM block_items i JOIN block_days d ON d.id = i.day_id WHERE d.block_id = $1 ORDER BY position", [block])).rows;
    [item, item2] = items.map((r) => r.id); day = items[0].day_id;
    assert.equal(items.length, 2);
  });
  test("المتدرب يرى برنامجه وتمارينه فقط؛ غيره لا يرى شيئاً", async () => {
    assert.equal((await as(A, "SELECT count(*)::int n FROM blocks")).rows[0].n, 1);
    assert.equal((await as(A, "SELECT count(*)::int n FROM block_items")).rows[0].n, 2);
    const ex = (await as(A, "SELECT name FROM app.block_exercises($1) ORDER BY name", [block])).rows.map((r) => r.name);
    assert.deepEqual(ex, ["Back Squat", "Leg Extension"]);
    assert.equal((await as(A, "SELECT * FROM app.block_exercises($1)", [block])).rows[0].notes, undefined);
    assert.equal((await as(B, "SELECT count(*)::int n FROM blocks")).rows[0].n, 0);
    assert.equal((await as(B, "SELECT count(*)::int n FROM block_items")).rows[0].n, 0);
    assert.equal((await as(B, "SELECT * FROM app.block_exercises($1)", [block])).rowCount, 0);
    assert.equal((await as(B, "SELECT * FROM app.swap_options($1)", [item])).rowCount, 0);
    // الكتابة المباشرة لا تمر (RLS: صفر صفوف)، والتمرين يبقى كما هو
    assert.equal((await as(A, "UPDATE block_items SET exercise_id = $2 WHERE id = $1", [item, notAlt])).rowCount, 0);
    assert.equal((await owner.query("SELECT exercise_id FROM block_items WHERE id = $1", [item])).rows[0].exercise_id, squat);
    await assert.rejects(as(A, "INSERT INTO block_notes (block_id, body) VALUES ($1, 'x')", [block]), /row-level security/);
  });
  test("التسجيل: صاحب البرنامج فقط، وأسبوع ضمن المدة، ويُستبدل عند التعديل", async () => {
    await as(A, "SELECT app.log_item($1, 1, 60, '{12,12,10}', 2)", [item]);
    await as(A, "SELECT app.log_item($1, 1, 62.5, '{}', NULL)", [item]);
    const l = (await as(A, "SELECT weight::float, reps, exercise_id FROM item_logs WHERE block_item_id = $1", [item])).rows;
    assert.equal(l.length, 1); assert.equal(l[0].weight, 62.5); assert.deepEqual(l[0].reps, []); assert.equal(l[0].exercise_id, squat);
    await assert.rejects(as(A, "SELECT app.log_item($1, 6, 60, '{}', NULL)", [item]), /الأسبوع/);
    await assert.rejects(as(B, "SELECT app.log_item($1, 1, 60, '{}', NULL)", [item]), /غير موجود/);
    // وزن لكل جولة: weight = الأثقل، والتسجيل القديم يمسح أوزان الجولات
    await as(A, "SELECT app.log_item_sets($1, 1, '{60,62.5,65}', '{10,9,8}', 1)", [item]);
    let s = (await as(A, "SELECT weight::float, weights::float[], reps FROM item_logs WHERE block_item_id = $1 AND week_no = 1", [item])).rows[0];
    assert.equal(s.weight, 65); assert.deepEqual(s.weights, [60, 62.5, 65]); assert.deepEqual(s.reps, [10, 9, 8]);
    await assert.rejects(as(A, "SELECT app.log_item_sets($1, 1, '{60,62.5}', '{10}', NULL)", [item]), /لكل جولة/);
    await assert.rejects(as(A, "SELECT app.log_item_sets($1, 1, '{60,2000}', '{10,10}', NULL)", [item]), /الوزن/);
    await assert.rejects(as(B, "SELECT app.log_item_sets($1, 1, '{60}', '{10}', NULL)", [item]), /غير موجود/);
    await as(A, "SELECT app.log_item($1, 1, 62.5, '{}', NULL)", [item]);
    s = (await as(A, "SELECT weight::float, weights FROM item_logs WHERE block_item_id = $1 AND week_no = 1", [item])).rows[0];
    assert.equal(s.weight, 62.5); assert.equal(s.weights, null);
    await assert.rejects(as(A, "INSERT INTO item_logs (block_item_id, week_no, exercise_id, weight) VALUES ($1, 2, $2, 1)", [item, squat]), /permission denied/);
    await as(A, "SELECT app.rate_day($1, 1, 4)", [day]);
    await assert.rejects(as(A, "SELECT app.rate_day($1, 1, 9)", [day]), /1 إلى 5/);
    await as(A, "SELECT app.log_steps($1, 1, 52000)", [block]);
    await as(A, "SELECT app.log_weight(current_date, 72.4)");
    await as(A, "SELECT app.log_measurements(current_date, NULL, 80, 98, NULL)");
    await assert.rejects(as(A, "SELECT app.log_weight(current_date + 3, 72)"), /التاريخ/);
    await assert.rejects(as(B, "SELECT app.log_weight(current_date, 72)"), /لا يوجد برنامج/);
    assert.equal((await as(B, "SELECT count(*)::int n FROM weight_logs")).rows[0].n, 0);
    assert.equal((await as(COACH, "SELECT count(*)::int n FROM weight_logs")).rows[0].n, 1);
  });
  test("التبديل: من بدائل اختيار المدربة فقط، ويُسجّل للمدربة كإشعار", async () => {
    const opts = (await as(A, "SELECT * FROM app.swap_options($1)", [item])).rows;
    assert.equal(opts[0].name, "Back Squat"); assert.equal(opts[0].is_coach_choice, true); assert.equal(opts[0].is_current, true);
    assert.ok(opts.some((o) => o.name === "Box Squat"));
    await assert.rejects(as(A, "SELECT app.swap_exercise($1,$2)", [item, notAlt]), /ليس من البدائل/);
    await assert.rejects(as(B, "SELECT app.swap_exercise($1,$2)", [item, boxSquat]), /غير موجود/);
    const r = (await as(A, "SELECT app.swap_exercise($1,$2) AS r", [item, boxSquat])).rows[0].r;
    assert.deepEqual(r, { changed: true, from: "Back Squat", to: "Box Squat" });
    // الرجوع لاختيار المدربة مسموح، والقائمة ما زالت مبنية على اختيارها
    assert.ok((await as(A, "SELECT * FROM app.swap_options($1)", [item])).rows.some((o) => o.name === "Back Squat" && o.is_coach_choice));
    assert.equal((await as(A, "SELECT count(*)::int n FROM exercise_swaps")).rows[0].n, 1);
    assert.equal((await as(B, "SELECT count(*)::int n FROM exercise_swaps")).rows[0].n, 0);
    assert.equal((await as(COACH, "SELECT count(*)::int n FROM exercise_swaps WHERE seen_at IS NULL")).rows[0].n, 1);
    // السجل السابق يبقى باسم التمرين الذي سُجّل عليه، والجديد باسم البديل
    await as(A, "SELECT app.log_item($1, 2, 50, '{}', NULL)", [item]);
    const logs = (await owner.query("SELECT week_no, exercise_id FROM item_logs WHERE block_item_id = $1 ORDER BY week_no", [item])).rows;
    assert.deepEqual(logs.map((l) => l.exercise_id), [squat, boxSquat]);
    assert.ok((await as(A, "SELECT name FROM app.block_exercises($1)", [block])).rows.some((e) => e.name === "Back Squat"));
    await assert.rejects(as(A, "SELECT app.coach_mark_swaps_seen($1)", [A]), /للمدربة فقط/);
    assert.equal((await as(COACH, "SELECT app.coach_mark_swaps_seen($1) AS n", [A])).rows[0].n, 1);
  });
  test("البرنامج المنتهي أو الطلب غير المدفوع: لا تسجيل", async () => {
    await owner.query("UPDATE orders SET status = 'cancelled' WHERE order_no = $1", [noA]);
    assert.equal((await as(A, "SELECT count(*)::int n FROM blocks")).rows[0].n, 0);
    await assert.rejects(as(A, "SELECT app.log_item($1, 1, 60, '{}', NULL)", [item]), /غير موجود/);
    await owner.query("UPDATE orders SET status = 'active' WHERE order_no = $1", [noA]);
    await as(COACH, "UPDATE blocks SET status = 'archived' WHERE id = $1", [block]);
    await assert.rejects(as(A, "SELECT app.log_item($1, 1, 60, '{}', NULL)", [item]), /منتهي/);
    await assert.rejects(as(A, "SELECT app.swap_exercise($1,$2)", [item2, squat]), /منتهي|ليس من البدائل/);
    await assert.rejects(as(A, "SELECT app.log_weight(current_date, 70)"), /لا يوجد برنامج/);
  });
});

describe("التغذية والمكملات", () => {
  let noA, tpl, meal, routineTpl, myPlan;
  before(async () => {
    noA = await newOrder(A, "k-nutrition-00000001");
    await owner.query("UPDATE orders SET status = 'active' WHERE order_no = $1", [noA]);
    tpl = (await owner.query("SELECT id FROM nutrition_plans WHERE order_id IS NULL AND name = 'الجدول الغذائي 1'")).rows[0].id;
    routineTpl = (await owner.query("SELECT id FROM supplement_routines WHERE order_id IS NULL LIMIT 1")).rows[0].id;
  });
  test("القوالب مستوردة ومحسوبة، ولا يراها غير المدربة", async () => {
    const t = (await as(COACH, `SELECT round(sum(i.protein*4 + i.carbs*4 + i.fat*9), 1)::float AS kcal FROM plan_items i JOIN plan_meals m ON m.id = i.meal_id WHERE m.plan_id = $1`, [tpl])).rows[0].kcal;
    assert.equal(t, 1748.5); // نفس «الحالي» في ورقة تغذية ١
    assert.equal((await as(A, "SELECT count(*)::int n FROM nutrition_plans")).rows[0].n, 0);
    assert.equal((await as(A, "SELECT count(*)::int n FROM supplement_items")).rows[0].n, 0);
    await assert.rejects(as(A, "INSERT INTO nutrition_plans (name) VALUES ('x')"), /row-level security/);
  });
  test("الإسناد ينسخ القالب للمتدرب فقط، وتعديل النسخة لا يغيّر القالب", async () => {
    await assert.rejects(as(A, "SELECT app.coach_assign_nutrition($1,$2)", [noA, tpl]), /للمدربة فقط/);
    myPlan = (await as(COACH, "SELECT app.coach_assign_nutrition($1,$2) AS id", [noA, tpl])).rows[0].id;
    await as(COACH, "SELECT app.coach_assign_supplements($1,$2)", [noA, routineTpl]);
    await as(COACH, "INSERT INTO nutrition_targets (order_id, kcal, protein, carbs, fat) SELECT id, 1885, 125, 200, 62 FROM orders WHERE order_no = $1", [noA]);
    await as(COACH, "UPDATE plan_items SET protein = 99 WHERE meal_id IN (SELECT id FROM plan_meals WHERE plan_id = $1)", [myPlan]);
    assert.equal((await owner.query("SELECT count(*)::int n FROM plan_items i JOIN plan_meals m ON m.id = i.meal_id WHERE m.plan_id = $1 AND i.protein = 99", [tpl])).rows[0].n, 0);
    assert.equal((await as(A, "SELECT count(*)::int n FROM nutrition_plans")).rows[0].n, 1);
    assert.ok((await as(A, "SELECT count(*)::int n FROM plan_items")).rows[0].n > 0);
    assert.equal((await as(A, "SELECT count(*)::int n FROM supplement_items")).rows[0].n, 11);
    assert.equal((await as(A, "SELECT kcal FROM nutrition_targets")).rows[0].kcal, 1885);
    assert.equal((await as(B, "SELECT count(*)::int n FROM nutrition_plans")).rows[0].n, 0);
    assert.equal((await as(B, "SELECT count(*)::int n FROM nutrition_targets")).rows[0].n, 0);
    meal = (await as(A, "SELECT id FROM plan_meals ORDER BY position LIMIT 1")).rows[0].id;
  });
  test("سجل الأكل: من وجبات المتدرب أو إدخال حر، لصاحبه فقط", async () => {
    await as(A, "SELECT app.log_food($1, current_date, 'breakfast', $2, NULL, 0, 0, 0)", [noA, meal]);
    await as(A, "SELECT app.log_food($1, current_date, 'snack', NULL, 'تفاحة', 0.5, 25, 0.3)", [noA]);
    const rows = (await as(A, "SELECT name, protein::float FROM food_logs ORDER BY id")).rows;
    assert.equal(rows.length, 2); assert.match(rows[0].name, /الجدول الغذائي 1/); assert.equal(rows[1].protein, 0.5);
    await assert.rejects(as(A, "SELECT app.log_food($1, current_date, 'lunch', NULL, '', 1, 1, 1)", [noA]), /اسم الأكلة/);
    await assert.rejects(as(A, "SELECT app.log_food($1, current_date + 1, 'lunch', NULL, 'x', 1, 1, 1)", [noA]), /التاريخ/);
    const tplMeal = (await owner.query("SELECT id FROM plan_meals WHERE plan_id = $1 LIMIT 1", [tpl])).rows[0].id;
    await assert.rejects(as(A, "SELECT app.log_food($1, current_date, 'lunch', $2, NULL, 0, 0, 0)", [noA, tplMeal]), /غير موجودة في جداولك/);
    await assert.rejects(as(B, "SELECT app.log_food($1, current_date, 'lunch', NULL, 'x', 1, 1, 1)", [noA]), /غير موجود/);
    assert.equal((await as(B, "SELECT count(*)::int n FROM food_logs")).rows[0].n, 0);
    assert.equal((await as(COACH, "SELECT count(*)::int n FROM food_logs")).rows[0].n, 2);
    const id = (await as(A, "SELECT id FROM food_logs ORDER BY id DESC LIMIT 1")).rows[0].id;
    await assert.rejects(as(B, "SELECT app.delete_food_log($1)", [id]), /غير موجود/);
    await as(A, "SELECT app.delete_food_log($1)", [id]);
    await assert.rejects(as(A, "INSERT INTO food_logs (user_id, order_id, log_date, kind, name, protein, carbs, fat) SELECT $1, id, current_date, 'lunch', 'x', 1, 1, 1 FROM orders LIMIT 1", [A]), /permission denied/);
  });
  test("الطلب غير المدفوع أو الجدول المخفي: لا يظهر", async () => {
    await as(COACH, "UPDATE nutrition_plans SET archived = true WHERE id = $1", [myPlan]);
    assert.equal((await as(A, "SELECT count(*)::int n FROM nutrition_plans")).rows[0].n, 0);
    await as(COACH, "UPDATE nutrition_plans SET archived = false WHERE id = $1", [myPlan]);
    await owner.query("UPDATE orders SET status = 'cancelled' WHERE order_no = $1", [noA]);
    assert.equal((await as(A, "SELECT count(*)::int n FROM nutrition_plans")).rows[0].n, 0);
    assert.equal((await as(A, "SELECT count(*)::int n FROM supplement_routines")).rows[0].n, 0);
    await assert.rejects(as(A, "SELECT app.log_food($1, current_date, 'lunch', NULL, 'x', 1, 1, 1)", [noA]), /غير موجود/);
  });
});

describe("قاعدة الأكل بالغرامات", () => {
  let noA, rice;
  before(async () => {
    noA = await newOrder(A, "k-foods-000000000001");
    await owner.query("UPDATE orders SET status = 'active' WHERE order_no = $1", [noA]);
  });
  test("الإضافة للمدربة فقط، والقراءة للمسجّلين (النشط فقط)", async () => {
    await assert.rejects(as(A, "INSERT INTO foods (name_ar, kcal_100, protein_100, carbs_100, fat_100) VALUES ('صنف', 1, 1, 1, 1)"), /row-level security/);
    rice = (await as(COACH, "INSERT INTO foods (name_ar, name_en, kcal_100, protein_100, carbs_100, fat_100, serving_g) VALUES ('رز اختبار مطبوخ', 'Test rice', 130, 2.7, 28.2, 0.3, 150) RETURNING id")).rows[0].id;
    await as(COACH, "INSERT INTO foods (name_ar, kcal_100, protein_100, carbs_100, fat_100, active) VALUES ('صنف مخفي', 1, 0, 0, 0, false)");
    assert.equal((await as(A, "SELECT count(*)::int n FROM foods WHERE name_ar LIKE 'رز اختبار%'")).rows[0].n, 1);
    assert.equal((await as(A, "SELECT count(*)::int n FROM foods WHERE name_ar = 'صنف مخفي'")).rows[0].n, 0);
    assert.equal((await as(null, "SELECT count(*)::int n FROM foods")).rows[0].n, 0);
  });
  test("التسجيل بالغرامات: قاعدة البيانات تحسب الماكروز", async () => {
    await as(A, "SELECT app.log_food_grams($1, current_date, 'lunch', $2, 150)", [noA, rice]);
    const r = (await as(A, "SELECT name, grams::float, protein::float, carbs::float, fat::float, source FROM food_logs WHERE food_id = $1", [rice])).rows[0];
    assert.deepEqual(r, { name: "رز اختبار مطبوخ — 150غ", grams: 150, protein: 4.1, carbs: 42.3, fat: 0.5, source: "food" });
    await assert.rejects(as(A, "SELECT app.log_food_grams($1, current_date, 'lunch', $2, 0)", [noA, rice]), /بالغرام/);
    await assert.rejects(as(A, "SELECT app.log_food_grams($1, current_date, 'lunch', $2, 5000)", [noA, rice]), /بالغرام/);
    await assert.rejects(as(B, "SELECT app.log_food_grams($1, current_date, 'lunch', $2, 100)", [noA, rice]), /غير موجود/);
    const hidden = (await owner.query("SELECT id FROM foods WHERE name_ar = 'صنف مخفي'")).rows[0].id;
    await assert.rejects(as(A, "SELECT app.log_food_grams($1, current_date, 'lunch', $2, 100)", [noA, hidden]), /الصنف غير موجود/);
  });
  test("FatSecret: القيم لكل 100غ تُحسب في القاعدة، وتسجيل الجداول يُعلَّم plan", async () => {
    await as(A, "SELECT app.log_food_external($1, current_date, 'snack', 'Greek Yogurt (Almarai)', 170, 10, 4, 0)", [noA]);
    const r = (await as(A, "SELECT protein::float, carbs::float, source FROM food_logs WHERE source = 'fatsecret'")).rows[0];
    assert.deepEqual(r, { protein: 17, carbs: 6.8, source: "fatsecret" });
    await assert.rejects(as(A, "SELECT app.log_food_external($1, current_date, 'snack', 'x', 100, 150, 0, 0)", [noA]), /غير صحيحة/);
  });
});

describe("التجديد بخصم ومكافأة الالتزام", () => {
  // اشتراك A بباقة 3 أشهر ينتهي بعد 4 أيام
  let noA;
  before(async () => {
    noA = await newOrder(A, "k-renew-00000000001", "int3");
    await owner.query("UPDATE orders SET status = 'active' WHERE order_no = $1", [noA]);
    await owner.query("UPDATE orders SET sub_start_at = now() - interval '86 days', sub_end_at = now() + interval '4 days' WHERE order_no = $1", [noA]);
  });
  test("خارج آخر 5 أيام: مرفوض", async () => {
    await owner.query("UPDATE orders SET sub_end_at = now() + interval '9 days' WHERE order_no = $1", [noA]);
    await assert.rejects(as(A, "SELECT app.create_renewal($1)", [noA]), /آخر 5 أيام/);
    await owner.query("UPDATE orders SET sub_end_at = now() - interval '2 days' WHERE order_no = $1", [noA]);
    await assert.rejects(as(A, "SELECT app.create_renewal($1)", [noA]), /آخر 5 أيام/);
    await owner.query("UPDATE orders SET sub_end_at = now() + interval '4 days' WHERE order_no = $1", [noA]);
  });
  test("مستخدم آخر لا يجدد طلب غيره، والطلب غير النشط لا يُجدَّد", async () => {
    await assert.rejects(as(B, "SELECT app.create_renewal($1)", [noA]), /غير موجود/);
    const pending = await newOrder(A, "k-renew-00000000002", "int3");
    await assert.rejects(as(A, "SELECT app.create_renewal($1)", [pending]), /لا يقبل التجديد/);
  });
  test("التجديد: 90% من سعر الباقة الحالي، مرة واحدة، مع نسخة الاستبيان", async () => {
    const r1 = (await as(A, "SELECT app.create_renewal($1) AS no", [noA])).rows[0].no;
    const r2 = (await as(A, "SELECT app.create_renewal($1) AS no", [noA])).rows[0].no;
    assert.equal(r1, r2);
    const o = (await as(A, "SELECT status, list_price_halalas, amount_due_halalas, months, renewal_kind FROM orders WHERE order_no = $1", [r1])).rows[0];
    assert.deepEqual(o, { status: "awaiting_payment", list_price_halalas: 155000, amount_due_halalas: 139500, months: 3, renewal_kind: "renewal" });
    assert.equal((await as(A, "SELECT count(*)::int n FROM intakes i JOIN orders o ON o.id = i.order_id WHERE o.order_no = $1", [r1])).rows[0].n, 1);
    assert.match((await as(A, "SELECT note FROM order_events e JOIN orders o ON o.id = e.order_id WHERE o.order_no = $1", [r1])).rows[0].note, /خصم 10%/);
    // المبلغ لا يتغير من المتدرب
    await assert.rejects(as(A, "UPDATE orders SET amount_due_halalas = 1 WHERE order_no = $1 RETURNING 1", [r1]).then((r) => { if (r.rowCount === 0) throw new Error("permission denied"); }), /permission denied/);
  });
  test("عند التفعيل يبدأ التجديد من نهاية الاشتراك الحالي", async () => {
    const r = (await as(A, "SELECT order_no FROM orders WHERE renewal_kind = 'renewal'")).rows[0].order_no;
    await owner.query("UPDATE orders SET status = 'active' WHERE order_no = $1", [r]);
    const d = (await owner.query(
      "SELECT n.sub_start_at = o.sub_end_at AS same, n.sub_end_at = o.sub_end_at + interval '3 months' AS plus3, n.review_weekday = o.review_weekday AS wd FROM orders n JOIN orders o ON o.id = n.renewal_of WHERE n.order_no = $1", [r])).rows[0];
    assert.deepEqual(d, { same: true, plus3: true, wd: true });
  });
  test("المكافأة: للمدربة فقط، 90% فأكثر، مرة واحدة، وتبدأ بعد آخر اشتراك", async () => {
    await assert.rejects(as(A, "SELECT app.coach_grant_reward($1, 0.95)", [noA]), /للمدربة فقط/);
    await assert.rejects(as(COACH, "SELECT app.coach_grant_reward($1, 0.89)", [noA]), /أقل من 90/);
    const short = await newOrder(A, "k-renew-00000000003", "int1");
    await owner.query("UPDATE orders SET status = 'active' WHERE order_no = $1", [short]);
    await assert.rejects(as(COACH, "SELECT app.coach_grant_reward($1, 0.95)", [short]), /3 أشهر فأكثر/);
    const rw = (await as(COACH, "SELECT app.coach_grant_reward($1, 0.93) AS no", [noA])).rows[0].no;
    await assert.rejects(as(COACH, "SELECT app.coach_grant_reward($1, 0.95)", [noA]), /من قبل/);
    const o = (await owner.query(
      "SELECT r.status, r.amount_due_halalas, r.months, r.sub_start_at = (SELECT sub_end_at FROM orders WHERE renewal_kind = 'renewal' AND renewal_of = r.renewal_of) AS after_renewal FROM orders r WHERE r.order_no = $1", [rw])).rows[0];
    assert.deepEqual(o, { status: "active", amount_due_halalas: 0, months: 3, after_renewal: true });
    assert.equal((await as(A, "SELECT count(*)::int n FROM loyalty_rewards")).rows[0].n, 1);
    assert.equal((await as(B, "SELECT count(*)::int n FROM loyalty_rewards")).rows[0].n, 0);
    await assert.rejects(as(A, "INSERT INTO loyalty_rewards (order_id) SELECT id FROM orders LIMIT 1"), /permission denied/);
  });
});

describe("استبيان نهاية البرنامج", () => {
  let noA;
  before(async () => {
    noA = await newOrder(A, "k-exit-000000000001", "int1");
    await owner.query("UPDATE orders SET status = 'active' WHERE order_no = $1", [noA]);
  });
  test("قبل نهاية الاشتراك: مرفوض", async () => {
    await owner.query("UPDATE orders SET sub_end_at = now() + interval '3 days' WHERE order_no = $1", [noA]);
    await assert.rejects(as(A, "SELECT app.submit_exit_survey($1, true, 'حاب أكمل', 'ممتازة')", [noA]), /عند نهاية البرنامج/);
  });
  test("عند النهاية: صاحب الطلب فقط، مرة واحدة، والمدربة تقرأ وتعلّم «اطّلعت»", async () => {
    await owner.query("UPDATE orders SET sub_end_at = now() - interval '1 day' WHERE order_no = $1", [noA]);
    await assert.rejects(as(B, "SELECT app.submit_exit_survey($1, true, 'سبب', 'تجربة')", [noA]), /غير موجود/);
    await assert.rejects(as(A, "SELECT app.submit_exit_survey($1, true, ' ', 'تجربة')", [noA]), /السبب/);
    await as(A, "SELECT app.submit_exit_survey($1, false, 'ظروف سفر', 'تجربة رائعة ومتابعة دقيقة')", [noA]);
    await assert.rejects(as(A, "SELECT app.submit_exit_survey($1, true, 'سبب', 'تجربة')", [noA]), /من قبل/);
    assert.equal((await as(B, "SELECT count(*)::int n FROM exit_surveys")).rows[0].n, 0);
    assert.equal((await as(A, "SELECT count(*)::int n FROM exit_surveys")).rows[0].n, 1);
    await assert.rejects(as(A, "SELECT app.coach_mark_survey_seen($1)", [noA]), /للمدربة فقط/);
    await as(COACH, "SELECT app.coach_mark_survey_seen($1)", [noA]);
    const r = (await as(COACH, "SELECT wants_renewal, reason, seen_at IS NOT NULL AS seen FROM exit_surveys")).rows[0];
    assert.deepEqual(r, { wants_renewal: false, reason: "ظروف سفر", seen: true });
    await assert.rejects(as(A, "INSERT INTO exit_surveys (order_id, user_id, wants_renewal, reason, experience) SELECT id, user_id, true, 'x1', 'x2' FROM orders LIMIT 1"), /permission denied/);
  });
});

describe("الحالات: تفعيل مباشر بعد الدفع، وانتهاء الاشتراك تلقائياً", () => {
  test("من «بانتظار الدفع» إلى «تفعيل البرنامج» بتأكيد وصول المبلغ فقط، ولباقات المتابعة فقط", async () => {
    const no = await newOrder(A, "k-status-000000000001", "int1");
    await assert.rejects(as(COACH, "SELECT app.coach_transition($1, 'active', NULL, false)", [no]), /كشف الحساب/);
    await as(COACH, "SELECT app.coach_transition($1, 'active', NULL, true)", [no]);
    const o = (await owner.query("SELECT status, paid_at IS NOT NULL AS paid, sub_start_at IS NOT NULL AS started FROM orders WHERE order_no = $1", [no])).rows[0];
    assert.deepEqual(o, { status: "active", paid: true, started: true });
    const files = await newOrder(A, "k-status-000000000002", "diy");
    await assert.rejects(as(COACH, "SELECT app.coach_transition($1, 'active', NULL, true)", [files]), /غير مسموح/);
    await assert.rejects(as(A, "SELECT app.coach_transition($1, 'active', NULL, true)", [files]), /للمدربة فقط/);
  });
  test("انتهاء الاشتراك تلقائياً بعد يوم انتهائه فقط، ومرة واحدة", async () => {
    const past = await newOrder(A, "k-status-000000000003", "int1");
    const today = await newOrder(A, "k-status-000000000004", "int1");
    await owner.query("UPDATE orders SET status = 'active' WHERE order_no = ANY($1)", [[past, today]]);
    await owner.query("UPDATE orders SET sub_end_at = now() - interval '2 days' WHERE order_no = $1", [past]);
    await owner.query("UPDATE orders SET sub_end_at = now() WHERE order_no = $1", [today]);
    await assert.rejects(as(A, "SELECT app.expire_subscriptions()"), /للمدربة فقط/);
    const nos = (await as(COACH, "SELECT app.expire_subscriptions() AS n")).rows[0].n;
    assert.ok(nos.includes(past) && !nos.includes(today));
    assert.equal((await owner.query("SELECT status FROM orders WHERE order_no = $1", [past])).rows[0].status, "completed");
    assert.equal((await owner.query("SELECT status FROM orders WHERE order_no = $1", [today])).rows[0].status, "active");
    assert.match((await owner.query("SELECT e.note FROM order_events e JOIN orders o ON o.id = e.order_id WHERE o.order_no = $1 ORDER BY e.id DESC LIMIT 1", [past])).rows[0].note, /تلقائياً/);
    assert.ok(!(await as(COACH, "SELECT app.expire_subscriptions() AS n")).rows[0].n.includes(past));
  });
});

describe("ربط أسماء التمارين من التطبيقات الخارجية", () => {
  test("لصاحبه فقط، ولتمرين موجود في برنامجه فقط", async () => {
    const noA = await newOrder(A, "k-alias-000000000001", "int1");
    await owner.query("UPDATE orders SET status = 'active' WHERE order_no = $1", [noA]);
    const ex = (await owner.query("SELECT id FROM exercises ORDER BY name LIMIT 2")).rows;
    const { rows: [b] } = await owner.query(
      `INSERT INTO blocks (order_id, user_id, name, start_date, weeks) SELECT id, user_id, 'b', current_date, 4 FROM orders WHERE order_no = $1 RETURNING id`, [noA]);
    const { rows: [d] } = await owner.query(`INSERT INTO block_days (block_id, day_no, title) VALUES ($1, 1, 'D1') RETURNING id`, [b.id]);
    await owner.query(`INSERT INTO block_items (day_id, position, exercise_id, coach_exercise_id, plan) VALUES ($1, 1, $2, $2, '[]')`, [d.id, ex[0].id]);
    await as(A, "SELECT app.save_exercise_alias('leg press', $1)", [ex[0].id]);
    await as(A, "SELECT app.save_exercise_alias('leg press', $1)", [ex[0].id]); // تكرار آمن
    await assert.rejects(as(A, "SELECT app.save_exercise_alias('x', $1)", [ex[1].id]), /غير موجود في برنامجك/);
    await assert.rejects(as(B, "SELECT app.save_exercise_alias('leg press', $1)", [ex[0].id]), /غير موجود في برنامجك/);
    assert.equal((await as(A, "SELECT count(*)::int n FROM exercise_aliases")).rows[0].n, 1);
    assert.equal((await as(B, "SELECT count(*)::int n FROM exercise_aliases")).rows[0].n, 0);
    await assert.rejects(as(A, "INSERT INTO exercise_aliases (user_id, external_name, exercise_id) VALUES ($1, 'y', $2)", [A, ex[1].id]), /permission denied/);
  });
});
