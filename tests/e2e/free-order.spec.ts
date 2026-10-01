// قبول الطلب «مجاني» من شريط الحالة: تاريخ بداية ونهاية، ويتفعّل بدون دفع، ويظهر للمتدرب (قاعدة nav_e2e).
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 60;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.19.${tag.length}.${ip++}` } });
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


test("مجاني: المدربة تقبل الطلب بمدة تحددها، ويتفعّل بدون دفع، وينتهي بعدها", async ({ browser }, info) => {
  const project = info.project.name;
  const email = `trainee-free-${project}@e2e.test`;
  const trainee = await newPage(browser, project);
  await login(trainee, email);
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status,
                         contact_name, contact_phone, idempotency_key)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,NULL,'awaiting_quote','متدرب مجاني','+966500000000',$1)`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas]);

  const coachEmail = `coach-free-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto(`/admin/orders/${orderNo}`);
  const bar = coach.getByTestId("status-bar");
  await bar.getByLabel("تغيير الحالة إلى").selectOption({ label: "مجاني (تفعيل بدون دفع)" });
  // تظهر خانات البداية والنهاية، ولا يُطلب تأكيد بنكي
  const dates = bar.getByTestId("free-dates");
  await expect(dates).toBeVisible();
  await expect(bar.getByText(/تأكدت من وصول المبلغ/)).toHaveCount(0);
  await dates.getByRole("button", { name: "4 أسابيع" }).click();
  await noHorizontalScroll(coach);
  coach.once("dialog", (d) => d.accept());
  await bar.getByRole("button", { name: "تحديث" }).click();
  await expect(bar.getByText("تم قبول الطلب مجاناً")).toBeVisible();

  const { rows: [o] } = await db.query(
    `SELECT status, is_free, amount_due_halalas, ((sub_end_at AT TIME ZONE 'Asia/Riyadh')::date - (sub_start_at AT TIME ZONE 'Asia/Riyadh')::date) AS days FROM orders WHERE order_no = $1`, [orderNo]);
  expect(o).toMatchObject({ status: "active", is_free: true, amount_due_halalas: 0, days: 27 }); // 4 أسابيع = 28 يوماً شاملة يوم النهاية

  await coach.reload();
  await expect(coach.getByTestId("free-tag")).toHaveText("مجاني");
  await coach.goto("/admin/orders");
  await expect(coach.getByRole("row", { name: new RegExp(orderNo) })).toContainText("مجاني");

  // المتدرب: الطلب نشط ومجاني
  await trainee.goto(`/account/orders/${orderNo}`);
  await expect(trainee.getByText("مجاني 🎁")).toBeVisible();
  await expect(trainee.getByText("البرنامج نشط").first()).toBeVisible();
  await noHorizontalScroll(trainee);

  // نهاية المدة: ينتهي تلقائياً مع التذكيرات
  await db.query(`UPDATE orders SET sub_end_at = now() - interval '2 days' WHERE order_no = $1`, [orderNo]);
  const run = await coach.request.post("/api/cron/reminders", { headers: { "x-cron-secret": "e2e-cron-secret-0123456789" }, data: { ignore_quiet_hours: true } });
  expect(run.status()).toBe(200);
  expect((await db.query(`SELECT status FROM orders WHERE order_no = $1`, [orderNo])).rows[0].status).toBe("completed");
});
