// موعد بداية البرنامج: المتدرب يغيّره قبل التفعيل، والمدربة ترى تاق الأولوية، والتفعيل يبدأ الاشتراك منه. قاعدة nav_e2e.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 200;
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
const riyadhToday = `(now() AT TIME ZONE 'Asia/Riyadh')::date`;

test("موعد البداية: تغيير المتدرب، تاق الأولوية للمدربة، والتفعيل من التاريخ المختار", async ({ browser }, info) => {
  const project = info.project.name;
  const email = `trainee-start-${project}@e2e.test`;
  const trainee = await newPage(browser, project);
  await login(trainee, email);
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const mk = async (name: string, pref: string | null) => {
    const no = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
    await db.query(
      `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status,
                           contact_name, contact_phone, idempotency_key, preferred_start)
       VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'preparing',$8,'+966500000000',$1, ${pref ?? "NULL"})`,
      [no, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas, name]);
    return no;
  };
  const later = await mk(`متأخر ${project}`, `${riyadhToday} + 10`);
  const asap = await mk(`عاجل ${project}`, null);

  // المتدرب يغيّر موعد الطلب العاجل إلى «بعد شهر»
  await trainee.goto(`/account/orders/${asap}`);
  await expect(trainee.getByTestId("start-pref-value")).toHaveText("بأقرب وقت");
  const form = trainee.getByTestId("start-pref-form");
  await form.locator("label.choice", { hasText: "في تاريخ أحدده" }).click();
  await form.getByRole("button", { name: "بعد شهر" }).click();
  await form.getByRole("button", { name: "حفظ الموعد" }).click();
  await expect(form).toContainText("تم حفظ موعد البداية");
  expect((await db.query(`SELECT preferred_start = ${riyadhToday} + 30 AS ok FROM orders WHERE order_no = $1`, [asap])).rows[0].ok).toBe(true);
  await noHorizontalScroll(trainee);
  // ويرجعه «بأقرب وقت»
  await form.locator("label.choice", { hasText: "بأقرب وقت" }).click();
  await form.getByRole("button", { name: "حفظ الموعد" }).click();
  await expect(form).toContainText("نبدأ بأقرب وقت");
  expect((await db.query(`SELECT preferred_start FROM orders WHERE order_no = $1`, [asap])).rows[0].preferred_start).toBeNull();

  // المدربة: التاقات، و«بأقرب وقت» قبل المتأخر
  const coachEmail = `coach-start-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto("/admin");
  const list = coach.getByTestId("dash-incomplete");
  const asapLi = list.locator("li", { hasText: `عاجل ${project}` });
  const laterLi = list.locator("li", { hasText: `متأخر ${project}` });
  await expect(asapLi.getByTestId("start-tag")).toHaveText("⚡ بأقرب وقت");
  await expect(laterLi.getByTestId("start-tag")).toContainText("بعد 10 يوم");
  const names = await list.locator("li b").allTextContents();
  expect(names.indexOf(`عاجل ${project}`)).toBeLessThan(names.indexOf(`متأخر ${project}`));
  await noHorizontalScroll(coach);
  await coach.goto(`/admin/orders?q=${encodeURIComponent(later)}`);
  await expect(coach.getByTestId("start-tag").first()).toContainText("📅 يبدأ");
  await coach.goto(`/admin/orders/${later}`);
  await expect(coach.getByTestId("start-tag")).toContainText("بعد 10 يوم");

  // التفعيل: الاشتراك يبدأ من التاريخ المختار
  await db.query(`UPDATE orders SET status = 'active', paid_at = now() WHERE order_no = $1`, [later]);
  const o = (await db.query(`SELECT (sub_start_at AT TIME ZONE 'Asia/Riyadh')::date = ${riyadhToday} + 10 AS ok FROM orders WHERE order_no = $1`, [later])).rows[0];
  expect(o.ok).toBe(true);
  await trainee.goto(`/account/orders/${later}`);
  await expect(trainee.getByTestId("start-pref-form")).toHaveCount(0);
  await expect(trainee.getByTestId("sub-start")).toBeVisible();

  // «طلباتي»: الطلبات المكتملة/الملغاة مطوية تحت «طلبات سابقة»
  await db.query(`UPDATE orders SET status = 'cancelled' WHERE order_no = $1`, [asap]);
  await trainee.goto("/account");
  const past = trainee.getByTestId("past-orders");
  await expect(past).toContainText("طلبات سابقة (1)");
  await expect(past.getByRole("link", { name: new RegExp(asap) })).toBeHidden();
  await past.locator("summary").click();
  await expect(past.getByRole("link", { name: new RegExp(asap) })).toBeVisible();
  // الطلب الفعّال يظهر في «برنامجي» فقط، ولا يتكرر في «طلباتي»
  await expect(trainee.getByTestId("my-program").locator(`a[href="/account/orders/${later}"]`)).toBeVisible();
  await expect(trainee.locator(`a.order-card[href$="${later}"]`)).toHaveCount(0);
  await expect(trainee.getByTestId("orders-in-program")).toBeVisible();
  await noHorizontalScroll(trainee);
});
