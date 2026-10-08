// خلط الحسابات (متدربة تشوف برنامج غيرها): الدخول يوضح صاحب الجهاز، تنبيه الطلب باسم مختلف، نقل الطلب لصاحبته، وتأكيد الطلب باسم شخص آخر.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 10;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.31.${tag.length}.${ip++}` } });
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
async function fillLogin(page: Page, email: string) {
  await page.getByLabel("البريد الإلكتروني").fill(email);
  await page.getByRole("button", { name: "أرسل رمز الدخول" }).click();
  await page.getByLabel("رمز الدخول").fill(await latestOtp(email));
  await page.getByRole("button", { name: "دخول" }).click();
  await page.waitForURL((u) => !u.pathname.startsWith("/login"));
}
async function login(page: Page, email: string, next = "/account") {
  await page.goto(`/login?next=${encodeURIComponent(next)}`);
  await fillLogin(page, email);
}
async function pickRadio(page: Page, name: string, value: string) {
  const input = page.locator(`input[name="${name}"][value="${value}"]`);
  await expect(async () => { await input.locator("xpath=..").click(); await expect(input).toBeChecked({ timeout: 1000 }); }).toPass();
}
async function noHorizontalScroll(page: Page) {
  const [sw, iw] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  expect(sw).toBeLessThanOrEqual(iw);
}

test("الدخول على جهاز داخل بحساب آخر: يوضح صاحب الحساب، والخروج ثم الدخول بالبريد الثاني يفتح حسابه هو", async ({ browser }, info) => {
  const p = info.project.name;
  const first = `ghaida-dev-${p}@e2e.test`, second = `sarah-dev-${p}@e2e.test`;
  const page = await newPage(browser, p + "dev");
  await login(page, first);
  await expect(page.getByTestId("account-who")).toContainText(first);
  // صفحة الدخول ما تدخل تلقائياً بالحساب الموجود
  await page.goto("/login?next=/account");
  await expect(page.getByTestId("signed-in-as")).toContainText(first);
  await page.getByRole("button", { name: /لست أنا/ }).click();
  await expect(page.getByLabel("البريد الإلكتروني")).toBeVisible();
  await fillLogin(page, second);
  await expect(page.getByTestId("account-who")).toContainText(second);
  await expect(page.getByTestId("account-who")).not.toContainText(first);
  await noHorizontalScroll(page);
});

test("طلب في حساب شخص آخر: تنبيه للمدربة، ونقله لصاحبته فيختفي من الحساب الخطأ ويظهر في حسابها", async ({ browser }, info) => {
  const p = info.project.name;
  const wrongEmail = `sarah-mv-${p}@e2e.test`, rightEmail = `ghaida-mv-${p}@e2e.test`, coachEmail = `coach-mv-${p}@e2e.test`;
  const wrong = await newPage(browser, p + "w");
  await login(wrong, wrongEmail);
  await db.query(`UPDATE "user" SET name = 'سارة' WHERE email = $1`, [wrongEmail]);
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [wrongEmail]);
  const { rows: [pr] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  const { rows: [o] } = await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status, contact_name, contact_phone, idempotency_key, paid_at, source)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active','غيداء','+966500000000',$1, now(), 'manual') RETURNING id`,
    [orderNo, u.id, pr.id, pr.offer_id, pr.name, pr.label, pr.price_halalas]);
  await db.query(`INSERT INTO blocks (order_id, user_id, name, start_date, weeks) VALUES ($1,$2,'بلوك غيداء',current_date,4)`, [o.id, u.id]);
  await wrong.goto("/account");
  await expect(wrong.getByTestId("my-program")).toBeVisible();

  const coach = await newPage(browser, p + "c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto("/admin");
  await expect(coach.getByTestId("coach-alerts")).toContainText(orderNo);
  await expect(coach.getByTestId("coach-alerts").locator("li", { hasText: orderNo })).toContainText(wrongEmail);
  await coach.goto(`/admin/orders/${orderNo}`);
  await expect(coach.getByTestId("owner-mismatch")).toContainText("غيداء");
  const mv = coach.getByTestId("move-order");
  await mv.locator("summary").click();
  await mv.getByLabel("بريد صاحب الطلب الصحيح").fill(rightEmail);
  await mv.getByLabel(/تأكدت أن هذا البريد/).check();
  coach.once("dialog", (d) => d.accept());
  await mv.getByRole("button", { name: "نقل الطلب" }).click();
  await expect(coach.getByText(/تم نقل الطلب لحساب/)).toBeVisible();
  await coach.reload();
  await expect(coach.getByTestId("owner-mismatch")).toHaveCount(0);
  await expect(coach.getByTestId("owner-card")).toContainText(rightEmail);
  await noHorizontalScroll(coach);

  // الحساب الخطأ ما يشوف الطلب ولا برنامجه
  await wrong.goto("/account");
  await expect(wrong.getByTestId("my-program")).toHaveCount(0);
  expect((await wrong.goto(`/account/orders/${orderNo}`))?.status()).toBe(404);
  expect((await wrong.goto(`/account/orders/${orderNo}/training`))?.status()).toBe(404);
  // صاحبة الطلب تدخل ببريدها وتشوفه
  const right = await newPage(browser, p + "r");
  await login(right, rightEmail);
  await expect(right.getByTestId("my-program")).toBeVisible();
  await expect(right.getByTestId("account-who")).toContainText(rightEmail);
});

