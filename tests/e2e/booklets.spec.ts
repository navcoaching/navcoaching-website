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
  // كتيب ثاني مخفي (ننتظر إعادة تعيين النموذج بعد النجاح، وإلا يرجع تحديد «يظهر للمتدربين»)
  await expect(up.getByLabel("اسم الكتيب")).toHaveValue("");
  await up.getByLabel("اسم الكتيب").fill(hidden);
  await up.getByLabel("ملف PDF").setInputFiles({ name: "h.pdf", mimeType: "application/pdf", buffer: PDF });
  await up.getByLabel("يظهر للمتدربين").uncheck();
  await expect(up.getByLabel("يظهر للمتدربين")).not.toBeChecked();
  await up.getByRole("button", { name: "رفع الكتيب" }).click();
  // رسالة النجاح باقية من الرفع الأول، فننتظر إعادة تعيين النموذج (تحدث فقط بعد نجاح الرفع الثاني)
  await expect(up.getByLabel("اسم الكتيب")).toHaveValue("");
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
  await expect(sec.getByRole("heading", { name: "تحميل الكتيبات" })).toBeVisible();
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

test("شراء كتيب: المدربة تحدد السعر، الزائر يسجّل ويطلب، وبعد تأكيد الدفع يحمّله؛ وباقة التغذية ما تفتحه", async ({ browser }, info) => {
  const project = info.project.name;
  const title = `كتيب للبيع ${project}`;
  const coachEmail = `coach-bks-${project}@e2e.test`;
  const coach = await newPage(browser, project + "-sc");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto("/admin/booklets");
  const up = coach.getByTestId("booklet-upload");
  await up.getByLabel("اسم الكتيب").fill(title);
  await up.getByLabel("وصف قصير (اختياري)").fill("أساسيات التمرين والتغذية.");
  await up.getByLabel(/سعر البيع/).fill("49");
  await up.getByLabel("ملف PDF").setInputFiles({ name: "s.pdf", mimeType: "application/pdf", buffer: PDF });
  await up.getByRole("button", { name: "رفع الكتيب" }).click();
  await expect(up.getByText("تم رفع الكتيب.")).toBeVisible();
  await coach.reload();
  await expect(coach.getByTestId("booklet-row").filter({ hasText: title }).getByTestId("booklet-for-sale")).toContainText("49");
  // منتج الكتيب ما يظهر في المنتجات ولا البرامج
  await coach.goto("/admin/products");
  await expect(coach.locator("body")).not.toContainText(`كتيب: ${title}`);

  // الزائر: يشوف الكتيب والسعر، والشراء يطلب تسجيل الدخول
  const buyerEmail = `buyer-bk-${project}@e2e.test`;
  const buyer = await newPage(browser, project + "-sb");
  await buyer.goto("/programs");
  await expect(buyer.locator("body")).not.toContainText(`كتيب: ${title}`);
  await buyer.goto("/booklets");
  const card = buyer.getByTestId("booklet-card").filter({ hasText: title });
  await expect(card).toContainText("49");
  await card.getByRole("link", { name: "شراء الكتيب" }).click();
  await buyer.getByLabel("البريد الإلكتروني").fill(buyerEmail);
  await buyer.getByRole("button", { name: "أرسل رمز الدخول" }).click();
  await buyer.getByLabel("رمز الدخول").fill(await latestOtp(buyerEmail));
  await buyer.getByRole("button", { name: "دخول" }).click();
  await buyer.waitForURL(/\/booklets/);
  await noHorizontalScroll(buyer);
  const card2 = buyer.getByTestId("booklet-card").filter({ hasText: title });
  await card2.getByRole("button", { name: "شراء الكتيب" }).click();
  const form = card2.getByTestId("booklet-buy-form");
  await form.getByLabel("رقم الجوال (واتساب)").fill("512345678");
  await form.getByRole("button", { name: /تأكيد الطلب/ }).click();
  await buyer.waitForURL(/\/account\/orders\//);
  const orderNo = buyer.url().split("/").pop()!;
  await expect(buyer.locator("body")).toContainText("بانتظار الدفع");
  await expect(buyer.getByTestId("start-pref-value")).toHaveCount(0);
  const o = (await db.query("SELECT amount_due_halalas, category, contact_phone FROM orders WHERE order_no = $1", [orderNo])).rows[0];
  expect(o).toEqual({ amount_due_halalas: 4900, category: "files", contact_phone: "+966512345678" });
  // قبل الدفع: ما يحمّله، وصفحة الكتيبات تعرض «إكمال الدفع»
  const { rows: [b] } = await db.query(`SELECT id FROM booklets WHERE title = $1`, [title]);
  await buyer.goto(`/api/booklets/${b.id}`);
  await expect(buyer.getByText("تعذّر التحميل")).toBeVisible();
  await buyer.goto("/booklets");
  await expect(buyer.getByTestId("booklet-card").filter({ hasText: title }).getByTestId("booklet-pending")).toContainText(orderNo);

  // المدربة تأكد الدفع ← يتحول «تم التسليم» تلقائياً
  await coach.goto(`/admin/orders/${orderNo}`);
  const bar = coach.getByTestId("status-bar");
  await bar.getByLabel("تغيير الحالة إلى").selectOption({ label: "قيد الإعداد (تأكيد الدفع)" });
  await bar.locator('input[name="bank_confirmed"]').check();
  await bar.getByRole("button", { name: "تحديث" }).click();
  await expect(coach.locator(".status").first()).toHaveText("تم التسليم");

  // المشتري: يحمّله من صفحة الطلب ومن «حسابي»
  await buyer.goto(`/account/orders/${orderNo}`);
  const [dl] = await Promise.all([buyer.waitForEvent("download"), buyer.getByTestId("order-booklet").click()]);
  expect(dl.suggestedFilename()).toBe(`${title}.pdf`);
  await buyer.goto("/account");
  await expect(buyer.getByTestId("booklets")).toContainText(title);
  await buyer.goto("/booklets");
  await expect(buyer.getByTestId("booklet-card").filter({ hasText: title }).getByTestId("booklet-owned")).toBeVisible();
  await noHorizontalScroll(buyer);

  // مشترك باقة التغذية: ما تشملها الكتيبات
  const nutEmail = `trainee-bk-nut-${project}@e2e.test`;
  const nut = await newPage(browser, project + "-sn");
  await login(nut, nutEmail);
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [nutEmail]);
  const { rows: [p] } = await db.query(`SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id WHERE p.slug = 'nutrition' LIMIT 1`);
  const no = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  await db.query(
    `INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas, amount_due_halalas, status,
                         contact_name, contact_phone, idempotency_key, paid_at, sub_start_at, sub_end_at)
     VALUES ($1,$2,$3,$4,'follow',$5,$6,1,$7,$7,'active','متدرب تغذية','+966500000000',$1, now(), now(), now() + interval '28 days')`,
    [no, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas]);
  await nut.goto("/account");
  await expect(nut.getByTestId("booklets")).toHaveCount(0);
  await nut.goto("/booklets");
  await expect(nut.getByTestId("booklet-card").filter({ hasText: title }).getByRole("button", { name: "شراء الكتيب" })).toBeVisible();

  // تنظيف: إيقاف البيع
  await coach.goto("/admin/booklets");
  const row = coach.getByTestId("booklet-row").filter({ hasText: title });
  await row.getByText("تعديل").click();
  await row.getByLabel(/سعر البيع/).fill("");
  await row.getByRole("button", { name: "حفظ" }).click();
  await expect(row.getByText("تم الحفظ.")).toBeVisible();
  await buyer.goto("/booklets");
  await expect(buyer.getByTestId("booklet-card").filter({ hasText: title })).toHaveCount(0);
});
