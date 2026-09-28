// الكتيبات (رفع المدربة ← تحميل المتدرب المشترك). قاعدة nav_e2e.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const CRON_SECRET = "e2e-cron-secret-0123456789";
const COACH_MAIL = "coach-notify@e2e.test";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 240;
async function newPage(browser: Browser, tag: string) {
  const ctx = await browser.newContext({ ...test.info().project.use, extraHTTPHeaders: { "x-forwarded-for": `10.15.${tag.length}.${ip++}` } });
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


const PDF = Buffer.from("%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n");

test("الكتيبات: المدربة ترفع، والمتدرب المشترك يحمّل، وغير المشترك ما يشوفها", async ({ browser }, info) => {
  const project = info.project.name;
  const title = `كتيب التغذية ${project}`;
  const hidden = `كتيب مخفي ${project}`;

  const coachEmail = `coach-bk-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-bc");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto("/admin/booklets");
  const up = coach.getByTestId("booklet-upload");
  // غير PDF مرفوض
  await up.getByLabel("اسم الكتيب").fill(title);
  await up.getByLabel("ملف PDF").setInputFiles({ name: "x.pdf", mimeType: "application/pdf", buffer: Buffer.from("not a pdf") });
  await up.getByRole("button", { name: "رفع الكتيب" }).click();
  await expect(up.getByText("الملف لازم يكون PDF.")).toBeVisible();
  await up.getByLabel("ملف PDF").setInputFiles({ name: "guide.pdf", mimeType: "application/pdf", buffer: PDF });
  await up.getByRole("button", { name: "رفع الكتيب" }).click();
  await expect(up.getByText("تم رفع الكتيب.")).toBeVisible();
  // كتيب ثاني مخفي
  await up.getByLabel("اسم الكتيب").fill(hidden);
  await up.getByLabel("ملف PDF").setInputFiles({ name: "h.pdf", mimeType: "application/pdf", buffer: PDF });
  await up.getByLabel("يظهر للمتدربين").uncheck();
  await up.getByRole("button", { name: "رفع الكتيب" }).click();
  await expect(up.getByText("تم رفع الكتيب.")).toBeVisible();
  await coach.reload();
  await expect(coach.getByTestId("booklet-row").filter({ hasText: title })).toContainText("ظاهر");
  await expect(coach.getByTestId("booklet-row").filter({ hasText: hidden })).toContainText("مخفي");
  await noHorizontalScroll(coach);

  // متدرب بدون اشتراك: ما يشوف القسم، والرابط المباشر يرجعه برسالة
  const { rows: [b] } = await db.query(`SELECT id FROM booklets WHERE title = $1`, [title]);
  const none = await newPage(browser, project + "-bn");
  await login(none, `trainee-bk-none-${project}@e2e.test`);
  await none.goto("/account");
  await expect(none.getByTestId("booklets")).toHaveCount(0);
  await none.goto(`/api/booklets/${b.id}`);
  await expect(none.getByText("تعذّر التحميل")).toBeVisible();

  // متدرب مشترك (نشط): يشوف الظاهر فقط ويحمّله
  const email = `trainee-bk-${project}@e2e.test`;
  const trainee = await newPage(browser, project + "-bt");
  await login(trainee, email);
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status,
                         contact_name, contact_phone, idempotency_key, paid_at, sub_start_at, sub_end_at)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,3,$7,$7,'active','متدرب كتيبات','+966500000000',$1, now(), now(), now() + interval '80 days')`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas]);
  await trainee.goto("/account");
  const sec = trainee.getByTestId("booklets");
  await expect(sec.getByRole("heading", { name: "📘 تحميل الكتيبات" })).toBeVisible();
  await expect(sec).toContainText(title);
  await expect(sec).not.toContainText(hidden);
  const [dl] = await Promise.all([
    trainee.waitForEvent("download"),
    sec.locator("li", { hasText: title }).getByRole("link", { name: /تحميل PDF/ }).click(),
  ]);
expect(dl.suggestedFilename()).toBe(`${title}.pdf`);
  await noHorizontalScroll(trainee);

  // الحذف يخفيه من المتدرب
  coach.once("dialog", (d) => d.accept());
  await coach.getByTestId("booklet-row").filter({ hasText: title }).getByRole("button", { name: "حذف" }).click();
  await expect(coach.getByTestId("booklet-row").filter({ hasText: title })).toHaveCount(0);
  await trainee.goto("/account");
  await expect(trainee.locator("body")).not.toContainText(title);
  await db.query(`DELETE FROM booklets WHERE title = $1`, [hidden]);
});
