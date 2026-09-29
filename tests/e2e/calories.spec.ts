// السعرات المقترحة (المتدرب يحدّث بياناته ← اقتراح للمدربة ← تجاهل/اعتماد) + الإيميل اليومي للمدربة. قاعدة nav_e2e.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";
import { profileFromIntake, targetKcal } from "../../src/lib/calorie-suggest.ts";
import { macrosFor } from "../../src/lib/calories.ts";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const CRON_SECRET = "e2e-cron-secret-0123456789";
const COACH_MAIL = "coach-notify@e2e.test";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 240;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.15.${tag.length}.${ip++}` } });
  return ctx.newPage();
}
async function latestOtp(email: string) {
  for (let i = 0; i < 20; i++) {
    const { rows } = await db.query("SELECT body FROM dev_mailbox WHERE recipient = $1 AND subject LIKE 'رمز الدخول%' ORDER BY id DESC LIMIT 1", [email]);
    const m = rows[0]?.body.match(/رمز الدخول: (\d{6})/);
    if (m) return m[1];
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error("OTP not found");
}
async function login(page: Page, email: string, next = "/account") {
  await page.goto(`/login?next=${encodeURIComponent(next)}`);
  await page.getByLabel("البريد الإلكتروني").fill(email);
  await page.getByRole("button", { name: "أرسل رمز الدخول" }).click();
  await page.getByLabel("رمز الدخول").fill(await latestOtp(email));
  await page.getByRole("button", { name: "دخول" }).click();
  await page.waitForURL((u) => !u.pathname.startsWith("/login"));
}
async function noHorizontalScroll(page: Page) {
  const [sw, iw] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  expect(sw, `horizontal overflow on ${page.url()}`).toBeLessThanOrEqual(iw);
}

test("السعرات المقترحة: المتدرب يحدّث نشاطه، والمدربة تتجاهل ثم تعتمد، والإيميل اليومي", async ({ browser }, info) => {
  const project = info.project.name;
  const email = `trainee-cal-${project}@e2e.test`;
  const name = `هند سعرات ${project}`;
  const trainee = await newPage(browser, project);
  await login(trainee, email);

  // اشتراك نشط بدأ قبل 7 أيام، ومراجعته تبدأ اليوم، واستبيان: أنثى 30 سنة 165 سم، 4 أيام × ساعة، 3,000–6,000 خطوة، نزول دهون
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  const riyadhToday = `(now() AT TIME ZONE 'Asia/Riyadh')::date`;
  const { rows: [o] } = await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status,
                         contact_name, contact_phone, idempotency_key, paid_at, sub_start_at, sub_end_at, review_weekday)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active',$8,'+966500000000',$1, now(),
             (${riyadhToday} - 7)::timestamp AT TIME ZONE 'Asia/Riyadh' + interval '10 hours', now() + interval '80 days',
             extract(dow FROM ${riyadhToday})::int) RETURNING id`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas, name]);
  await db.query(
    `INSERT INTO intakes (order_id, user_id, answers, health, media_consent, consent_terms_at, consent_whatsapp_at)
     VALUES ($1,$2,$3,$4,'لا',now(),now())`,
    [o.id, u.id, JSON.stringify({ gender: "أنثى", age: 30, days: "4 أيام", duration: "ساعة", steps: "3,000 – 6,000", goal: "نزول دهون" }), JSON.stringify({ weight: 74, height: 165 })]);
  await db.query(`INSERT INTO nutrition_targets (order_id, kcal, protein, carbs, fat) VALUES ($1, 2100, 125, 250, 62)`, [o.id]);
  await db.query(`INSERT INTO weight_logs (user_id, logged_on, kg) VALUES ($1, ${riyadhToday}, 70)`, [u.id]);

  // المتدرب: «حدّث بياناتك» — نشاط أقل
  await trainee.goto(`/account/orders/${orderNo}/progress`);
  const form = trainee.getByTestId("body-info-form");
  await expect(form.getByLabel("الطول (سم)")).toHaveValue("165");
  await form.getByLabel("نشاطك اليومي خارج التمرين").selectOption("1.0");
  await form.getByRole("button", { name: "حفظ بياناتي" }).click();
  await expect(form).toContainText("المدربة تراجع");
  const { rows: [prof] } = await db.query(`SELECT sex, age, paf::float, training_days, minutes, eb_factor::float FROM calorie_profiles WHERE order_id = $1`, [o.id]);
  expect(prof).toEqual({ sex: "female", age: 30, paf: 1, training_days: 4, minutes: 60, eb_factor: 0.8 });
  await noHorizontalScroll(trainee);
  // المتدرب لا يرى الرقم المقترح
  await trainee.goto(`/account/orders/${orderNo}/nutrition`);
  await expect(trainee.locator("body")).not.toContainText("1,755");

  // المدربة: الاقتراح في لوحة الإدارة وصفحة التغذية
  const coachEmail = `coach-cal-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto("/admin");
  await expect(coach.locator("li", { hasText: name }).filter({ hasText: "سعرات مقترحة جديدة: 1,755" })).toBeVisible();
  await coach.goto(`/admin/orders/${orderNo}/nutrition`);
  const card = coach.getByTestId("calorie-suggest");
  // Ten Haaf: 70 كغ، 165 سم، 30 سنة، نشاط 1.0، 4 أيام × 60 دقيقة، عجز 20% → 1755
  await expect(card.getByTestId("suggestion")).toContainText("مقترح: 1,755 سعرة بدل 2,100 (-345)");
  await expect(card.getByTestId("suggestion")).toContainText("كارب 174غ"); // (1755 − 125×4 − 62×9) ÷ 4
  await noHorizontalScroll(coach);

  // تجاهل: يختفي ولا يتكرر نفس الرقم
  await card.getByRole("button", { name: "تجاهل" }).click();
  await expect(card.getByTestId("no-suggestion")).toBeVisible();
  expect((await db.query(`SELECT dismissed_kcal FROM calorie_profiles WHERE order_id = $1`, [o.id])).rows[0].dismissed_kcal).toBe(1755);

  // المدربة تعدّل البيانات (5 أيام تمرين) → اقتراح جديد → اعتماد
  await card.locator("details summary").click();
  await card.getByLabel("أيام التمرين").fill("5");
  await card.getByRole("button", { name: "حفظ البيانات" }).click();
  await expect(card.getByText("تم حفظ بيانات الحساب")).toBeVisible();
  await coach.reload();
  await expect(coach.getByTestId("suggestion")).toContainText("مقترح: 1,815 سعرة");
  coach.once("dialog", (d) => d.accept());
  await coach.getByTestId("calorie-suggest").getByRole("button", { name: "اعتماد" }).click();
  // بعد الاعتماد يصير الهدف = المقترح، فيختفي الاقتراح
  await expect(coach.getByTestId("no-suggestion")).toBeVisible();
  await expect(coach.getByTestId("targets").getByLabel("السعرات")).toHaveValue("1815");
  const { rows: [t] } = await db.query(`SELECT kcal, protein::float, carbs::float, fat::float FROM nutrition_targets WHERE order_id = $1`, [o.id]);
  expect(t).toEqual({ kcal: 1815, protein: 125, carbs: 189, fat: 62 }); // (1815 − 500 − 558) ÷ 4 = 189.25
  await trainee.goto(`/account/orders/${orderNo}/nutrition`);
  await expect(trainee.getByTestId("macro-summary")).toContainText("1,815");

  // الإيميل اليومي: مرة واحدة فقط، وفيه اسم المتدرب (مراجعته تبدأ اليوم)
  await db.query(`DELETE FROM coach_digests WHERE day = ${riyadhToday}`);
  const before = (await db.query(`SELECT max(id) AS id FROM dev_mailbox`)).rows[0].id ?? 0;
  const run = () => coach.request.post("/api/cron/reminders", { headers: { "x-cron-secret": CRON_SECRET }, data: { ignore_quiet_hours: true } });
  expect((await run()).status()).toBe(200);
  const mails = async () => (await db.query(
    `SELECT subject, body FROM dev_mailbox WHERE id > $1 AND recipient = $2 AND subject LIKE 'مراجعات اليوم%'`, [before, COACH_MAIL])).rows;
  const got = await mails();
  expect(got.length).toBe(1);
  expect(got[0].body).toContain("مراجعات تبدأ اليوم");
  expect(got[0].body).toContain(name);
  expect(got[0].body).toContain(`/admin/orders/${orderNo}`);
  expect((await run()).status()).toBe(200);
  expect((await mails()).length).toBe(1);
});

test("السعرات التلقائية: تنحسب لمتدرب جديد بشارة «بانتظار تأكيدك»، وتُقترح الجداول القريبة", async ({ browser }, info) => {
  const project = info.project.name;
  const email = `trainee-auto-${project}@e2e.test`;
  const name = `ريم تلقائي ${project}`;
  const trainee = await newPage(browser, project + "-a");
  await login(trainee, email);
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  // نشط، بدون هدف سعرات. أنثى 30 سنة 165 سم 74 كغ، 4 أيام × ساعة، 3,000–6,000 خطوة، نزول دهون
  const { rows: [o] } = await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status,
                         contact_name, contact_phone, idempotency_key, paid_at, sub_start_at, sub_end_at)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active',$8,'+966500000000',$1, now(), now(), now() + interval '80 days') RETURNING id`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas, name]);
  await db.query(
    `INSERT INTO intakes (order_id, user_id, answers, health, media_consent, consent_terms_at, consent_whatsapp_at)
     VALUES ($1,$2,$3,$4,'لا',now(),now())`,
    [o.id, u.id, JSON.stringify({ gender: "أنثى", age: 30, days: "4 أيام", duration: "ساعة", steps: "3,000 – 6,000", goal: "نزول دهون" }), JSON.stringify({ weight: 74, height: 165 })]);
  const expected = targetKcal(profileFromIntake({ gender: "أنثى", age: 30, days: "4 أيام", duration: "ساعة", steps: "3,000 – 6,000", goal: "نزول دهون" }, { weight: 74, height: 165 }), 74)!;
  const fmt = expected.toLocaleString("en-US");

  // قوالب: +80 (قريب جداً)، −150 (مقترح)، +300 (لا يظهر)
  const tpl = async (label: string, kcal: number) => {
    const { rows: [pl] } = await db.query(`INSERT INTO nutrition_plans (name) VALUES ($1) RETURNING id`, [`${label} ${project}`]);
    const { rows: [m] } = await db.query(`INSERT INTO plan_meals (plan_id, kind, title) VALUES ($1,'lunch','غداء') RETURNING id`, [pl.id]);
    const c = Math.round(kcal / 8 * 10) / 10;
    await db.query(`INSERT INTO plan_items (meal_id, food, carbs) VALUES ($1,'أ',$2), ($1,'ب',$2)`, [m.id, c]);
    return `${label} ${project}`;
  };
  const near = await tpl("قالب قريب", expected + 80), mid = await tpl("قالب متوسط", expected - 150), far = await tpl("قالب بعيد", expected + 300);

  const coachEmail = `coach-auto-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-ac");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  // لوحة الإدارة تحسبها تلقائياً وتطلب التأكيد
  await coach.goto("/admin");
  await expect(coach.locator("li", { hasText: name }).filter({ hasText: `بانتظار تأكيدك: ${fmt}` })).toBeVisible();
  expect((await db.query(`SELECT kcal, kcal_source, kcal_confirmed_at, protein FROM nutrition_targets WHERE order_id = $1`, [o.id])).rows[0])
    .toEqual({ kcal: expected, kcal_source: "auto", kcal_confirmed_at: null, protein: null });

  await coach.goto(`/admin/orders/${orderNo}/nutrition`);
  const auto = coach.getByTestId("auto-kcal");
  await expect(auto.getByTestId("auto-badge")).toHaveText("⏳ بانتظار تأكيدك");
  await expect(auto).toContainText(`${fmt} سعرة`);
  for (const t of ["Ten Haaf", "74 كغ (من الاستبيان)", "165 سم", "4 أيام × 60 دقيقة"]) await expect(auto).toContainText(t);
  await expect(coach.getByTestId("targets").getByLabel("السعرات")).toHaveValue(String(expected));

  // الجداول المقترحة
  const list = coach.getByTestId("near-plans");
  await expect(list.getByTestId("near-plan").filter({ hasText: near })).toContainText("قريب جداً");
  await expect(list.getByTestId("near-plan").filter({ hasText: mid })).not.toContainText("قريب جداً");
  await expect(list).not.toContainText(far);
  await noHorizontalScroll(coach);

  // المتدرب ما يشوف السعرات قبل التأكيد
  await trainee.goto(`/account/orders/${orderNo}/nutrition`);
  await expect(trainee.locator("main")).not.toContainText(fmt);

  // تأكيد الحسبة
  await auto.getByRole("button", { name: "أكدت الحسبة" }).click();
  await coach.reload();
  await expect(coach.getByTestId("auto-kcal")).toHaveCount(0);
  await trainee.reload();
  await expect(trainee.getByTestId("macro-summary")).toContainText(fmt);
  const { rows: [t] } = await db.query(`SELECT kcal, kcal_source, kcal_confirmed_at IS NOT NULL AS ok FROM nutrition_targets WHERE order_id = $1`, [o.id]);
  expect(t).toEqual({ kcal: expected, kcal_source: "coach", ok: true });

  // الماكروز المقترحة بمستويين (معتدل 1.6 وعالي 2.2 غ/كغ) وتعبئتها بضغطة بالمستوى العالي
  const mm = macrosFor(expected, 74, { proteinPerKg: 1.6, fatPerKg: 0.8 }), mk = macrosFor(expected, 74, { proteinPerKg: 2.2, fatPerKg: 0.8 });
  const ms = coach.getByTestId("macro-suggest");
  await expect(ms.getByTestId("macro-moderate")).toContainText(`بروتين ${mm.protein}غ`);
  await expect(ms.getByTestId("macro-high")).toContainText(`بروتين ${mk.protein}غ`);
  await expect(ms.getByTestId("macro-high")).toContainText(`كارب ${mk.carbs}غ`);
  await ms.getByLabel("مستوى البروتين").selectOption("high");
  await ms.getByRole("button", { name: "تعبئة الماكروز" }).click();
  // ننتظر حفظ الإجراء قبل التحديث (وإلا قد يسبق التحديثُ الحفظَ)
  await expect.poll(async () => (await db.query(`SELECT protein::float AS p FROM nutrition_targets WHERE order_id = $1`, [o.id])).rows[0].p).toBe(mk.protein);
  await coach.reload();
  await expect(coach.getByTestId("targets").getByLabel("البروتين (غ)")).toHaveValue(String(mk.protein));
  await expect(coach.getByTestId("targets").getByLabel("الكارب (غ)")).toHaveValue(String(mk.carbs));
  expect((await db.query(`SELECT protein::float, carbs::float, fat::float FROM nutrition_targets WHERE order_id = $1`, [o.id])).rows[0])
    .toEqual({ protein: mk.protein, carbs: mk.carbs, fat: mk.fat });
  await expect(coach.getByTestId("macro-suggest").getByRole("button", { name: "تعبئة الماكروز" })).toHaveCount(0);

  // إضافة القالب المقترح بضغطة
  await list.getByTestId("near-plan").filter({ hasText: near }).getByRole("button", { name: "إضافة للمتدرب" }).click();
  await expect(coach.getByTestId("trainee-plans").locator("table")).toContainText(near);
  await expect(list.getByTestId("near-plan").filter({ hasText: near })).toContainText("✓ مضاف له");
});
