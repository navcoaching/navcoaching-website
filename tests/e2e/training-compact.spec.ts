// صفحة التمرين للمتدرب: قائمة مختصرة، الأسبوع الحالي فقط، واليوم الافتراضي أول يوم لم يبدأ (قاعدة nav_e2e).
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 120;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.11.${tag.length}.${ip++}` } });
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
async function login(page: Page, email: string) {
  await page.goto(`/login?next=/account`);
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


test("قائمة التمرين مختصرة: اليوم الافتراضي، الأسبوع الحالي، وصفحة لكل تمرين", async ({ browser }, info) => {
  const email = `trainee-cmp-${info.project.name}@e2e.test`;
  const page = await newPage(browser, info.project.name + "cmp");
  await login(page, email);
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  const { rows: [o] } = await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status, contact_name, contact_phone, idempotency_key, paid_at)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active','متدربة','+966500000000',$1, now()) RETURNING id`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas]);
  const { rows: [b] } = await db.query(`INSERT INTO blocks (order_id, user_id, name, start_date, weeks) VALUES ($1,$2,'بلوك مختصر',current_date,4) RETURNING id`, [o.id, u.id]);
  const plan = JSON.stringify(Array(4).fill({ sets: 3, reps: [10, 10, 10], rir: 2 }));
  const items: string[][] = [];
  for (const [dn, names] of [[1, ["Back Squat", "Glute Bridge"]], [2, ["Seated Cable Row", "Plank"]], [3, ["Bodyweight Squat"]]] as const) {
    const { rows: [d] } = await db.query(`INSERT INTO block_days (block_id, day_no, title) VALUES ($1,$2,$3) RETURNING id`, [b.id, dn, `DAY ${dn}`]);
    const ids: string[] = [];
    let pos = 1;
    for (const n of names) ids.push((await db.query(`INSERT INTO block_items (day_id, position, exercise_id, coach_exercise_id, plan) SELECT $1, $2, id, id, $3 FROM exercises WHERE name = $4 RETURNING id`, [d.id, pos++, plan, n])).rows[0].id);
    items.push(ids);
  }
  const current = page.getByRole("navigation", { name: "اليوم" }).locator('a[aria-current="true"]');

  // لم يبدأ شيئاً: أول يوم
  await page.goto(`/account/orders/${orderNo}/training`);
  await expect(current).toHaveText("DAY 1");
  // الأسبوع الحالي فقط في الواجهة، وباقي الأسابيع داخل «المزيد»
  await expect(page.getByTestId("week-label")).toContainText("الأسبوع 1 من 4");
  await expect(page.getByRole("navigation", { name: "الأسبوع" })).toBeHidden();
  await page.getByTestId("more-tools").locator("summary").first().click();
  await expect(page.getByRole("navigation", { name: "الأسبوع" }).getByRole("link")).toHaveCount(4);
  await page.getByTestId("more-tools").locator("summary").first().click();
  // القائمة بدون نماذج تسجيل: صف لكل تمرين
  await expect(page.getByTestId("exercise-card")).toHaveCount(2);
  await expect(page.getByLabel(/وزن الجولة/)).toHaveCount(0);
  await noHorizontalScroll(page);
  await page.screenshot({ path: `${process.env.SHOT_DIR ?? "/tmp"}/training-list-${info.project.name}.png`, fullPage: true });

  // بدأ اليوم الأول (سجّل تمريناً) ← يبدأ باليوم الثاني
  await db.query(`INSERT INTO item_logs (block_item_id, week_no, exercise_id, weight, weights, reps, rir) SELECT i.id, 1, i.exercise_id, 60, '{60,60,60}', '{10,10,10}', 2 FROM block_items i WHERE i.id = $1`, [items[0][0]]);
  await page.goto(`/account/orders/${orderNo}/training`);
  await expect(current).toHaveText("DAY 2");
  await expect(page.getByTestId("exercise-card").first()).toContainText("Seated Cable Row");
  // اليوم الأول ما زال متاحاً بالضغط، وتمرينه المسجّل عليه علامة
  await page.getByRole("navigation", { name: "اليوم" }).getByRole("link", { name: "DAY 1" }).click();
  await expect(page.getByTestId("exercise-card").first().getByLabel("مسجّل")).toBeVisible();

  // صفحة التمرين: التسجيل والتبديل هناك
  await page.getByTestId("exercise-card").nth(1).click();
  await page.waitForURL(/\/training\/[0-9a-f-]{36}/);
  await expect(page.getByRole("heading", { level: 1 })).toContainText("Glute Bridge");
  await expect(page.getByLabel("وزن الجولة 1")).toBeVisible();
  await noHorizontalScroll(page);
  await page.screenshot({ path: `${process.env.SHOT_DIR ?? "/tmp"}/training-item-${info.project.name}.png`, fullPage: true });
  // تمرين من متدرب آخر لا يُفتح
  const other = await newPage(browser, info.project.name + "cmp2");
  await login(other, `trainee-cmp2-${info.project.name}@e2e.test`);
  expect((await other.goto(`/account/orders/${orderNo}/training/${items[0][0]}`))?.status()).toBe(404);
});
