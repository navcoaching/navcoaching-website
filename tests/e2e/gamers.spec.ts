// بانر «باقة القيمرز» في الصفحة الرئيسية: يختفي بدون باقة منشورة، ويظهر بعد نشرها من لوحة الإدارة. قاعدة nav_e2e.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 200;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.13.${tag.length}.${ip++}` } });
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
async function login(page: Page, email: string, next = "/admin") {
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
async function setStatus(page: Page, id: string, status: "published" | "archived") {
  await page.goto(`/admin/products/${id}`);
  await page.locator('select[name="status"]').selectOption(status);
  await page.getByRole("button", { name: "حفظ المنتج" }).click();
  await expect(page.getByText("تم حفظ المنتج")).toBeVisible();
}

test("بانر باقة القيمرز: مخفي بدون باقة، ويظهر بعد نشرها", async ({ browser }, info) => {
  const project = info.project.name;
  const visitor = await newPage(browser, project + "-v");
  await visitor.goto("/");
  await expect(visitor.getByTestId("gamers-banner")).toHaveCount(0);

  // باقة تجريبية (مسودة) بعرض سعر، ثم تنشرها المدربة من لوحة الإدارة
  const { rows: [p] } = await db.query(
    `INSERT INTO products (slug, category, name, audience, status, sort) VALUES ('gamers', 'follow', 'باقة القيمرز (اختبار)', 'للقيمرز', 'draft', 99)
     ON CONFLICT (slug) DO UPDATE SET status = 'draft' RETURNING id`);
  await db.query(
    `INSERT INTO product_offers (product_id, sku, label, months, price_halalas) VALUES ($1, 'GAMERS-1', 'شهر', 1, 30000) ON CONFLICT (sku) DO NOTHING`, [p.id]);
  const email = `coach-gamers-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-c");
  await login(coach, email);
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [email]);
  try {
    await setStatus(coach, p.id, "published");

    await visitor.goto("/");
    const banner = visitor.getByTestId("gamers-banner");
    await expect(banner).toBeVisible();
    await expect(banner).toContainText("قيمر؟ عندي باقة مصممة لك");
    await expect(banner).toContainText("سرعة استجابة أفضل");
    await expect(banner).toContainText("تقييم مختص");
    await expect(banner).toContainText("300");
    // بعد قسم البرامج مباشرة
    expect(await visitor.evaluate(() => document.querySelector("#programs")?.nextElementSibling?.id)).toBe("gamers");
    await noHorizontalScroll(visitor);
    await banner.getByRole("link", { name: /شوف باقة القيمرز/ }).click();
    await expect(visitor).toHaveURL(/\/programs\/gamers$/);
    await expect(visitor.getByRole("heading", { name: /باقة القيمرز/ }).first()).toBeVisible();
  } finally {
    await setStatus(coach, p.id, "archived");
  }
  await visitor.goto("/");
  await expect(visitor.getByTestId("gamers-banner")).toHaveCount(0);
});
