// حذف برنامج أُضيف بالخطأ وحذف عضو (للمدربة فقط، ويُمنع إذا له بيانات فعلية) — قاعدة nav_e2e.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 150;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.23.${tag.length}.${ip++}` } });
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



test("حذف برنامج بالخطأ وحذف عضو بدون طلبات", async ({ browser }, info) => {
  const project = info.project.name;
  const traineeEmail = `trainee-del-${project}@e2e.test`;
  const lonelyEmail = `lonely-del-${project}@e2e.test`;
  const coachEmail = `coach-del-${project}@e2e.test`;
  const t = await newPage(browser, project + "-t");
  await login(t, traineeEmail);
  const l = await newPage(browser, project + "-l");
  await login(l, lonelyEmail);
  const coach = await newPage(browser, project + "-c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);

  // طلب نشط لهذا المتدرب وبرنامج بلا تسجيلات
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [traineeEmail]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  const { rows: [o] } = await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status, contact_name, contact_phone, idempotency_key, paid_at)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active','متدربة','+966500000000',$1, now()) RETURNING id`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas]);
  const mk = async (name: string) => {
    const { rows: [b] } = await db.query(`INSERT INTO blocks (order_id, user_id, name, start_date, weeks) VALUES ($1,$2,$3,current_date,4) RETURNING id`, [o.id, u.id, name]);
    const { rows: [d] } = await db.query(`INSERT INTO block_days (block_id, day_no, title) VALUES ($1,1,'DAY 1') RETURNING id`, [b.id]);
    const { rows: [i] } = await db.query(`INSERT INTO block_items (day_id, position, exercise_id, coach_exercise_id, plan) SELECT $1, 0, id, id, '[]' FROM exercises WHERE name = 'Back Squat' RETURNING id`, [d.id]);
    return { block: b.id as string, item: i.id as string };
  };
  const wrong = await mk("برنامج بالخطأ");
  // أزرار الإنهاء والحذف داخل «بيانات البرنامج» (مطوية على الشاشات الصغيرة)
  const openData = async () => {
    const d = coach.locator("details", { has: coach.locator("summary", { hasText: "بيانات البرنامج" }) }).first();
    if ((await d.getAttribute("open")) === null) await d.locator("summary").first().click();
  };
  await coach.goto(`/admin/orders/${orderNo}/program`);
  await openData();
  await expect(coach.getByTestId("delete-block")).toBeVisible();
  coach.once("dialog", (d) => d.accept());
  await coach.getByRole("button", { name: "حذف البرنامج (أضفته بالخطأ)" }).click();
  await coach.waitForURL(/program\?deleted=1/);
  await expect(coach.getByText("تم حذف البرنامج.")).toBeVisible();
  expect((await db.query(`SELECT count(*)::int n FROM blocks WHERE id = $1`, [wrong.block])).rows[0].n).toBe(0);
  await noHorizontalScroll(coach);

  // برنامج سجّل عليه المتدرب: لا يظهر زر الحذف
  const used = await mk("برنامج مسجّل عليه");
  await db.query(`INSERT INTO item_logs (block_item_id, week_no, exercise_id, weight, reps) SELECT $1, 1, exercise_id, 50, '{10}' FROM block_items WHERE id = $1`, [used.item]);
  await coach.goto(`/admin/orders/${orderNo}/program`);
  await openData();
  await expect(coach.getByTestId("delete-block")).toHaveCount(0);
  await expect(coach.getByText(/فلا يُحذف/)).toBeVisible();

  // الأعضاء: زر الحذف لمن بلا طلبات فقط
  await coach.goto(`/admin/members?q=${encodeURIComponent(traineeEmail)}`);
  await expect(coach.getByTestId("members").getByText(traineeEmail)).toBeVisible();
  await expect(coach.getByTestId("delete-member")).toHaveCount(0);
  await coach.goto(`/admin/members?q=${encodeURIComponent(lonelyEmail)}`);
  await expect(coach.getByTestId("delete-member")).toHaveCount(1);
  coach.once("dialog", (d) => d.accept());
  await coach.getByRole("button", { name: "حذف العضو" }).click();
  // يختفي صف العضو من القائمة، ويُحذف حسابه
  await expect(coach.getByTestId("delete-member")).toHaveCount(0);
  await expect.poll(async () => (await db.query(`SELECT count(*)::int n FROM "user" WHERE email = $1`, [lonelyEmail])).rows[0].n).toBe(0);
  await noHorizontalScroll(coach);
});
