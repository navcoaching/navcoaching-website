// الباقة الأساسية: المراجعة كل أسبوعين — جدول المتدرب ومواعيده، وما تشوفه المدربة. + «حالة الإعداد» ظاهرة أعلى لوحة الإدارة.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 10;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.47.${tag.length}.${ip++}` } });
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
async function login(page: Page, email: string, next: string) {
  await page.goto(`/login?next=${encodeURIComponent(next)}`);
  await page.getByLabel("البريد الإلكتروني").fill(email);
  await page.getByRole("button", { name: "أرسل رمز الدخول" }).click();
  await page.getByLabel("رمز الدخول").fill(await latestOtp(email));
  await page.getByRole("button", { name: "دخول" }).click();
  await page.waitForURL((u) => !u.pathname.startsWith("/login"));
}
async function noHorizontalScroll(page: Page) {
  const [sw, iw] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  expect(sw).toBeLessThanOrEqual(iw);
}

test("الأساسية: المراجعة كل أسبوعين للمتدرب والمدربة", async ({ browser }, info) => {
  const p = info.project.name;
  const email = `basic-rev-${p}@e2e.test`, coachEmail = `coach-rev-${p}@e2e.test`;
  const trainee = await newPage(browser, p + "t");
  await login(trainee, email, "/account");
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [pr] } = await db.query(
    `SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'basic' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  // بدأ قبل 20 يوماً لمدة 90 يوماً، ويوم المراجعة نفس يوم البدء
  await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas,
                         status, contact_name, contact_phone, idempotency_key, paid_at, source, sub_start_at, sub_end_at, review_weekday)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active','منى','+966500000000',$1, now(), 'manual',
             now() - interval '20 days', now() + interval '70 days', extract(dow FROM (now() - interval '20 days') AT TIME ZONE 'Asia/Riyadh')::smallint)`,
    [orderNo, u.id, pr.id, pr.offer_id, pr.name, pr.label, pr.price_halalas]);
  expect((await db.query("SELECT review_every_weeks n FROM orders WHERE order_no = $1", [orderNo])).rows[0].n).toBe(2);

  await trainee.goto(`/account/orders/${orderNo}`);
  const history = trainee.getByTestId("review-history");
  await expect(history.getByRole("heading", { name: "سجل المراجعات (كل أسبوعين)" })).toBeVisible();
  // 90 يوماً: مواعيد عند 14، 28، 42، 56، 70، 84 يوماً = 6 مراجعات (الأسبوعية كانت 12)
  await expect(history.locator("ol.weeks > li")).toHaveCount(6);
  await expect(history.locator("ol.weeks > li").first()).toContainText("المراجعة 1");
  // أول موعد (قبل 6 أيام) فات، والأسبوع اللي بعده ما فيه موعد
  await expect(trainee.getByTestId("review-missed")).toContainText("المراجعة 1");
  await expect(trainee.getByRole("heading", { name: "المراجعة (كل أسبوعين)" })).toBeVisible();
  await expect(trainee.getByTestId("review-day")).toContainText("كل أسبوعين");
  await noHorizontalScroll(trainee);

  const coach = await newPage(browser, p + "c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto("/admin");
  // حالة الحماية ظاهرة أعلى الصفحة بدون تمرير، والرابط ينزل لـ«حالة الإعداد»
  const summary = coach.getByTestId("setup-summary");
  await expect(summary).toBeInViewport();
  await expect(summary).toContainText("حماية البيانات بين الحسابات");
  await summary.getByRole("link", { name: /حالة الإعداد/ }).click();
  await expect(coach.getByRole("heading", { name: "حالة الإعداد" })).toBeInViewport();
  await noHorizontalScroll(coach);

  await coach.goto(`/admin/orders/${orderNo}`);
  await expect(coach.getByTestId("subscription-card").getByTestId("review-day")).toContainText("كل أسبوعين");
  await expect(coach.getByRole("heading", { name: "المراجعات (كل أسبوعين)" })).toBeVisible();
  await noHorizontalScroll(coach);

  await coach.goto(`/admin/products/${pr.id}`);
  await expect(coach.locator("#review-every")).toHaveValue("2");
  await noHorizontalScroll(coach);
});
