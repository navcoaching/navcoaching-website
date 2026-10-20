// أقسام الطلبات (باقات/استشارات/مجانية) والأرقام الشهرية في الرئيسية — قاعدة nav_e2e.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 20;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.24.${tag.length}.${ip++}` } });
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

test("الطلبات: أقسام الباقات والاستشارات والمجانية، والرئيسية: الأرقام الشهرية", async ({ browser }, info) => {
  const project = info.project.name;
  const email = `coach-sec-${project}@e2e.test`;
  const coach = await newPage(browser, project);
  await login(coach, email);
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [email]);

  await coach.goto("/admin/orders");
  const tabs = coach.getByTestId("order-sections");
  await expect(tabs.getByRole("link", { name: /الباقات/ })).toBeVisible();
  await expect(tabs.getByRole("link", { name: /الاستشارات/ })).toBeVisible();
  await expect(tabs.getByRole("link", { name: /الجداول المجانية/ })).toBeVisible();
  for (const [name, sec] of [["الباقات", "packages"], ["الاستشارات", "consult"], ["الجداول المجانية", "free"]] as const) {
    await tabs.getByRole("link", { name: new RegExp(name) }).click();
    await expect(coach).toHaveURL(new RegExp(`sec=${sec}`));
    await expect(tabs.locator("a[aria-current=true]")).toContainText(name);
    // كل صف بالقسم من نوعه
    const rows = await coach.locator("table.t tbody tr").count();
    if (sec === "free") await expect(coach.locator("table.t tbody tr td:nth-child(4) .status.ok")).toHaveCount(rows === 1 && (await coach.getByText("لا توجد نتائج.").count()) ? 0 : rows);
    await noHorizontalScroll(coach);
  }

  await coach.goto("/admin");
  const stats = coach.getByTestId("monthly-stats");
  await expect(stats).toContainText("عدد الطلبات");
  await expect(stats).toContainText("عدد الأعضاء الجدد");
  await expect(stats).toContainText("مجموع المبالغ المدفوعة");
  await expect(stats.locator("svg")).toHaveCount(3);
  await noHorizontalScroll(coach);
});
