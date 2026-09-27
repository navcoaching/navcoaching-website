// الاحتفاظ بالمتدربين: نافذة التجديد بخصم 10% قبل الانتهاء بـ 5 أيام، شريط الالتزام والـ streak،
// لوحة المدربة (طلبات تحتاج إكمال / تعديل / اشتراكات تنتهي)، ومنح مكافأة 3 أشهر. قاعدة nav_e2e.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 80;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.9.${tag.length}.${ip++}` } });
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

/** اشتراك 3 أشهر نشط بدأ قبل 86 يوماً وينتهي بعد 4 أيام، ومراجعاته الـ 12 منجزة (التزام 100%) */
async function endingOrder(email: string, name: string) {
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(
    `SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  const { rows: [o] } = await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas,
                         amount_due_halalas, status, contact_name, contact_phone, idempotency_key, paid_at,
                         sub_start_at, sub_end_at, review_weekday)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active',$8,'+966512345678',$9, now(),
             (((now() AT TIME ZONE 'Asia/Riyadh')::date - 86) + time '12:00') AT TIME ZONE 'Asia/Riyadh',
             (((now() AT TIME ZONE 'Asia/Riyadh')::date + 4) + time '12:00') AT TIME ZONE 'Asia/Riyadh',
             extract(dow FROM (now() AT TIME ZONE 'Asia/Riyadh'))::smallint)
     RETURNING id`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas, name, `k-${orderNo}-retention`]);
  await db.query(
    `INSERT INTO intakes (order_id, user_id, answers, media_consent, consent_terms_at, consent_whatsapp_at)
     VALUES ($1, $2, '{"goal":"لياقة"}', 'لا', now(), now())`, [o.id, u.id]);
  await db.query(`INSERT INTO review_weeks (order_id, week_no) SELECT $1, g FROM generate_series(1, 12) g`, [o.id]);
  return { orderNo, price: p.price_halalas as number };
}
const sar = (h: number) => `${(h / 100).toLocaleString("en-US", { maximumFractionDigits: 2 })} ر.س`;

