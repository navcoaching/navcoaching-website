// مقطع شرح استخدام الموقع بالكامل: قسم كبير في الصفحة الرئيسية، يُضبط من «المحتوى والإعدادات» (قاعدة nav_e2e).
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 90;
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


test("مقطع شرح الموقع بالكامل: قسم في الصفحة الرئيسية يظهر بعد إضافة الرابط ويختفي بمسحه", async ({ browser }, info) => {
  const project = info.project.name;
  const coachEmail = `coach-gv-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto("/admin/content#guide-video");
  const box = coach.getByTestId("guide-video-settings");
  const url = box.getByLabel("رابط المقطع على يوتيوب");

  await url.fill("https://example.com/v.mp4");
  await box.getByRole("button", { name: "حفظ" }).click();
  await expect(box.getByText("الرابط غير صالح")).toBeVisible();
  await url.fill("https://www.youtube.com/watch?v=dQw4w9WgXcQ");
  await box.getByLabel("العنوان", { exact: true }).fill("شرح الموقع كامل");
  await box.getByRole("button", { name: "حفظ" }).click();
  await expect(box.getByText(/تم/)).toBeVisible();

  const visitor = await newPage(browser, project + "-v");
  await visitor.goto("/");
  const sec = visitor.getByTestId("guide-video");
  await expect(sec.getByRole("heading", { name: "شرح الموقع كامل" })).toBeVisible();
  // إطار عرضي 16:9 يملأ عرض القسم
  const frame = sec.locator(".short-frame.wide");
  const bb = (await frame.boundingBox())!;
  expect(Math.abs(bb.width / bb.height - 16 / 9)).toBeLessThan(0.05);
  await sec.getByRole("button", { name: /تشغيل المقطع/ }).click();
  await expect(sec.locator("iframe")).toHaveAttribute("src", /youtube-nocookie\.com\/embed\/dQw4w9WgXcQ/);
  await noHorizontalScroll(visitor);
  await sec.screenshot({ path: `${process.env.SHOT_DIR ?? "/tmp"}/guide-video-${project}.png` });

  // مسح الرابط يخفي القسم
  await coach.reload();
  await box.getByLabel("رابط المقطع على يوتيوب").fill("");
  await box.getByRole("button", { name: "حفظ" }).click();
  await expect(box.getByText(/تم/)).toBeVisible();
  await visitor.goto("/");
  await expect(visitor.getByTestId("guide-video")).toHaveCount(0);
});
