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
  // تقييم اليوم
  const rd = new FormData(); rd.set("day", day.id); rd.set("week", "1"); rd.set("rating", "4"); rd.set("order_no", no);
  assert.equal((await call("/api/mobile/v1/actions/rate-day", { method: "POST", body: rd })).status, 200);
  assert.deepEqual((await j(await call("/api/mobile/v1/coaching"))).coaching.ratings, [{ day: day.id, week: 1, rating: 4 }]);

  // التقدم: الوزن والقياسات والخطوات والأرقام القياسية
  const pr0 = (await j(await call("/api/mobile/v1/progress"))).progress;
  const send = (name: string, fields: Record<string, string>) => {
    const f = new FormData(); for (const [k, v] of Object.entries(fields)) f.set(k, v);
    return call(`/api/mobile/v1/actions/${name}`, { method: "POST", body: f });
  };
  assert.equal((await send("log-weight", { date: pr0.today, kg: "72.4" })).status, 200);
  assert.equal((await send("log-weight", { date: pr0.today, kg: "900" })).status, 422);
  assert.equal((await send("log-measurements", { date: pr0.today, waist: "80" })).status, 200);
  assert.equal((await send("log-steps", { block: pr0.steps.block, week: "1", total: "42000" })).status, 200);
  const pr1 = (await j(await call("/api/mobile/v1/progress"))).progress;
  assert.equal(pr1.body.weights.at(-1).kg, 72.4);
  assert.equal(pr1.body.measurements.at(-1).waist, 80);
  assert.deepEqual(pr1.steps.logs, [{ week_no: 1, total: 42000 }]);
  assert.equal(pr1.records[0].name, "Back Squat");

  // التغذية: الأهداف، إضافة أكل حر ومن قاعدة الأكل بالغرام، والحذف
  await db.query(`INSERT INTO nutrition_targets (order_id, kcal, protein, carbs, fat) VALUES ($1, 2000, 150, 200, 60)`, [ord.id]);
  const n0 = (await j(await call("/api/mobile/v1/nutrition"))).nutrition;
  assert.equal(n0.target.kcal, 2000);
  assert.equal((await send("log-food", { order_no: no, date: n0.date, kind: "lunch", name: "رز ودجاج", protein: "40", carbs: "60", fat: "10" })).status, 200);
  const { rows: [food] } = await db.query(`SELECT id FROM foods WHERE active LIMIT 1`);
  assert.equal((await send("log-food-grams", { order_no: no, date: n0.date, kind: "snack", source: "local", food: food.id, grams: "150" })).status, 200);
  assert.equal((await send("log-food", { order_no: no, date: n0.date, kind: "lunch", name: "" })).status, 422);
  const n1 = (await j(await call("/api/mobile/v1/nutrition"))).nutrition;
  assert.equal(n1.logs.length, 2);
  assert.equal(n1.logs[0].kcal, 40 * 4 + 60 * 4 + 10 * 9);
  assert.equal((await send("delete-food-log", { id: String(n1.logs[0].id), order_no: no })).status, 200);
  assert.equal((await j(await call("/api/mobile/v1/nutrition"))).nutrition.logs.length, 1);
  const fs = await call(`/api/foods/search?q=${encodeURIComponent("دجاج")}`);
  assert.equal(fs.status, 200);

  const bad = new FormData(); bad.set("item", item.id); bad.set("week", "1"); bad.append("set_weight", "abc"); bad.append("reps", "10");
  assert.equal((await call("/api/mobile/v1/actions/log-item", { method: "POST", body: bad })).status, 422);
  assert.equal((await call("/api/mobile/v1/actions/not-allowed", { method: "POST", body: new FormData() })).status, 404);

  // تفاصيل الطلب: الملفات (رابط من المدربة)، المراجعة الأسبوعية، والتقييم
  await db.query(`INSERT INTO deliverables (order_id, title, kind, url) VALUES ($1, 'دليل التمارين', 'link', 'https://example.com/guide')`, [ord.id]);
  const d0 = await j(await call(`/api/mobile/v1/orders/${no}`));
  assert.equal(d0.entitled, true);
  assert.deepEqual(d0.files.map((f: { title: string; kind: string }) => [f.title, f.kind]), [["دليل التمارين", "link"]]);
  assert.equal(d0.review.status, "none");
  if (d0.checkin?.can_submit) {
    const cf = new FormData(); cf.set("order_no", no);
    for (const q of d0.checkin.questions) { cf.append("topic", q.topic); cf.append("q", q.q); cf.append("a", "أسبوع ممتاز"); }
    assert.equal((await call("/api/mobile/v1/actions/submit-checkin", { method: "POST", body: cf })).status, 200);
    assert.equal((await j(await call(`/api/mobile/v1/orders/${no}`))).checkin.history.length, 1);
  }
  const rv = new FormData(); rv.set("order_no", no); rv.set("rating", "5"); rv.set("body", "تجربة رائعة ومتابعة ممتازة"); rv.set("display_mode", "first"); rv.set("consent", "on");
  assert.equal((await call("/api/mobile/v1/actions/submit-review", { method: "POST", body: rv })).status, 200);
  assert.equal((await j(await call(`/api/mobile/v1/orders/${no}`))).review.status, "pending");
  assert.equal((await call(`/api/mobile/v1/orders/NOPE-000`)).status, 404);

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

  // الملف الشخصي وتفضيلات التواصل
  const send2 = (name: string, fields: Record<string, string>) => {
    const f = new FormData(); for (const [k, v] of Object.entries(fields)) f.set(k, v);
    return call(`/api/mobile/v1/actions/${name}`, { method: "POST", body: f });
  };
  assert.equal((await send2("update-profile", { name: "نورة" })).status, 200);
  assert.equal((await send2("save-prefs", { email_enabled: "on" })).status, 200);
  const prof = await j(await call("/api/mobile/v1/profile"));
  assert.equal(prof.name, "نورة");
  assert.deepEqual(prof.prefs, { email: true, whatsapp: false });

  // تبديل التمرين ببديل من قائمة المدربة
  const sw = (await j(await call(`/api/mobile/v1/coaching/swaps?item=${item.id}`))).options;
  const alt = sw.find((o: { is_current: boolean }) => !o.is_current);
  assert.ok(alt, "Back Squat له بدائل في المكتبة");
  assert.equal((await send2("swap-exercise", { item: item.id, exercise: alt.id, order_no: no })).status, 200);
  assert.equal((await j(await call("/api/mobile/v1/coaching"))).coaching.days[0].items[0].exercise.name, alt.name);

  // موعد البداية لطلب لم يبدأ
  const dS = await j(await call(`/api/mobile/v1/orders/${no2}`));
  assert.ok(dS.start, "الطلب قبل التفعيل يعرض موعد البداية");
  assert.equal((await send2("set-start-pref", { order_no: no2, start_mode: "date", start_date: dS.start.range.min })).status, 200);
  assert.equal((await j(await call(`/api/mobile/v1/orders/${no2}`))).start.pref.slice(0, 10), dS.start.range.min);
  assert.equal((await send2("set-start-pref", { order_no: no2, start_mode: "date", start_date: "2000-01-01" })).status, 422);

  // التجديد بخصم في آخر أيام الاشتراك
  await db.query(`UPDATE orders SET sub_start_at = now() - interval '85 days', sub_end_at = now() + interval '3 days' WHERE order_no = $1`, [no]);
  const dR = await j(await call(`/api/mobile/v1/orders/${no}`));
  assert.equal(dR.renewal.kind, "offer");
  const rn = await send2("renew", { order_no: no });
  const rnj = await rn.json();
  assert.equal(rn.status, 200, JSON.stringify(rnj));
  assert.equal((await j(await call(`/api/mobile/v1/orders/${no}`))).renewal.kind, "pending");
  assert.equal((await db.query(`SELECT renewal_kind, status FROM orders WHERE order_no = $1`, [rnj.message])).rows[0].renewal_kind, "renewal");

  // استبيان نهاية البرنامج (اشتراك منتهٍ بدون تجديد)
  const no4 = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no;
  await db.query(`INSERT INTO orders (order_no,user_id,product_id,offer_id,category,product_name,offer_label,months,list_price_halalas,amount_due_halalas,status,contact_name,contact_phone,idempotency_key,paid_at,sub_start_at,sub_end_at)
    VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'completed','متدرب','+966512345678',$8,now(), now() - interval '100 days', now() - interval '10 days')`, [no4, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas, `k-${no4}`]);
  assert.deepEqual((await j(await call(`/api/mobile/v1/orders/${no4}`))).end_of_program, { survey_done: false });
  assert.equal((await send2("submit-exit-survey", { order_no: no4, wants_renewal: "yes", reason: "النتائج", experience: "ممتازة" })).status, 200);
  assert.deepEqual((await j(await call(`/api/mobile/v1/orders/${no4}`))).end_of_program, { survey_done: true });

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
  assert.equal((await db.query(`SELECT count(*)::int n FROM orders WHERE order_no = ANY($1)`, [[no, no2, no4]])).rows[0].n, 0);
  const log = (await db.query(`SELECT details FROM admin_log WHERE action='member.self_delete' AND target=$1`, [email])).rows[0];
  assert.ok([no, no2, no4].every((x) => log.details.orders.includes(x)));
  assert.equal((await call("/api/mobile/v1/me")).status, 401, "session gone");

  // المدربة لا تحذف نفسها
});