test("التجديد بخصم 10%، الالتزام والـ streak، لوحة المدربة ومنح المكافأة", async ({ browser }, info) => {
  const project = info.project.name;
  const coachEmail = `coach-rt-${project}@e2e.test`;
  const traineeEmail = `trainee-rt-${project}@e2e.test`;
  const name = `متدربة تجديد ${project}`;

  const coach = await newPage(browser, project + "-c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  const trainee = await newPage(browser, project + "-t");
  await login(trainee, traineeEmail);
  const { orderNo, price } = await endingOrder(traineeEmail, name);
  const discounted = Math.round(price * 0.9);

  // ---------- المتدرب: النافذة المنبثقة + شريط الالتزام ----------
  await trainee.goto("/account");
  const popup = trainee.getByTestId("renewal-popup");
  await expect(popup).toBeVisible();
  await expect(popup).toContainText("خلال 4 أيام");
  await expect(popup).toContainText("خصم 10%");
  await expect(popup).toContainText(sar(price));
  await expect(popup).toContainText(sar(discounted));
  await noHorizontalScroll(trainee);
  const mine = trainee.getByTestId("my-program");
  await expect(mine.getByTestId("adherence-pct")).toHaveText("100%");
  await expect(mine.getByTestId("streak")).toContainText("12 أسبوعاً متتالية");
  await expect(mine.getByTestId("reward-progress")).toContainText("استحققت");

  // «لاحقاً» تخفيها لبقية اليوم
  await popup.getByRole("button", { name: "لاحقاً" }).click();
  await expect(popup).toBeHidden();
  await trainee.reload();
  await expect(trainee.getByTestId("my-program")).toBeVisible();
  await expect(trainee.getByTestId("renewal-popup")).toHaveCount(0);

  // التجديد من تنبيه الانتهاء: طلب جديد بـ 90% من السعر
  await mine.getByTestId("expiry-alert").getByRole("button", { name: "جدّد بخصم 10%" }).click();
  await trainee.waitForURL(/\/account\/orders\/NAV-.*\?renewed=1/);
  await expect(trainee.getByTestId("renewed-alert")).toBeVisible();
  await expect(trainee.getByTestId("order-status")).toHaveText("بانتظار الدفع");
  await expect(trainee.locator("body")).toContainText(sar(discounted));
  const renewalNo = new URL(trainee.url()).pathname.split("/").pop()!;
  const { rows: [rn] } = await db.query(
    "SELECT amount_due_halalas, list_price_halalas, renewal_kind FROM orders WHERE order_no = $1", [renewalNo]);
  expect(rn).toEqual({ amount_due_halalas: discounted, list_price_halalas: price, renewal_kind: "renewal" });
  expect((await db.query("SELECT count(*)::int n FROM dev_mailbox WHERE recipient = 'coach-notify@e2e.test' AND subject LIKE $1", [`%${renewalNo}%`])).rows[0].n).toBe(1);
  await noHorizontalScroll(trainee);

  await trainee.goto("/account");
  await expect(trainee.getByTestId("renewal-popup")).toHaveCount(0);
  await expect(trainee.getByTestId("my-program").getByTestId("expiry-alert").first()).toContainText("طلب التجديد بانتظار الدفع");

  // ---------- لوحة المدربة ----------
  await coach.goto("/admin");
  await expect(coach.getByTestId("dash-incomplete")).toContainText(name);
  const ending = coach.getByTestId("dash-ending").locator("li", { hasText: name });
  await expect(ending).toContainText("باقي 4 أيام");
  await expect(ending).toContainText("طلب التجديد بانتظار الدفع");
  const todos = coach.getByTestId("dash-todos");
  await expect(todos.locator("li", { hasText: name }).filter({ hasText: "لا يوجد برنامج تمرين" })).toHaveCount(1);
  const eligible = todos.getByTestId("reward-eligible").filter({ hasText: name });
  await expect(eligible).toContainText("التزام 100%");
  await noHorizontalScroll(coach);

  // صفحة الطلب: الالتزام ورابط التجديد
  await coach.goto(`/admin/orders/${orderNo}`);
  const card = coach.getByTestId("retention-card");
  await expect(card.getByTestId("adherence-pct")).toHaveText("100%");
  await expect(card).toContainText(renewalNo);

  // المنح بضغطة (مع تأكيد)
  await coach.goto("/admin");
  coach.once("dialog", (d) => d.accept());
  await coach.getByTestId("reward-eligible").filter({ hasText: name }).getByRole("button", { name: "منح 3 أشهر مجاناً" }).click();
  await coach.waitForURL(/\/admin\?granted=/);
  await expect(coach.getByTestId("granted-alert")).toContainText("تم منح 3 أشهر مجاناً");
  const { rows: [rw] } = await db.query(
    `SELECT r.status, r.amount_due_halalas, r.sub_start_at = o.sub_end_at AS from_end FROM orders r JOIN orders o ON o.id = r.renewal_of
      WHERE o.order_no = $1 AND r.renewal_kind = 'reward'`, [orderNo]);
  expect(rw).toEqual({ status: "active", amount_due_halalas: 0, from_end: true });
  await expect(coach.getByTestId("reward-eligible").filter({ hasText: name })).toHaveCount(0);

  // المتدرب يرى المكافأة
  await trainee.goto("/account");
  await expect(trainee.getByTestId("my-program")).toContainText("حصلت على مكافأة الالتزام");
  await noHorizontalScroll(trainee);

  // مستخدم آخر لا يجدد طلب غيره (قاعدة البيانات ترفض)
  const other = await newPage(browser, project + "-o");
  await login(other, `other-rt-${project}@e2e.test`);
  expect((await other.goto(`/account/orders/${orderNo}`))?.status()).toBe(404);
});
