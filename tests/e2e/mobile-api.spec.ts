// واجهات تطبيق الجوال (/api/mobile/v1) عبر HTTP كما يستدعيها التطبيق: ترويسة expo-origin وكوكي الجلسة يدوياً.
import { test } from "@playwright/test";
import assert from "node:assert/strict";
import pg from "pg";
import sharp from "sharp";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const B = "http://localhost:3100";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

test("التطبيق: مصدر غير موثوق مرفوض، والبرامج المجانية عامة", async () => {
  const r = await fetch(`${B}/api/auth/email-otp/send-verification-otp`, {
    method: "POST", headers: { "content-type": "application/json", "expo-origin": "evil://", "x-forwarded-for": "10.9.1.1" },
    body: JSON.stringify({ email: "x@e2e.test", type: "sign-in" }),
  });
  assert.equal(r.status, 403);
  const p = await fetch(`${B}/api/mobile/v1/programs`);
  assert.equal(p.status, 200);
  assert.ok(Array.isArray((await p.json()).programs));
});

test("التطبيق: برنامج المتدرب، التسجيل، الطلبات والإيصال، وحذف الحساب", async ({}, info) => {
  test.skip(info.project.name !== "desktop", "اختبار واجهات فقط: مرة واحدة يكفي");
  const email = `app-trainee-${Date.now()}@e2e.test`;
  const H = { "expo-origin": "navcoaching://", "x-forwarded-for": `10.9.${Date.now() % 250}.7` };
  const j = (r) => r.json();
  let cookie = "";
  const call = (path, init = {}) => fetch(B + path, { ...init, headers: { ...H, ...(cookie ? { Cookie: cookie } : {}), ...init.headers } });

  // دخول
  await call("/api/auth/email-otp/send-verification-otp", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email, type: "sign-in" }) });
  const otp = (await db.query("SELECT substring(body from 'رمز الدخول: ([0-9]{6})') AS o FROM dev_mailbox WHERE recipient=$1 ORDER BY id DESC LIMIT 1", [email])).rows[0].o;
  const r = await call("/api/auth/sign-in/email-otp", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ email, otp }) });
  cookie = r.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
  assert.equal(r.status, 200);

  // بدون اشتراك
  assert.deepEqual(await j(await call("/api/mobile/v1/coaching")), { coaching: null });

  // اشتراك نشط + برنامج (مثل اختبارات الموقع)
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email=$1`, [email]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id=p.id WHERE p.slug='intensive' AND o.months=3`);
  const no = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no;
  const { rows: [ord] } = await db.query(`INSERT INTO orders (order_no,user_id,product_id,offer_id,category,product_name,offer_label,months,list_price_halalas,amount_due_halalas,status,contact_name,contact_phone,idempotency_key,paid_at)
    VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active','متدرب','+966512345678',$8,now()) RETURNING id`, [no, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas, `k-${no}`]);
  const { rows: [ex] } = await db.query(`SELECT id FROM exercises WHERE name='Back Squat'`);
  const { rows: [blk] } = await db.query(`INSERT INTO blocks (order_id,user_id,name,start_date,weeks) VALUES ($1,$2,'بلوك القوة',current_date,4) RETURNING id`, [ord.id, u.id]);
  const { rows: [day] } = await db.query(`INSERT INTO block_days (block_id,day_no,title) VALUES ($1,1,'سفلي') RETURNING id`, [blk.id]);
  const { rows: [item] } = await db.query(`INSERT INTO block_items (day_id,position,exercise_id,coach_exercise_id,plan) VALUES ($1,0,$2,$2,'[{"sets":3,"reps":[10,10,10],"rir":2}]') RETURNING id`, [day.id, ex.id]);
  await db.query(`INSERT INTO block_notes (block_id, body) VALUES ($1, 'ركز على العمق')`, [blk.id]);

  const c1 = (await j(await call("/api/mobile/v1/coaching"))).coaching;
  assert.equal(c1.order.order_no, no);
  assert.equal(c1.block.name, "بلوك القوة");
  assert.equal(c1.block.current_week, 1);
  assert.equal(c1.days[0].items[0].exercise.name, "Back Squat");
  assert.deepEqual(c1.days[0].items[0].plan[0].reps, [10, 10, 10]);
  assert.equal(c1.notes[0].body, "ركز على العمق");

  // تسجيل تمرين عبر نفس عملية الموقع
  const fd = new FormData();
  fd.set("item", item.id); fd.set("week", "1"); fd.set("order_no", no); fd.set("rir", "2");
  for (const w of ["60", "", "62.5"]) fd.append("set_weight", w);
  for (const x of ["10", "9", ""]) fd.append("reps", x);
  const lr = await call("/api/mobile/v1/actions/log-item", { method: "POST", body: fd });
  assert.equal(lr.status, 200, JSON.stringify(await lr.clone().json()));
  const c2 = (await j(await call("/api/mobile/v1/coaching"))).coaching;
  assert.deepEqual(c2.logs[0], { item: item.id, week: 1, weights: [60, 60, 62.5], reps: [10, 9, 10], rir: 2 });
  const bad = new FormData(); bad.set("item", item.id); bad.set("week", "1"); bad.append("set_weight", "abc"); bad.append("reps", "10");
  assert.equal((await call("/api/mobile/v1/actions/log-item", { method: "POST", body: bad })).status, 422);
  assert.equal((await call("/api/mobile/v1/actions/not-allowed", { method: "POST", body: new FormData() })).status, 404);

  // طلب ينتظر الدفع + رفع إيصال
  const no2 = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no;
  await db.query(`INSERT INTO orders (order_no,user_id,product_id,offer_id,category,product_name,offer_label,months,list_price_halalas,amount_due_halalas,status,contact_name,contact_phone,idempotency_key)
    VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'awaiting_payment','متدرب','+966512345678',$8)`, [no2, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas, `k-${no2}`]);
  const ol = await j(await call("/api/mobile/v1/orders"));
  assert.equal(ol.orders.length, 2);
  assert.ok(ol.bank && ol.bank.iban !== undefined, "bank shown for awaiting payment");
  const o2 = ol.orders.find((o) => o.order_no === no2);
  assert.equal(o2.status, "awaiting_payment");

  const png = await sharp({ create: { width: 400, height: 600, channels: 3, background: "#ffffff" } }).png().toBuffer();
  const up = new FormData(); up.set("order_no", no2); up.set("proof", new Blob([png], { type: "image/png" }), "receipt.png");
  const ur = await call("/api/mobile/v1/actions/upload-proof", { method: "POST", body: up });
  const urj = await ur.json();
  assert.equal(ur.status, 200, JSON.stringify(urj));
  assert.equal((await db.query("SELECT status FROM orders WHERE order_no=$1", [no2])).rows[0].status, "payment_review");

  // غير المسجّل
  const saved = cookie; cookie = "";
  assert.equal((await call("/api/mobile/v1/coaching")).status, 401);
  assert.equal((await call("/api/mobile/v1/actions/log-item", { method: "POST", body: fd })).status, 401);
  cookie = saved;

  // حذف الحساب
  assert.equal((await call("/api/mobile/v1/account/delete", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ confirm: "نعم" }) })).status, 422);
  const dr = await call("/api/mobile/v1/account/delete", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ confirm: "حذف" }) });
  assert.equal(dr.status, 200, JSON.stringify(await dr.clone().json()));
  assert.equal((await db.query(`SELECT count(*)::int n FROM "user" WHERE email=$1`, [email])).rows[0].n, 0);
  assert.equal((await db.query(`SELECT count(*)::int n FROM orders WHERE order_no = ANY($1)`, [[no, no2]])).rows[0].n, 0);
  const log = (await db.query(`SELECT details FROM admin_log WHERE action='member.self_delete' AND target=$1`, [email])).rows[0];
  assert.deepEqual(log.details.orders.sort(), [no, no2].sort());
  assert.equal((await call("/api/mobile/v1/me")).status, 401, "session gone");

  // المدربة لا تحذف نفسها
});