test("التطبيق: الخدمات الإضافية (راجعي جدولي، تصحيح الأداء بالفيديو، وجباتي)", async ({}, info) => {
  test.skip(info.project.name !== "desktop", "اختبار واجهات فقط: مرة واحدة يكفي");
  const H = { "expo-origin": "navcoaching://", "x-forwarded-for": `10.9.${Date.now() % 250}.9` };
  async function login(email: string) {
    const hdr = { ...H, "content-type": "application/json" };
    await fetch(`${B}/api/auth/email-otp/send-verification-otp`, { method: "POST", headers: hdr, body: JSON.stringify({ email, type: "sign-in" }) });
    const otp = (await db.query("SELECT substring(body from 'رمز الدخول: ([0-9]{6})') AS o FROM dev_mailbox WHERE recipient=$1 ORDER BY id DESC LIMIT 1", [email])).rows[0].o;
    const r = await fetch(`${B}/api/auth/sign-in/email-otp`, { method: "POST", headers: hdr, body: JSON.stringify({ email, otp }) });
    return r.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
  }
  const tag = Date.now();
  // منتجات الخدمات (كما تنشئها المدربة من لوحة الإدارة)
  for (const [kind, price] of [["program_review", 7900], ["form_check", 2900], ["meal_library", 4900]] as const) {
    await db.query(`UPDATE products SET app_addon = NULL WHERE app_addon = $1`, [kind]);
    const { rows: [p] } = await db.query(
      `INSERT INTO products (slug, category, name, audience, items, status, app_addon) VALUES ($1,'consult',$2,'وصف','[]','published',$3) RETURNING id`,
      [`addon-${kind.replace("_", "-")}-${tag}`, `خدمة ${kind}`, kind]);
    await db.query(`INSERT INTO product_offers (product_id, sku, label, months, price_halalas) VALUES ($1,$2,'مرة واحدة',0,$3)`, [p.id, `${kind.replace("_", "")}${tag}`.slice(0, 40), price]);
  }
  const list = (await (await fetch(`${B}/api/mobile/v1/addons`)).json()).addons;
  const sku = (k: string) => list.find((a: { kind: string }) => a.kind === k).sku;
  assert.equal(list.length, 3);
  assert.ok(list.find((a: { kind: string; price: string }) => a.kind === "form_check").price.includes("29"));

  const email = `addon-${tag}@e2e.test`;
  const cookie = await login(email);
  const post = (fd: FormData, c = cookie) => fetch(`${B}/api/mobile/v1/addons`, { method: "POST", headers: { ...H, Cookie: c }, body: fd });
  const base = (k: string) => { const f = new FormData(); f.set("sku", sku(k)); f.set("idempotency_key", `idem-${k}-${tag}-xxxxxxxx`); f.set("cc", "+966"); f.set("phone", "0512345678"); return f; };

  // راجعي جدولي: بدون برنامج مرفوض، ومع البرنامج ينشئ طلباً ينتظر التحويل
  assert.equal((await post(base("program_review"))).status, 422);
  const pr = base("program_review");
  pr.set("payload", JSON.stringify({ program: { name: "برنامجي", days: [{ title: "اليوم 1", items: [{ name: "Back Squat", sets: 3, reps: "8-12", target_weight: 60 }] }] }, sessions: [] }));
  pr.set("note", "أبي أركز على الأرجل");
  const prr = await post(pr);
  const prj = await prr.json();
  assert.equal(prr.status, 200, JSON.stringify(prj));
  const { rows: [o1] } = await db.query(`SELECT o.id, o.status, a.kind, a.payload, a.note FROM orders o JOIN addon_requests a ON a.order_id = o.id WHERE o.order_no = $1`, [prj.orderNo]);
  assert.equal(o1.status, "awaiting_payment");
  assert.equal(o1.kind, "program_review");
  assert.equal(o1.payload.program.name, "برنامجي");
  // نفس الطلب مرتين (نفس مفتاح التكرار) لا ينشئ طلباً ثانياً
  assert.equal((await (await post(pr)).json()).orderNo, prj.orderNo);

  // تصحيح الأداء: فيديو MP4 (يُتحقق من محتواه لا من امتداده)، ونص بامتداد mp4 مرفوض
  const mp4 = Buffer.concat([Buffer.from("000000186674797069736f6d0000020069736f6d69736f32", "hex"), Buffer.alloc(2048)]);
  const fc = base("form_check"); fc.set("payload", JSON.stringify({ exercise: "Back Squat" }));
  fc.set("video", new Blob([mp4], { type: "video/mp4" }), "form.mp4");
  const fcr = await post(fc); const fcj = await fcr.json();
  assert.equal(fcr.status, 200, JSON.stringify(fcj));
  const fake = base("form_check"); fake.set("idempotency_key", `idem-fake-${tag}-xxxxxxxxxx`);
  fake.set("video", new Blob([Buffer.from("not a video")], { type: "video/mp4" }), "x.mp4");
  assert.equal((await post(fake)).status, 422);
  const { rows: [o2] } = await db.query(`SELECT o.id FROM orders o WHERE o.order_no = $1`, [fcj.orderNo]);
  const v = await fetch(`${B}/api/files/addon/${o2.id}`, { headers: { Cookie: cookie } });
  assert.equal(v.status, 200);
  assert.equal(v.headers.get("content-type"), "video/mp4");
  const other = await login(`addon-other-${tag}@e2e.test`);
  assert.equal((await fetch(`${B}/api/files/addon/${o2.id}`, { headers: { Cookie: other } })).status, 404, "فيديو متدرب آخر");

  // وجباتي: خدمات المراجعة لا تفتحها حتى بعد التسليم، واشتراك «وجباتي» يفتحها
  const meals = async () => (await (await fetch(`${B}/api/mobile/v1/meals`, { headers: { ...H, Cookie: cookie } })).json()).access;
  await db.query(`UPDATE orders SET status = 'delivered' WHERE order_no = ANY($1)`, [[prj.orderNo, fcj.orderNo]]);
  assert.equal(await meals(), false);
  const ml = await (await post(base("meal_library"))).json();
  assert.ok(ml.orderNo);
  await db.query(`UPDATE orders SET status = 'active' WHERE order_no = $1`, [ml.orderNo]);
  assert.equal(await meals(), true);

  // بدون دخول
  assert.equal((await post(base("form_check"), "")).status, 401);
  await db.query(`UPDATE products SET status = 'archived' WHERE slug LIKE $1`, [`addon-%-${tag}`]);
});

