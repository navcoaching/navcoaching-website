// رحلة كاملة على الجوال والآيباد والكمبيوتر، ببيانات اختبار في قاعدة nav_e2e المنفصلة:
// تصفح ← دخول ← استبيان وطلب ← رفع إيصال ← اعتماد المدربة ← ملفات ← مراجعة أسبوعية ← تقييم ← نشر التقييم.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";
import sharp from "sharp";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ipCounter = 10;
async function newUserPage(browser: Browser, project: string) {
  // عنوان IP مختلف لكل مستخدم تجريبي حتى لا تتداخل حدود الطلبات بين المستخدمين في نفس الجهاز
  const ctx = await browser.newContext({
    ...test.info().project.use,
    extraHTTPHeaders: { "x-forwarded-for": `10.0.${project.length}.${ipCounter++}` },
  });
  return ctx.newPage();
}

async function latestOtp(email: string) {
  for (let i = 0; i < 20; i++) {
    const { rows } = await db.query("SELECT body FROM dev_mailbox WHERE recipient = $1 AND subject LIKE 'رمز الدخول%' ORDER BY id DESC LIMIT 1", [email]);
    const m = rows[0]?.body.match(/رمز الدخول: (\d{6})/);
    if (m) return m[1];
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error("OTP not found for " + email);
}

async function login(page: Page, email: string) {
  await page.getByLabel("البريد الإلكتروني").fill(email);
  await page.getByRole("button", { name: "أرسل رمز الدخول" }).click();
  await expect(page.getByLabel("رمز الدخول")).toBeVisible();
  await page.getByLabel("رمز الدخول").fill(await latestOtp(email));
  await page.getByRole("button", { name: "دخول" }).click();
  await page.waitForURL((u) => !u.pathname.startsWith("/login"));
}

async function noHorizontalScroll(page: Page) {
  const [sw, iw] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  expect(sw, `horizontal overflow on ${page.url()}`).toBeLessThanOrEqual(iw);
}

async function pickRadio(page: Page, name: string, value: string) {
  // نضغط على نص الخيار كما يفعل المستخدم، وننتظر حتى يثبت الاختيار
  const input = page.locator(`input[name="${name}"][value="${value}"]`);
  await expect(async () => {
    await input.locator("xpath=..").click();
    await expect(input).toBeChecked({ timeout: 1000 });
  }).toPass({ timeout: 10_000 });
}

test("رحلة الشراء والمتابعة والتقييم", async ({ browser }, info) => {
  const project = info.project.name;
  const clientEmail = `client-${project}@e2e.test`;
  const otherEmail = `other-${project}@e2e.test`;
  const coachEmail = `coach-${project}@e2e.test`;

  // ---------- 1) الزائر يتصفح ----------
  const page = await newUserPage(browser, project);
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1 })).toContainText("برامج تدريب وتغذية مخصصة لأهدافك");
  await expect(page.locator("#intro")).toHaveCount(0); // لا يوجد رابط فيديو بعد ← القسم مخفي
  await noHorizontalScroll(page);
  await page.goto("/programs");
  await expect(page.getByRole("link", { name: /المكثفة/ }).first()).toBeVisible();
  await noHorizontalScroll(page);
  await page.goto("/programs/intensive");
  await expect(page.getByText("599").first()).toBeVisible();
  await expect(page.getByText("ماذا يشمل؟")).toBeVisible();
  await noHorizontalScroll(page);

  // ---------- 2) الشراء يتطلب الدخول ----------
  await page.getByRole("link", { name: /شهر واحد/ }).click();
  await expect(page).toHaveURL(/\/login\?next=%2Fcheckout%2Fint1/);
  await login(page, clientEmail);
  await expect(page).toHaveURL(/\/checkout\/int1/);
  // تنبيه المدربة بالتسجيل الجديد
  const signup = await db.query("SELECT subject FROM dev_mailbox WHERE recipient = 'coach-notify@e2e.test' AND subject LIKE '%' || $1 || '%'", [clientEmail]);
  expect(signup.rows[0]?.subject).toContain("تسجيل جديد");

  // ---------- 3) الاستبيان (5 خطوات) ----------
  await noHorizontalScroll(page);
  await expect(page.locator('fieldset[data-step="2"]')).toBeHidden();
  await page.getByRole("button", { name: "التالي" }).click();
  await expect(page.getByText("اكتب اسمك (حرفين على الأقل).")).toBeVisible(); // التحقق من الحقول
  await page.getByLabel("الاسم").fill("سارة الاختبار");
  await page.locator("#phone").fill("512345678");
  await pickRadio(page, "gender", "أنثى");
  await page.locator("#age").fill("29");
  await page.getByRole("button", { name: "التالي" }).click();
  await expect(page.locator('fieldset[data-step="1"]')).toBeHidden();
  await pickRadio(page, "goal", "لياقة وقوة");
  await pickRadio(page, "level", "مبتدئ · أقل من 6 أشهر");
  await pickRadio(page, "place", "البيت");
  await page.locator('input[name="equip"][value="دمبلز"]').check({ force: true });
  await page.locator("#days").selectOption("3 أيام");
  await page.locator("#duration").selectOption("ساعة");
  await page.getByRole("button", { name: "التالي" }).click();
  await pickRadio(page, "injury", "نعم");
  await pickRadio(page, "condition", "لا");
  await page.locator("#health_notes").fill("ألم خفيف أسفل الظهر مع الانحناء");
  await page.locator('input[name="health_ack"]').check();
  await page.getByRole("button", { name: "التالي" }).click();
  await page.locator("#weight").fill("68.5");
  await page.locator("#height").fill("164");
  await page.locator("#calories").selectOption("أعرف الأساسيات");
  await page.getByRole("button", { name: "التالي" }).click();
  await page.locator("#expectations").fill("متابعة أسبوعية واضحة وتعديل البرنامج حسب تقدمي");
  await page.locator("#media").selectOption("لا، أفضّل الخصوصية");
  await page.locator('input[name="consent_terms"]').check();
  await page.locator('input[name="consent_wa"]').check();
  await page.getByRole("button", { name: "أرسل الاستبيان وانتقل للدفع" }).click();

  // ---------- 4) صفحة التأكيد ----------
  await expect(page).toHaveURL(/\/account\/orders\/NAV-\d{6}-[A-Z0-9]{5}\?new=1/);
  const orderNo = page.url().match(/NAV-\d{6}-[A-Z0-9]{5}/)![0];
  await expect(page.getByText("وصل استبيانك وتم إنشاء طلبك.")).toBeVisible();
  await expect(page.getByTestId("order-status")).toHaveText("بانتظار الدفع");
  await expect(page.getByText("SA1280000139608016245411")).toBeVisible();
  await noHorizontalScroll(page);

  // البيانات الصحية مخزنة منفصلة ولم تُرسل في أي بريد
  const mails = await db.query("SELECT subject, body FROM dev_mailbox WHERE body LIKE '%' || $1 || '%'", [orderNo]);
  expect(mails.rowCount).toBeGreaterThan(0);
  for (const m of mails.rows) expect(m.body).not.toContain("الظهر");

  // ---------- 5) رفع الإيصال (ليس دفعاً) ----------
  const png = await sharp({ create: { width: 400, height: 600, channels: 3, background: "#eeeeee" } }).png().toBuffer();
  await page.setInputFiles("#proof", { name: "receipt.png", mimeType: "image/png", buffer: png });
  await page.getByRole("button", { name: "رفع الإيصال" }).click();
  await expect(page.getByTestId("order-status")).toHaveText("جارٍ التحقق من الدفع");
  await expect(page.getByText("وصلنا إيصالك")).toBeVisible();
  await expect(page.locator("#proof")).toHaveCount(0); // لا يمكن رفع إيصال ثانٍ أثناء المراجعة

  const proofId = (await db.query("SELECT p.id FROM payment_proofs p JOIN orders o ON o.id = p.order_id WHERE o.order_no = $1", [orderNo])).rows[0].id;

  // ---------- 6) الصلاحيات ----------
  await page.goto("/admin");
  await expect(page).toHaveURL(/\/account\?denied=1/);
  const anon = await browser.newContext();
  const anonRes = await anon.request.get(`/api/files/proof/${proofId}`);
  expect(anonRes.status()).toBe(401);
  await anon.close();

  const other = await newUserPage(browser, project);
  await other.goto("/login");
  await login(other, otherEmail);
  await expect(other).toHaveURL(/\/account/);
  const r404 = await other.goto(`/account/orders/${orderNo}`);
  expect(r404?.status()).toBe(404);
  const fileRes = await other.request.get(`/api/files/proof/${proofId}`);
  expect(fileRes.status()).toBe(404);
  await other.context().close();

  // ---------- 7) المدربة تعتمد الدفع وتضيف الملفات ----------
  const coach = await newUserPage(browser, project);
  await coach.goto("/login?next=/admin");
  await login(coach, coachEmail);
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  await coach.goto(`/admin/orders?q=${orderNo}`);
  await noHorizontalScroll(coach);
  await coach.getByRole("link", { name: orderNo }).click();
  await expect(coach.getByText("تحتاج مراعاة")).toBeVisible(); // تنبيه البيانات الصحية للمدربة فقط
  await expect(coach.getByText("ألم خفيف أسفل الظهر")).toBeVisible();
  // العمر الدقيق والسؤال الجديد يظهران للمدربة
  await expect(coach.getByText("29 سنة")).toBeVisible();
  await expect(coach.getByText("ماذا تتوقع مني أثناء التدريب؟")).toBeVisible();
  await expect(coach.getByText("متابعة أسبوعية واضحة وتعديل البرنامج حسب تقدمي")).toBeVisible();
  await expect(coach.getByText("68.5 كغ")).toBeVisible();
  // تغيير الحالة من الشريط الثابت: قائمة الانتقالات المسموحة فقط
  const bar = coach.getByTestId("status-bar");
  await bar.getByLabel("تغيير الحالة إلى").selectOption({ label: "اعتماد الدفع" });
  await bar.getByRole("button", { name: "تحديث" }).click();
  await expect(coach.locator(".status").first()).not.toHaveText("قيد الإعداد"); // مربع تأكيد وصول المبلغ إلزامي
  await bar.locator('input[name="bank_confirmed"]').check();
  await bar.getByRole("button", { name: "تحديث" }).click();
  await expect(coach.locator(".status").first()).toHaveText("قيد الإعداد");
  await expect(bar.getByLabel("تغيير الحالة إلى")).not.toContainText("اعتماد الدفع");

  const add = coach.locator("form", { has: coach.getByRole("button", { name: "إضافة", exact: true }) });
  await add.locator('input[name="title"]').fill("ملف البرنامج — الشهر الأول");
  await add.locator('input[name="url"]').fill("https://example.com/program-file");
  await add.getByRole("button", { name: "إضافة", exact: true }).click();
  await expect(coach.getByText("تمت الإضافة")).toBeVisible();

  // العميل لا يرى الملف قبل تفعيل البرنامج
  await page.goto(`/account/orders/${orderNo}`);
  await expect(page.getByTestId("order-status")).toHaveText("قيد الإعداد");
  await expect(page.getByText("ملف البرنامج — الشهر الأول")).toHaveCount(0);

  await coach.reload();
  await coach.getByTestId("status-bar").getByLabel("تغيير الحالة إلى").selectOption({ label: "تفعيل البرنامج" });
  await coach.getByTestId("status-bar").getByRole("button", { name: "تحديث" }).click();
  await expect(coach.locator(".status").first()).toHaveText("البرنامج نشط");
  // تاريخ البدء يُضبط تلقائياً عند التفعيل، والنهاية = البدء + مدة الباقة
  const { rows: [sub] } = await db.query("SELECT sub_start_at, sub_end_at, months FROM orders WHERE order_no = $1", [orderNo]);
  expect(sub.sub_start_at).not.toBeNull();
  const months = (new Date(sub.sub_end_at).getUTCFullYear() - new Date(sub.sub_start_at).getUTCFullYear()) * 12 + new Date(sub.sub_end_at).getUTCMonth() - new Date(sub.sub_start_at).getUTCMonth();
  expect(months).toBe(sub.months);
  await expect(coach.getByRole("term").filter({ hasText: "تاريخ البدء" })).toBeVisible();
  // إشعار تغيّر الحالة مسجّل، والملف المضاف قبل التفعيل لم يُرسل عنه إشعار
  const logs = (await db.query(
    `SELECT n.kind, n.channel, n.status, n.body FROM notification_log n JOIN orders o ON o.id = n.order_id WHERE o.order_no = $1`, [orderNo])).rows;
  expect(logs.some((l) => l.kind === "status" && l.channel === "email" && l.status === "simulated")).toBe(true);
  expect(logs.some((l) => l.kind === "status" && l.channel === "whatsapp" && l.status === "skipped")).toBe(true);
  expect(logs.some((l) => l.kind === "deliverable")).toBe(false);
  for (const l of logs) expect(l.body).not.toContain("الظهر");

  // ---------- 8) العميل: الملفات + المراجعة الأسبوعية + التقييم ----------
  await page.reload();
  await expect(page.getByTestId("order-status")).toHaveText("البرنامج نشط");
  await expect(page.getByRole("link", { name: "ملف البرنامج — الشهر الأول" })).toBeVisible();
  await expect(page.getByTestId("sub-start")).toBeVisible();
  await expect(page.getByTestId("sub-end")).toBeVisible();
  await page.locator('textarea[name="a"]').first().fill("الحركة اليومية أفضل والنوم أحسن");
  await page.getByRole("button", { name: "أرسل المراجعة" }).click();
  await expect(page.getByText("وصلت مراجعتك")).toBeVisible();

  const reviewText = `تجربة ممتازة ومتابعة دقيقة كل أسبوع (${project})`;
  await page.locator("#rbody").fill("اتصلوا علي 0555 123 456");
  await page.locator('input[name="consent"]').check();
  await page.getByRole("button", { name: "أرسل التقييم" }).click();
  await expect(page.getByText("احذف أرقام الهواتف")).toBeVisible();
  await page.locator("#rbody").fill(reviewText);
  await page.getByRole("button", { name: "أرسل التقييم" }).click();
  await expect(page.getByText("حالة تقييمك: قيد المراجعة")).toBeVisible();

  await page.goto("/reviews");
  await expect(page.getByText(reviewText)).toHaveCount(0); // لا يُنشر قبل المراجعة

  // ---------- 9) المدربة تعتمد التقييم ----------
  await coach.goto("/admin/reviews");
  const card = coach.locator(".card", { hasText: reviewText });
  await card.locator('input[name="checked"]').check();
  await card.getByRole("button", { name: "اعتماد النشر" }).click();
  await expect(coach.locator(".card", { hasText: reviewText })).toHaveCount(0); // خرج من قائمة «بانتظار المراجعة»
  await page.goto("/reviews");
  await expect(page.getByText(reviewText)).toBeVisible();
  await expect(page.getByText("سارة", { exact: true }).first()).toBeVisible(); // الاسم الأول فقط (الافتراضي)

  // ---------- 10) مقطع YouTube Shorts من لوحة الإدارة ----------
  await coach.goto("/admin/content");
  const vid = coach.locator("form", { has: coach.locator('input[name="key"][value="intro_video"]') });
  await vid.locator('input[name="url"]').fill("https://example.com/not-youtube");
  await vid.getByRole("button", { name: "حفظ" }).click();
  await expect(coach.getByText("الرابط غير صالح")).toBeVisible();
  await vid.locator('input[name="url"]').fill("https://youtube.com/shorts/aBcDeFgHiJk");
  await vid.getByRole("button", { name: "حفظ" }).click();
  await expect(coach.getByText("تم الحفظ.").first()).toBeVisible();

  await page.goto("/");
  await expect(page.locator("#intro")).toBeVisible();
  await expect(page.locator("#intro iframe")).toHaveCount(0); // لا تشغيل تلقائي
  await page.getByRole("button", { name: /تشغيل المقطع/ }).click();
  await expect(page.locator("#intro iframe")).toHaveAttribute("src", /youtube-nocookie\.com\/embed\/aBcDeFgHiJk/);

  // إزالة الرابط تُخفي القسم مجدداً
  await coach.goto("/admin/content");
  const vid2 = coach.locator("form", { has: coach.locator('input[name="key"][value="intro_video"]') });
  await vid2.locator('input[name="url"]').fill("");
  await vid2.getByRole("button", { name: "حفظ" }).click();
  await expect(coach.getByText("تم الحفظ.").first()).toBeVisible();
  await page.goto("/");
  await expect(page.locator("#intro")).toHaveCount(0);

  // ---------- 11) مناطق اللمس على الجوال ----------
  if (project === "iphone") {
    await page.goto("/programs/intensive");
    const small = await page.evaluate(() =>
      Array.from(document.querySelectorAll<HTMLElement>("main a.btn, main button, .site-header summary"))
        .filter((e) => e.offsetParent !== null)
        .map((e) => ({ t: e.textContent?.trim().slice(0, 30), h: e.getBoundingClientRect().height }))
        .filter((x) => x.h < 44));
    expect(small, JSON.stringify(small)).toEqual([]);
  }

  await coach.context().close();
  await page.context().close();
});