test("الاستبيان باسم شخص غير صاحب الحساب: يوقف الإرسال حتى يؤكد أن الطلب له", async ({ browser }, info) => {
  const p = info.project.name;
  const email = `sarah-co-${p}@e2e.test`;
  const page = await newPage(browser, p + "co");
  await login(page, email, "/checkout/int1");
  await db.query(`UPDATE "user" SET name = 'سارة' WHERE email = $1`, [email]);
  await page.goto("/checkout/int1");
  await expect(page.getByTestId("order-account")).toBeHidden(); // في الخطوة الأخيرة فقط
  await page.getByLabel("الاسم").fill("غيداء");
  await page.locator("#phone").fill("512345678");
  await pickRadio(page, "gender", "أنثى");
  await page.locator("#age").fill("27");
  await page.getByRole("button", { name: "التالي" }).click();
  await pickRadio(page, "goal", "لياقة وقوة");
  await pickRadio(page, "level", "مبتدئ · أقل من 6 أشهر");
  await pickRadio(page, "place", "البيت");
  await page.locator('input[name="equip"][value="دمبلز"]').check({ force: true });
  await page.locator("#days").selectOption("3 أيام");
  await page.locator("#duration").selectOption("ساعة");
  await page.getByRole("button", { name: "التالي" }).click();
  await pickRadio(page, "injury", "لا");
  await pickRadio(page, "condition", "لا");
  await page.locator('input[name="health_ack"]').check();
  await page.getByRole("button", { name: "التالي" }).click();
  await page.locator("#weight").fill("60");
  await page.locator("#height").fill("160");
  await page.locator("#calories").selectOption("أعرف الأساسيات");
  await page.getByRole("button", { name: "التالي" }).click();
  await expect(page.getByTestId("order-account")).toContainText(email);
  await page.locator("#expectations").fill("متابعة أسبوعية");
  await page.locator("#media").selectOption("لا، أفضّل الخصوصية");
  await page.locator('input[name="consent_terms"]').check();
  await page.locator('input[name="consent_wa"]').check();
  await page.getByRole("button", { name: "أرسل الاستبيان وانتقل للدفع" }).click();
  await expect(page.locator(".alert.err")).toContainText("والطلب باسم «غيداء»");
  expect((await db.query(`SELECT count(*)::int n FROM orders o JOIN "user" u ON u.id = o.user_id WHERE u.email = $1`, [email])).rows[0].n).toBe(0);
  await page.getByTestId("for-me").locator("input").check();
  await page.getByRole("button", { name: "أرسل الاستبيان وانتقل للدفع" }).click();
  await expect(page).toHaveURL(/\/account\/orders\/NAV-\d{6}-[A-Z0-9]{5}\?new=1/);
  await noHorizontalScroll(page);
});