test("التطبيق: محتوى الموقع العام والجداول المجانية", async ({}, info) => {
  test.skip(info.project.name !== "desktop", "اختبار واجهات فقط: مرة واحدة يكفي");
  // جدول مجاني منشور بملف PDF حقيقي في التخزين المحلي لبيئة الاختبار
  const tag = Date.now();
  const key = `free-plans/e2e-${tag}.pdf`;
  const { mkdirSync, writeFileSync } = await import("node:fs");
  mkdirSync(".data/e2e-uploads/free-plans", { recursive: true });
  writeFileSync(`.data/e2e-uploads/${key}`, Buffer.from("%PDF-1.4\n%e2e\n"));
  await db.query(`INSERT INTO free_plans (slug, title, summary, status, file_key, file_mime, sort) VALUES ($1, 'جدول اختبار', 'جدول تجريبي لاختبار التطبيق', 'published', $2, 'application/pdf', -1)`, [`e2e-plan-${tag}`, key]);
  const c = await (await fetch(`${B}/api/mobile/v1/content`)).json();
  assert.ok(c.products.length > 0, "البرامج المنشورة");
  assert.ok(c.products.every((p: { offers: unknown[] }) => Array.isArray(p.offers)));
  assert.equal(c.bank, undefined, "بيانات البنك لا تُرسل في المحتوى العام");
  assert.equal(c.analytics, undefined);
  assert.ok(c.about.name && Array.isArray(c.faqs) && Array.isArray(c.policies) && Array.isArray(c.reviews));
  assert.equal((await fetch(`${B}/api/mobile/v1/library`)).status, 401);

  const H = { "expo-origin": "navcoaching://", "x-forwarded-for": `10.9.${Date.now() % 250}.11` };
  const email = `freeplan-${Date.now()}@e2e.test`;
  const hdr = { ...H, "content-type": "application/json" };
  await fetch(`${B}/api/auth/email-otp/send-verification-otp`, { method: "POST", headers: hdr, body: JSON.stringify({ email, type: "sign-in" }) });
  const otp = (await db.query("SELECT substring(body from 'رمز الدخول: ([0-9]{6})') AS o FROM dev_mailbox WHERE recipient=$1 ORDER BY id DESC LIMIT 1", [email])).rows[0].o;
  const r = await fetch(`${B}/api/auth/sign-in/email-otp`, { method: "POST", headers: hdr, body: JSON.stringify({ email, otp }) });
  const cookie = r.headers.getSetCookie().map((x) => x.split(";")[0]).join("; ");
  const lib0 = await (await fetch(`${B}/api/mobile/v1/library`, { headers: { Cookie: cookie } })).json();
  assert.deepEqual(lib0.free_plans, []);
  assert.equal(c.free_plans[0].slug, `e2e-plan-${tag}`);
  {
    const fd = new FormData(); fd.set("slug", c.free_plans[0].slug);
    assert.equal((await fetch(`${B}/api/mobile/v1/actions/request-free-plan`, { method: "POST", headers: { Cookie: cookie }, body: fd })).status, 200);
    const lib1 = await (await fetch(`${B}/api/mobile/v1/library`, { headers: { Cookie: cookie } })).json();
    assert.equal(lib1.free_plans.length, 1);
    // التحميل: ملف PDF إذا كان مرفوعاً، وإلا تحويل (التطبيق يعتبر التحويل فشلاً ولا يحفظ صفحة HTML)
    const dl = await fetch(`${B}${lib1.free_plans[0].url}`, { headers: { Cookie: cookie }, redirect: "manual" });
    assert.equal(lib1.free_plans[0].has_file, true);
    assert.equal(dl.status, 200);
    assert.equal(dl.headers.get("content-type"), "application/pdf");
    // مستخدم آخر لا يقدر يحمّل طلب غيره
    assert.equal((await fetch(`${B}${lib1.free_plans[0].url}`, { redirect: "manual" })).status, 303);
  }
  await db.query(`UPDATE free_plans SET status = 'hidden' WHERE slug = $1`, [`e2e-plan-${tag}`]);
});