test("رفض الملفات غير المسموحة وحماية المسارات", async ({ browser }, info) => {
  const page = await newUserPage(browser, info.project.name + "-sec");
  // مسارات محمية بدون دخول
  for (const path of ["/account", "/admin", "/checkout/int1"]) {
    await page.goto(path);
    await expect(page).toHaveURL(/\/login\?next=/);
  }
  // إعادة التوجيه بعد الدخول لا تسمح بمواقع خارجية
  const email = `sec-${info.project.name}@e2e.test`;
  await page.goto("/login?next=//evil.example.com");
  await login(page, email);
  await expect(page).toHaveURL(/localhost:3100\/account/);

  // ملف نصي بامتداد صورة يُرفض على الخادم
  await page.goto("/checkout/diy");
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const orderNo = (await db.query(
    `SELECT app.new_order_no() AS no`)).rows[0].no as string;
  await db.query(
    `INSERT INTO orders (order_no, user_id, category, product_name, offer_label, list_price_halalas, amount_due_halalas, status, contact_name, contact_phone, idempotency_key, is_demo)
     VALUES ($1, $2, 'files', 'منتج اختبار', 'دفعة واحدة', 19900, 19900, 'awaiting_payment', 'اختبار', '+966500000000', $3, true)`,
    [orderNo, u.id, `k-${orderNo}-xxxxxxxx`]);
  await page.goto(`/account/orders/${orderNo}`);
  await page.setInputFiles("#proof", { name: "fake.png", mimeType: "image/png", buffer: Buffer.from("<script>alert(1)</script>") });
  await page.getByRole("button", { name: "رفع الإيصال" }).click();
  await expect(page.getByText("نوع الملف غير مسموح")).toBeVisible();
  await expect(page.getByTestId("order-status")).toHaveText("بانتظار الدفع");
  await page.context().close();
});

