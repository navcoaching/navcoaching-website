// نسخة قديمة من الصفحة بعد نشر تحديث: الخادم ما يعرف إجراء الحفظ (UnrecognizedActionError).
// المتوقع: رسالة واضحة وإعادة تحميل تلقائية بدل «صار خطأ غير متوقع». (قاعدة nav_e2e)
import { test, expect, type Page } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

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

test("صفحة من نسخة قديمة: رسالة «تحدّث الموقع» وإعادة تحميل تلقائية", async ({ browser }, info) => {
  const project = info.project.name;
  const ctx = await browser.newContext({ ...info.project.use, extraHTTPHeaders: { "x-forwarded-for": `10.21.${project.length}.9` } });
  const page = await ctx.newPage();
  const email = `coach-stale-${project}@e2e.test`;
  await login(page, email, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [email]);
  await page.goto("/admin/free-plans/new");
  // نحاكي خادماً منشوراً بنسخة أحدث: أي إجراء حفظ يرجع «الإجراء غير معروف»
  await page.route("**/admin/free-plans/new", async (route) => {
    if (route.request().method() === "POST" && route.request().headers()["next-action"]) {
      await route.fulfill({ status: 404, headers: { "x-nextjs-action-not-found": "1", "content-type": "text/plain" }, body: "" });
    } else await route.continue();
  });
  await page.getByLabel("اسم الجدول").fill("جدول قديم");
  await page.getByLabel("رابط الصفحة (بالإنجليزي)").fill(`stale-${project}`);
  await page.getByLabel("وصف مختصر").fill("وصف تجريبي لاختبار النسخة القديمة من الصفحة.");
  await page.setInputFiles("#fp-file", { name: "p.pdf", mimeType: "application/pdf", buffer: Buffer.from("%PDF-1.4\n%%EOF\n") });
  await page.getByRole("button", { name: "إنشاء الجدول" }).click();
  await expect(page.getByTestId("stale-version")).toBeVisible();
  await expect(page.getByText("صار خطأ غير متوقع")).toHaveCount(0);
  // إعادة التحميل تلقائياً ترجع النموذج
  await expect(page.getByLabel("اسم الجدول")).toBeVisible({ timeout: 10_000 });
  await ctx.close();
});