test("التطبيق: «ناف برو» بدائل الكوتش للمشترك فقط", async ({}, info) => {
  test.skip(info.project.name !== "desktop", "اختبار واجهات فقط: مرة واحدة يكفي");
  const H = { "expo-origin": "navcoaching://", "x-forwarded-for": `10.8.${Date.now() % 250}.8` };
  const email = `pro-${Date.now()}@example.com`;
  const hdr = { ...H, "content-type": "application/json" };
  await fetch(`${B}/api/auth/email-otp/send-verification-otp`, { method: "POST", headers: hdr, body: JSON.stringify({ email, type: "sign-in" }) });
  const otp = (await db.query("SELECT substring(body from 'رمز الدخول: ([0-9]{6})') AS o FROM dev_mailbox WHERE recipient=$1 ORDER BY id DESC LIMIT 1", [email])).rows[0].o;
  const r = await fetch(`${B}/api/auth/sign-in/email-otp`, { method: "POST", headers: hdr, body: JSON.stringify({ email, otp }) });
  const cookie = r.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
  const alts = async () => (await fetch(`${B}/api/mobile/v1/coach-alts`, { headers: { ...H, Cookie: cookie } })).json();

  assert.equal((await fetch(`${B}/api/mobile/v1/coach-alts`, { headers: H })).status, 401);
  // بدائل تحددها المدربة من لوحة الإدارة
  const { rows: [sq] } = await db.query(`SELECT id FROM exercises WHERE name='Back Squat'`);
  const { rows: [fs] } = await db.query(`SELECT id FROM exercises WHERE name='Front Squat'`);
  await db.query(`INSERT INTO exercise_alternatives (exercise_id, alt_id, position) VALUES ($1,$2,-1) ON CONFLICT DO NOTHING`, [sq.id, fs.id]);

  // مستخدم مجاني: لا بيانات
  assert.deepEqual(await alts(), { pro: false, alts: {} });

  // اشتراك متابعة جارٍ: مفعّل
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email=$1`, [email]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id=p.id WHERE p.slug='intensive' AND o.months=3`);
  const no = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no;
  await db.query(`INSERT INTO orders (order_no,user_id,product_id,offer_id,category,product_name,offer_label,months,list_price_halalas,amount_due_halalas,status,contact_name,contact_phone,idempotency_key,paid_at)
    VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active','متدرب','+966512345678',$8,now())`, [no, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas, `k-${no}`]);
  const on = await alts();
  assert.equal(on.pro, true);
  assert.ok(on.alts["back-squat"].includes("front-squat"));

  // انتهى الاشتراك: يتوقف
  await db.query(`UPDATE orders SET status = 'completed' WHERE order_no = $1`, [no]);
  assert.equal((await alts()).pro, false);
  await db.query(`DELETE FROM orders WHERE order_no = $1`, [no]);
});