test("المدربة تخفي طلباً من القائمة وتحذف الملغى نهائياً", async ({ browser }, info) => {
  const project = info.project.name;
  const coachEmail = `coach2-${project}@e2e.test`;
  const coach = await newUserPage(browser, project + "-arch");
  await coach.goto("/login?next=/admin");
  await login(coach, coachEmail);
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [coachEmail]);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  await db.query(
    `INSERT INTO orders (order_no, user_id, category, product_name, offer_label, list_price_halalas, amount_due_halalas, status, contact_name, contact_phone, idempotency_key, is_demo)
     VALUES ($1, $2, 'files', 'منتج اختبار', 'دفعة واحدة', 19900, 19900, 'awaiting_payment', 'اختبار', '+966500000000', $3, true)`,
    [orderNo, u.id, `k-${orderNo}-archive`]);

  await coach.goto(`/admin/orders?q=${orderNo}`);
  const row = coach.locator("tr", { hasText: orderNo });
  await row.getByRole("button", { name: "إخفاء" }).click();
  await expect(coach.locator("tr", { hasText: orderNo })).toHaveCount(0);
  await coach.goto(`/admin/orders?view=archived&q=${orderNo}`);
  await expect(coach.locator("tr", { hasText: orderNo })).toHaveCount(1);

  await coach.goto(`/admin/orders/${orderNo}`);
  await expect(coach.getByText("الحذف النهائي متاح للطلبات الملغاة فقط.")).toBeVisible();
  const cancel = coach.getByTestId("status-bar");
  await cancel.getByLabel("تغيير الحالة إلى").selectOption({ label: "إلغاء الطلب" });
  await cancel.getByLabel("السبب (يظهر للعميل)").fill("طلب تجريبي");
  coach.once("dialog", (d) => d.accept());
  await cancel.getByRole("button", { name: "تحديث" }).click();
  await expect(coach.locator(".status").first()).toHaveText("ملغي");
  await coach.getByText("حذف نهائي").first().click();
  const del = coach.locator("form", { has: coach.getByRole("button", { name: "حذف نهائي" }) });
  await del.locator('input[name="confirm"]').fill(orderNo);
  await del.getByRole("button", { name: "حذف نهائي" }).click();
  await expect(coach).toHaveURL(/\/admin\/orders\?deleted=1/);
  expect((await db.query("SELECT count(*)::int n FROM orders WHERE order_no = $1", [orderNo])).rows[0].n).toBe(0);
  await coach.context().close();
});

test("قائمة الجوال تُغلق بعد اختيار صفحة", async ({ browser }, info) => {
  test.skip(info.project.name !== "iphone", "القائمة المنسدلة للجوال فقط");
  const page = await newUserPage(browser, "menu");
  await page.goto("/");
  await page.getByLabel("فتح القائمة").click();
  const panel = page.locator(".menu-panel");
  await expect(panel).toBeVisible();
  await panel.getByRole("link", { name: "البرامج" }).click();
  await expect(page).toHaveURL(/\/programs$/);
  await expect(panel).toBeHidden();
  // الضغط خارج القائمة يغلقها أيضاً
  await page.getByLabel("فتح القائمة").click();
  await expect(panel).toBeVisible();
  const box = await panel.boundingBox();
  const vh = page.viewportSize()!.height;
  // خارج القائمة: الهامش الجانبي (القائمة تبعد 12px عن الحافة) أو تحتها إن وُجد مكان
  await page.mouse.click(4, Math.min(vh - 10, box!.y + box!.height + 40));
  await expect(panel).toBeHidden();
  // وزر Esc
  await page.getByLabel("فتح القائمة").click();
  await expect(panel).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(panel).toBeHidden();
  await page.context().close();
});
