// دليل مصادر الأكل: التصنيف حسب نوع المصدر والقيمة الغذائية (قاعدة nav_e2e)، والقالب عالي الألياف.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 60;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.16.${tag.length}.${ip++}` } });
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

test("دليل مصادر الأكل: المتدرب يصفّي بالنوع والقيمة ويشوف التفاصيل، وغير المشترك ما يشوف شي", async ({ browser }, info) => {
  const project = info.project.name;
  const email = `trainee-guide-${project}@e2e.test`;
  const page = await newPage(browser, project);
  await login(page, email);
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  const base = `/account/orders/${orderNo}/nutrition/foods`;

  // قبل الدفع: الدليل فاضي (RLS)
  await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status,
                         contact_name, contact_phone, idempotency_key)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'awaiting_payment','متدرب دليل','+966500000000',$1)`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas]);
  await page.goto(base);
  await expect(page.getByText("الدليل يظهر بعد تأكيد اشتراكك.")).toBeVisible();

  await db.query(`UPDATE orders SET status = 'active', paid_at = now(), sub_start_at = now(), sub_end_at = now() + interval '80 days' WHERE order_no = $1`, [orderNo]);
  await page.goto(base);
  const guide = page.getByTestId("food-guide");
  await expect(guide.getByRole("heading", { name: /لحوم حمراء/ })).toBeVisible();
  await expect(guide.getByRole("heading", { name: /لحوم بيضاء \(دواجن\)/ })).toBeVisible();
  await expect(guide.getByRole("heading", { name: /بقوليات/ })).toBeVisible();

  // نوع المصدر: بقوليات فقط
  await page.getByLabel("نوع المصدر").selectOption("بقوليات");
  await page.getByRole("button", { name: "عرض" }).click();
  await expect(page).toHaveURL(/type=/);
  await expect(guide.getByTestId("guide-food")).toHaveCount(5);
  await expect(guide.getByTestId("guide-food").filter({ hasText: "عدس مطبوخ" })).toContainText("غني بالألياف");

  // التفاصيل: الألياف والفولات للحصة
  const lentil = guide.getByTestId("guide-food").filter({ hasText: "عدس مطبوخ" });
  await lentil.locator("summary").click();
  await expect(lentil.locator(".food-rows")).toContainText("الألياف");
  await expect(lentil.locator(".food-rows")).toContainText("الفولات (B9)");

  // القيمة: عالي الألياف (اختصار) مع مسح النوع
  await page.getByRole("link", { name: "مسح التصفية" }).click();
  await page.getByRole("link", { name: "عالي الألياف" }).click();
  await expect(page).toHaveURL(/tag=fiber/);
  await expect(guide.getByTestId("guide-food").filter({ hasText: "حمص مطبوخ" })).toHaveCount(1);
  await expect(guide.getByTestId("guide-food").filter({ hasText: "صدر دجاج مشوي" })).toHaveCount(0);

  // فيتامين C
  await page.goto(`${base}?tag=vit_c`);
  await expect(guide.getByTestId("guide-food").filter({ hasText: "فلفل رومي أحمر" })).toContainText("غني بفيتامين C");
  await noHorizontalScroll(page);

  // مستخدم آخر ما يفتح صفحة طلب غيره
  const other = await newPage(browser, project + "-o");
  await login(other, `other-guide-${project}@e2e.test`);
  expect((await other.goto(base))?.status()).toBe(404);
});

test("كل الوجبات: المتدرب يضيف أي وجبة من قوالب التغذية لأكله اليومي (مو بس من جداوله)", async ({ browser }, info) => {
  const project = info.project.name;
  const email = `trainee-lib-${project}@e2e.test`;
  const page = await newPage(browser, project + "-l");
  await login(page, email);
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  const { rows: [o] } = await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status,
                         contact_name, contact_phone, idempotency_key, paid_at, sub_start_at, sub_end_at)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active','متدرب مكتبة','+966500000000',$1, now(), now(), now() + interval '80 days') RETURNING id`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas]);
  await db.query(`INSERT INTO nutrition_targets (order_id, kcal, protein, carbs, fat) VALUES ($1, 2000, 150, 200, 60)`, [o.id]); // بدون جداول مخصصة له
  // وجبة موجودة في المكتبة فقط (وصفة مضادات الأكسدة «حمص بالخضار الملوّنة» مو داخل أي قالب)
  const { rows: [tm] } = await db.query(
    `SELECT m.id, m.title FROM plan_meals m JOIN nutrition_plans pl ON pl.id = m.plan_id AND pl.is_library WHERE m.title = 'حمص بالخضار الملوّنة'`);
  expect(tm, "وصفة المكتبة غير موجودة بالبذور").toBeTruthy();

  await page.goto(`/account/orders/${orderNo}/nutrition`);
  await page.getByTestId("add-food-breakfast").click();
  const form = page.getByTestId("food-log-form");
  await expect(form.getByText("من جدولي")).toHaveCount(0); // ما عنده جداول
  await form.getByTestId("tab-meals").click();
  // قد تتكرر الوجبة بين القوالب فتظهر مرة وحدة: نبحث بالاسم
  await form.getByLabel("بحث في الوجبات").fill(tm.title);
  await form.getByRole("radio", { name: "الكل" }).check();
  await expect(form.getByText("طريقة التحضير")).toHaveCount(0);
  await expect(form.getByText("المكونات")).toHaveCount(0);
  await form.getByRole("button", { name: new RegExp(`إضافة ${tm.title}`) }).first().click();
  await expect(page.locator(".food-log-row", { hasText: tm.title })).toBeVisible();
  const { rows: [log] } = await db.query(`SELECT name, protein::float FROM food_logs WHERE order_id = $1`, [o.id]);
  expect(log.name).toBe(tm.title); // بدون اسم الجدول
  expect(log.protein).toBeCloseTo(6.2, 1);
  await page.reload();
  await expect(page.locator(".food-log-row", { hasText: tm.title })).toBeVisible();
  await noHorizontalScroll(page);

  // غير المشترك: ما عنده الخيار (الطلب غير مدفوع)
  await db.query(`UPDATE orders SET status = 'awaiting_payment' WHERE id = $1`, [o.id]);
  await page.goto(`/account/orders/${orderNo}/nutrition`);
  await expect(page.getByTestId("add-food-breakfast")).toHaveCount(0); // قبل الدفع لا يظهر التسجيل
});