test("التطبيق: طلب الباقة بالاستبيان كاملاً", async ({}, info) => {
  test.skip(info.project.name !== "desktop", "اختبار واجهات فقط: مرة واحدة يكفي");
  const H = { "expo-origin": "navcoaching://", "x-forwarded-for": `10.7.${Date.now() % 250}.7` };
  const email = `co-${Date.now()}@example.com`;
  const hdr = { ...H, "content-type": "application/json" };
  await fetch(`${B}/api/auth/email-otp/send-verification-otp`, { method: "POST", headers: hdr, body: JSON.stringify({ email, type: "sign-in" }) });
  const otp = (await db.query("SELECT substring(body from 'رمز الدخول: ([0-9]{6})') AS o FROM dev_mailbox WHERE recipient=$1 ORDER BY id DESC LIMIT 1", [email])).rows[0].o;
  const r = await fetch(`${B}/api/auth/sign-in/email-otp`, { method: "POST", headers: hdr, body: JSON.stringify({ email, otp }) });
  const cookie = r.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
  const { rows: [o] } = await db.query(`SELECT o.sku, o.price_halalas FROM products p JOIN product_offers o ON o.product_id=p.id WHERE p.slug='intensive' AND o.months=3`);

  assert.equal((await fetch(`${B}/api/mobile/v1/checkout?sku=${o.sku}`, { headers: H })).status, 401);
  assert.equal((await fetch(`${B}/api/mobile/v1/checkout?sku=nope`, { headers: { ...H, Cookie: cookie } })).status, 404);
  const c = await (await fetch(`${B}/api/mobile/v1/checkout?sku=${o.sku}`, { headers: { ...H, Cookie: cookie } })).json();
  assert.equal(c.sku, o.sku);
  assert.ok(c.offers.some((x: { sku: string; price_halalas: number }) => x.sku === o.sku && x.price_halalas === o.price_halalas));
  assert.ok(c.opt.goal.length > 0 && c.questions.goal.label && c.startRange.min);

  const send = (fields: Record<string, string | string[]>) => {
    const fd = new FormData();
    for (const [k, v] of Object.entries(fields)) for (const x of [v].flat()) fd.append(k, x);
    return fetch(`${B}/api/mobile/v1/actions/create-order`, { method: "POST", headers: { ...H, Cookie: cookie }, body: fd });
  };
  const key = `app-${Date.now()}-idempotency`;
  const full = {
    idempotency_key: key, sku: o.sku, name: "متدربة التطبيق", cc: "+966", phone: "512345678", gender: "أنثى", age: "28",
    goal: c.opt.goal[0], level: c.opt.level[0], place: "البيت", equip: [c.opt.equip[0], c.opt.equip[1]], days: c.opt.days[1], duration: c.opt.duration[1],
    injury: "لا", condition: "لا", health_ack: "on", weight: "70.5", height: "165", calories: c.opt.calories[0],
    expectations: "متابعة أسبوعية", media: c.opt.media[2], start_mode: "date", start_date: c.startRange.min,
    consent_terms: "on", consent_wa: "on",
  };
  // أخطاء الحقول ترجع بأسمائها
  const bad = await send({ ...full, phone: "123", weight: "10" });
  assert.equal(bad.status, 422);
  const bj = await bad.json();
  assert.ok(bj.fieldErrors.phone && bj.fieldErrors.weight);

  const ok = await (await send(full)).json();
  assert.ok(ok.ok && ok.message);
  // نفس المفتاح لا ينشئ طلباً ثانياً
  const again = await (await send(full)).json();
  assert.equal(again.message, ok.message);
  const { rows: [row] } = await db.query(
    `SELECT o.status, o.amount_due_halalas, o.preferred_start::text, i.answers, i.health FROM orders o JOIN intakes i ON i.order_id = o.id WHERE o.order_no = $1`, [ok.message]);
  assert.equal(row.status, "awaiting_payment");
  assert.equal(row.amount_due_halalas, o.price_halalas);
  assert.equal(row.preferred_start, c.startRange.min);
  assert.deepEqual(row.answers.equip, [c.opt.equip[0], c.opt.equip[1]]);
  assert.equal(Number(row.health.weight), 70.5);
  // صفحة الطلب في التطبيق تعرض بيانات التحويل
  const det = await (await fetch(`${B}/api/mobile/v1/orders`, { headers: { ...H, Cookie: cookie } })).json();
  assert.ok(JSON.stringify(det).includes(ok.message));
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE order_no = $1`, [ok.message]);
});

test("التطبيق: مفتاح إيقاف الطلب من التطبيق", async ({}, info) => {
  test.skip(info.project.name !== "desktop", "اختبار واجهات فقط: مرة واحدة يكفي");
  const H = { "expo-origin": "navcoaching://", "x-forwarded-for": `10.6.${Date.now() % 250}.6` };
  const email = `off-${Date.now()}@example.com`;
  const hdr = { ...H, "content-type": "application/json" };
  await fetch(`${B}/api/auth/email-otp/send-verification-otp`, { method: "POST", headers: hdr, body: JSON.stringify({ email, type: "sign-in" }) });
  const otp = (await db.query("SELECT substring(body from 'رمز الدخول: ([0-9]{6})') AS o FROM dev_mailbox WHERE recipient=$1 ORDER BY id DESC LIMIT 1", [email])).rows[0].o;
  const r = await fetch(`${B}/api/auth/sign-in/email-otp`, { method: "POST", headers: hdr, body: JSON.stringify({ email, otp }) });
  const cookie = r.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
  const { rows: [o] } = await db.query(`SELECT o.sku FROM products p JOIN product_offers o ON o.product_id=p.id WHERE p.slug='intensive' AND o.months=3`);
  const content = async () => (await (await fetch(`${B}/api/mobile/v1/content`, { headers: H })).json()).ordering;
  const auth = { headers: { ...H, Cookie: cookie } };

  assert.equal(await content(), true);
  await db.query(`INSERT INTO site_settings (key, value) VALUES ('app_ordering', '{"enabled": false}') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`);
  try {
    assert.equal(await content(), false);
    assert.equal((await fetch(`${B}/api/mobile/v1/checkout?sku=${o.sku}`, auth)).status, 403);
    const fd = new FormData(); fd.append("sku", o.sku);
    const co = await fetch(`${B}/api/mobile/v1/actions/create-order`, { method: "POST", body: fd, ...auth });
    assert.equal((await co.json()).error, "الطلب من التطبيق متوقف حالياً.");
    assert.deepEqual((await (await fetch(`${B}/api/mobile/v1/addons`, { headers: H })).json()).addons, []);
    assert.equal((await fetch(`${B}/api/mobile/v1/addons`, { method: "POST", body: new FormData(), ...auth })).status, 403);
    // الموقع لا يتأثر
    assert.equal((await fetch(`${B}/checkout/${o.sku}`, { headers: { Cookie: cookie }, redirect: "manual" })).status, 200);
  } finally {
    await db.query(`DELETE FROM site_settings WHERE key = 'app_ordering'`);
  }
  assert.equal(await content(), true);
});
