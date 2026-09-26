// المتابعة بعد الاشتراك: ملاحظات المدربة، وسوم الباقات، صفحة الباقات والمتدربين، تواريخ الاشتراك،
// سجل المراجعات الأسبوعية، التذكيرات (المجدولة والفورية)، الإشعارات وسجلها، تفضيلات التواصل، القياسات الناقصة،
// دليل الإضافة للشاشة الرئيسية، ومسميات «الاستبيان». كل البيانات في قاعدة nav_e2e المنفصلة.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";

const OWNER = process.env.E2E_DATABASE_URL_OWNER ?? "postgres://nav_owner:nav_owner_dev@localhost:5432/nav_e2e";
const CRON_SECRET = "e2e-cron-secret-0123456789";
const db = new pg.Pool({ connectionString: OWNER, max: 2 });
test.afterAll(async () => { await db.end(); });

let ip = 50;
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
const logRows = async (orderNo: string) => (await db.query(
  `SELECT n.kind, n.channel, n.status, n.detail, n.body, n.occasion_key FROM notification_log n JOIN orders o ON o.id = n.order_id
    WHERE o.order_no = $1 ORDER BY n.id`, [orderNo])).rows;

/**
 * متدرب باشتراك نشط بدأ قبل 19 يوماً وينتهي بعد 7 أيام (بتوقيت الرياض)، يوم المراجعة = يوم البدء:
 *   الأسبوع 1: قبل 12 يوماً (فائت ← تعلّمه المدربة يدوياً)، الأسبوع 2: قبل 5 أيام (فائت، نافذته انتهت قبل 3 أيام)،
 *   الأسبوع 3: بعد يومين (الحالي). والاستبيان قديم: عمر كنطاق، بدون وزن وطول.
 */
async function seedTrainee(email: string, name: string) {
  const { rows: [u] } = await db.query(`SELECT id FROM "user" WHERE email = $1`, [email]);
  const { rows: [p] } = await db.query(
    `SELECT p.id, p.name, o.id AS offer_id, o.label, o.price_halalas FROM products p JOIN product_offers o ON o.product_id = p.id
      WHERE p.slug = 'intensive' AND o.months = 3`);
  const orderNo = (await db.query("SELECT app.new_order_no() AS no")).rows[0].no as string;
  const { rows: [o] } = await db.query(
    `WITH d AS (SELECT ((now() AT TIME ZONE 'Asia/Riyadh')::date - 19) AS start, ((now() AT TIME ZONE 'Asia/Riyadh')::date + 7) AS fin)
     INSERT INTO orders (order_no, user_id, product_id, offer_id, category, product_name, offer_label, months, list_price_halalas,
                         amount_due_halalas, status, contact_name, contact_phone, idempotency_key, paid_at,
                         sub_start_at, sub_end_at, review_weekday)
     SELECT $1, $2, $3, $4, 'follow', $5, $6, 3, $7, $7, 'active', $8, '+966512345678', $9, now(),
            (d.start + time '12:00') AT TIME ZONE 'Asia/Riyadh', (d.fin + time '12:00') AT TIME ZONE 'Asia/Riyadh', extract(dow FROM d.start)::smallint
       FROM d RETURNING id`,
    [orderNo, u.id, p.id, p.offer_id, p.name, p.label, p.price_halalas, name, `k-${orderNo}-follow`]);
  await db.query(
    `INSERT INTO intakes (order_id, user_id, answers, health, health_flag, media_consent, consent_terms_at, consent_whatsapp_at)
     VALUES ($1, $2, $3, $4, true, 'لا', now(), now())`,
    [o.id, u.id, JSON.stringify({ gender: "أنثى", age: "25 – 34", goal: "لياقة وقوة" }), JSON.stringify({ injury: "نعم", health_notes: "آلام في الركبة اليسرى" })]);
  return orderNo;
}

test("متابعة المشترك: الملاحظات، الباقات، الاشتراك، المراجعات، التذكيرات والإشعارات", async ({ browser }, info) => {
  const project = info.project.name;
  const traineeEmail = `trainee-${project}@e2e.test`;
  const coachEmail = `coach3-${project}@e2e.test`;
  const name = `نورة متابعة ${project}`;
  const secretNote = `ملاحظة-سرية-${project}-${Date.now()}`;

  const trainee = await newPage(browser, project + "-t");
  await login(trainee, traineeEmail);
  const orderNo = await seedTrainee(traineeEmail, name);

  const coach = await newPage(browser, project + "-c");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);

  // ---------- 1) ملاحظات خاصة: حفظ، مؤشر في القائمة، بحث ----------
  await coach.goto(`/admin/orders/${orderNo}`);
  await noHorizontalScroll(coach); // صفحة الطلب (مع جدول الأسابيع) لا تتجاوز عرض الجوال
  const notes = coach.getByTestId("admin-notes");
  // الملاحظات أعلى الصفحة قبل الإجراءات
  const [notesY, actionY] = await Promise.all([notes.boundingBox(), coach.getByRole("heading", { name: "الإجراء التالي" }).boundingBox()]);
  expect(notesY!.y).toBeLessThan(actionY!.y);
  await notes.getByLabel("ملاحظة جديدة").fill("ملاحظة أولى: بداية جيدة");
  await notes.getByRole("button", { name: "إضافة ملاحظة" }).click();
  await expect(notes.locator(".note-log li")).toHaveCount(1);
  await expect(notes.getByLabel("ملاحظة جديدة")).toHaveValue(""); // الحقل يُفرّغ بعد الإضافة
  await notes.getByLabel("ملاحظة جديدة").fill(secretNote);
  await notes.getByRole("button", { name: "إضافة ملاحظة" }).click();
  await expect(notes.locator(".note-log li")).toHaveCount(2);
  await expect(notes.locator(".note-log li").first()).toContainText(secretNote); // الأحدث أولاً
  await expect(notes.locator(".note-log li time").first()).toBeVisible();        // لكل ملاحظة تاريخها
  coach.once("dialog", (d) => d.accept());
  await notes.locator(".note-log li", { hasText: "ملاحظة أولى" }).getByRole("button", { name: "حذف" }).click();
  await expect(notes.locator(".note-log li")).toHaveCount(1);
  await coach.goto(`/admin/orders?q=${encodeURIComponent(secretNote)}`);
  const row = coach.locator("tr", { hasText: orderNo });
  await expect(row).toHaveCount(1); // البحث يشمل نص الملاحظة
  await expect(row.getByRole("img", { name: "توجد ملاحظة خاصة" })).toBeVisible();

  // ---------- 2) وسم الباقة والتصفية بها ----------
  await expect(row.locator(".ptag")).toContainText("المكثفة");
  await row.getByRole("link", { name: /تصفية حسب/ }).click();
  await expect(coach).toHaveURL(/pkg=[0-9a-f-]{36}/);
  await expect(coach.locator("tr", { hasText: orderNo })).toHaveCount(1);
  await expect(coach.locator("tbody .ptag").filter({ hasNotText: "المكثفة" })).toHaveCount(0);
  await noHorizontalScroll(coach);

  // ---------- 3) الباقات والمتدربين ----------
  await coach.goto("/admin/packages");
  await expect(coach.getByRole("heading", { level: 1 })).toContainText("الباقات والمتدربين");
  await coach.getByRole("link", { name: /قريب من الانتهاء: [1-9]/ }).first().click();
  await expect(coach.getByTestId("trainees")).toContainText(name);
  await coach.goto(`/admin/packages?q=${orderNo}`);
  await expect(coach.getByTestId("trainees")).toContainText(orderNo);
  await coach.goto(`/admin/packages?state=expired&q=${orderNo}`);
  await expect(coach.getByTestId("trainees")).not.toContainText(orderNo);
  await noHorizontalScroll(coach);

  // ---------- 4) صفحة الطلب: الاشتراك، الاستبيان القديم، الأسابيع ----------
  await coach.goto(`/admin/orders/${orderNo}`);
  await expect(coach.getByText("قريب من الانتهاء").first()).toBeVisible();
  await expect(coach.getByText("(نطاق من الاستبيان القديم)")).toBeVisible();
  await expect(coach.getByRole("button", { name: "اطلبي منه تحديثهما" })).toBeVisible();
  const week1 = coach.locator("tr", { has: coach.locator("td", { hasText: /^1$/ }) });
  await week1.getByRole("button", { name: "تعليم كمكتمل" }).click();
  await expect(week1).toContainText("(يدوي)");

  // ---------- 5) إعدادات التذكير: تذكير المراجعة قبل موعدها بيومين ----------
  await coach.goto("/admin/content#reminders");
  const rem = coach.locator("form", { has: coach.locator('input[name="key"][value="reminders"]') });
  await rem.locator('input[name="review_lead_days"]').fill("2");
  await rem.getByRole("button", { name: "حفظ إعدادات التذكير" }).click();
  await expect(rem.getByText("تم الحفظ.")).toBeVisible();

  // ---------- 6) تنبيهات داخلية للمدربة في الرئيسية ----------
  await coach.goto("/admin");
  const alerts = coach.getByTestId("coach-alerts");
  await expect(alerts.locator("li", { hasText: orderNo }).filter({ hasText: "الاشتراك ينتهي" })).toHaveCount(1);
  await expect(alerts.locator("li", { hasText: orderNo }).filter({ hasText: "لم تصل مراجعة الأسبوع 2" })).toHaveCount(1);
  await expect(alerts.locator("li", { hasText: orderNo }).filter({ hasText: "مراجعة الأسبوع 3" })).toHaveCount(1);
  await expect(alerts.locator("li", { hasText: orderNo }).filter({ hasText: "الوزن أو الطول" })).toHaveCount(1);

  // ---------- 7) التذكيرات المجدولة (نفس المسار الذي تستدعيه Netlify كل ساعة) ----------
  expect((await coach.request.post("/api/cron/reminders")).status()).toBe(401);
  expect((await coach.request.post("/api/cron/reminders", { headers: { "x-cron-secret": "wrong-secret-000000000000" } })).status()).toBe(401);
  const run = await coach.request.post("/api/cron/reminders", { headers: { "x-cron-secret": CRON_SECRET }, data: { ignore_quiet_hours: true } });
  expect(run.status()).toBe(200);
  let logs = await logRows(orderNo);
  for (const kind of ["sub_expiry", "review_upcoming", "review_missed"]) {
    expect(logs.find((l) => l.kind === kind && l.channel === "email")?.status, kind).toBe("simulated");
    expect(logs.find((l) => l.kind === kind && l.channel === "whatsapp")?.detail, kind).toContain("غير مفعّل");
  }
  const before = logs.length;
  await coach.request.post("/api/cron/reminders", { headers: { "x-cron-secret": CRON_SECRET }, data: { ignore_quiet_hours: true } });
  expect((await logRows(orderNo)).length).toBe(before); // لا تكرار لنفس المناسبة
  const mails = (await db.query("SELECT body FROM dev_mailbox WHERE recipient = $1", [traineeEmail])).rows.map((r) => r.body as string);
  expect(mails.some((b) => b.includes(`/account/orders/${orderNo}`))).toBe(true);
  for (const b of mails) expect(b).not.toContain("الركبة");

  // ---------- 8) المتدرب: التواريخ وسجل المراجعات ----------
  await trainee.goto(`/account/orders/${orderNo}`);
  await expect(trainee.getByTestId("sub-start")).toBeVisible();
  await expect(trainee.getByTestId("sub-end")).toBeVisible();
  const hist = trainee.getByTestId("review-history");
  await expect(hist.locator("li.wk").nth(0)).toContainText("✅");
  await expect(hist.locator("li.wk").nth(1)).toHaveClass(/missed/);
  await expect(hist.locator("li.wk").nth(2)).toContainText("⏳");
  await expect(trainee.getByTestId("review-window")).toContainText("المراجعة مفتوحة من");
  await expect(trainee.getByTestId("review-missed")).toBeVisible();
  expect(await trainee.content()).not.toContain(secretNote); // الملاحظات الخاصة لا تصل للمتدرب إطلاقاً
  await noHorizontalScroll(trainee);

  // ---------- 9) استكمال القياسات ----------
  const mf = trainee.getByTestId("measurements-form");
  await mf.getByLabel("الوزن (كغ)").fill("20");
  await mf.getByLabel("الطول (سم)").fill("165");
  await mf.getByRole("button", { name: "حفظ القياسات" }).click();
  // المتصفح يمنع الإرسال خارج النطاق (والخادم يرفضه أيضاً — tests/db)
  expect(await mf.getByLabel("الوزن (كغ)").evaluate((e: HTMLInputElement) => e.validity.rangeUnderflow)).toBe(true);
  await expect(trainee.getByText("تم تحديث القياسات")).toHaveCount(0);
  await mf.getByLabel("الوزن (كغ)").fill("62");
  await mf.getByRole("button", { name: "حفظ القياسات" }).click();
  await expect(trainee.getByTestId("measurements-form")).toHaveCount(0); // اكتملت البيانات فاختفى النموذج
  const { rows: [hm] } = await db.query("SELECT i.health FROM intakes i JOIN orders o ON o.id = i.order_id WHERE o.order_no = $1", [orderNo]);
  expect(Number(hm.health.weight)).toBe(62);
  expect(hm.health.health_notes).toBe("آلام في الركبة اليسرى"); // لم تُمس بقية البيانات الصحية
  await coach.goto(`/admin/orders/${orderNo}`);
  await expect(coach.getByRole("button", { name: "اطلبي منه تحديثهما" })).toHaveCount(0);
  await expect(coach.getByText("62 كغ")).toBeVisible();

  // ---------- 10) «إرسال تنبيه المراجعة الآن»: معاينة، تأكيد بالنص، نتيجة لكل قناة، مهلة ----------
  const preview = (await coach.getByTestId("review-preview").textContent())!.trim();
  expect(preview).toContain("المراجعة مفتوحة من");
  let dialogText = "";
  coach.once("dialog", (d) => { dialogText = d.message(); d.accept(); });
  await coach.getByRole("button", { name: "إرسال تنبيه المراجعة الآن" }).click();
  await expect(coach.getByText(/البريد — محاكاة/)).toBeVisible();
  await expect(coach.getByText(/واتساب — لم يُرسل/)).toBeVisible();
  expect(dialogText).toContain(preview);
  coach.once("dialog", (d) => d.accept());
  await coach.getByRole("button", { name: "إرسال تنبيه المراجعة الآن" }).click();
  await expect(coach.getByText(/أُرسل تنبيه لهذا المتدرب قبل أقل من/)).toBeVisible();
  logs = await logRows(orderNo);
  expect(logs.filter((l) => l.kind === "review_manual" && l.channel === "email")).toHaveLength(1);
  expect(logs.find((l) => l.kind === "review_manual" && l.channel === "email")!.body).toContain(preview);

  // ---------- 11) تفضيلات التواصل تُحترم ----------
  await trainee.goto("/account");
  const prefs = trainee.getByTestId("prefs-form");
  await prefs.getByLabel("إشعارات البريد الإلكتروني").uncheck();
  await prefs.getByRole("button", { name: "حفظ التفضيلات" }).click();
  await expect(trainee.getByText("تم حفظ تفضيلات التواصل.")).toBeVisible();

  // ---------- 12) إشعار إضافة رابط ورد على المراجعة ----------
  await coach.reload();
  const add = coach.locator("form", { has: coach.getByRole("button", { name: "إضافة", exact: true }) });
  await add.locator('input[name="title"]').fill("فيديو تصحيح التكنيك");
  await add.locator('input[name="url"]').fill("https://example.com/technique");
  await add.getByRole("button", { name: "إضافة", exact: true }).click();
  await expect(coach.getByText(/تمت الإضافة/)).toBeVisible();
  logs = await logRows(orderNo);
  const del = logs.find((l) => l.kind === "deliverable" && l.channel === "email");
  expect(del?.status).toBe("skipped");
  expect(del?.detail).toContain("أوقف");

  await trainee.goto(`/account/orders/${orderNo}`);
  await trainee.locator('textarea[name="a"]').first().fill("التزمت بالتمارين هذا الأسبوع");
  await trainee.getByRole("button", { name: "أرسل المراجعة" }).click();
  await expect(trainee.getByText("وصلت مراجعتك")).toBeVisible();
  await coach.reload();
  await coach.getByText(/بانتظار الرد|مراجعة/).first().click().catch(() => {});
  const reply = coach.locator("form", { has: coach.getByRole("button", { name: "إرسال الرد" }) }).first();
  await reply.locator('textarea[name="reply"]').fill("ممتاز! نزيد الأوزان الأسبوع الجاي.");
  await reply.getByRole("button", { name: "إرسال الرد" }).click();
  await expect(coach.getByText(/الإشعار:/).first()).toBeVisible();
  logs = await logRows(orderNo);
  expect(logs.some((l) => l.kind === "checkin_reply" && l.channel === "email")).toBe(true);
  for (const l of logs) expect(l.body).not.toContain("الركبة");

  await trainee.goto(`/account/orders/${orderNo}`);
  await expect(trainee.getByTestId("review-history").locator("li.wk").nth(2)).toContainText("✅"); // مراجعة من الموقع تُحتسب

  await coach.context().close();
  await trainee.context().close();
});

test("الاستبيان: العمر والقياسات وسؤال التوقعات إلزامية", async ({ browser }, info) => {
  const page = await newPage(browser, info.project.name + "-v");
  await login(page, `valid-${info.project.name}@e2e.test`, "/checkout/int1");
  await expect(page.getByText("استبيان المتدرب").first()).toBeVisible();
  await page.getByLabel("الاسم").fill("اختبار التحقق");
  await page.locator("#phone").fill("512345678");
  await page.locator('input[name="gender"][value="أنثى"]').locator("xpath=..").click();
  for (const bad of ["9", "91", "25.5"]) {
    await page.locator("#age").fill(bad);
    await page.getByRole("button", { name: "التالي" }).click();
    await expect(page.getByText("اكتب عمرك رقماً صحيحاً بين 10 و 90.")).toBeVisible();
  }
  await page.locator("#age").fill("16");
  await page.getByRole("button", { name: "التالي" }).click();
  await expect(page.getByText("للأعمار أقل من 18 نحتاج تأكيد موافقة ولي الأمر.")).toBeVisible();
  await page.locator("#age").fill("30");
  await page.getByRole("button", { name: "التالي" }).click();
  await expect(page.locator('fieldset[data-step="2"]')).toBeVisible();

  // تحقق الخادم لنفس القواعد مغطى في tests/unit/intake.test.mts
  await page.context().close();
});

test("دليل إضافة الموقع للشاشة الرئيسية وملف التطبيق", async ({ browser }, info) => {
  const page = await newPage(browser, info.project.name + "-i");
  await page.goto("/install");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("أضف الموقع كتطبيق على جوالك");
  await expect(page.getByRole("heading", { name: /iPhone/ })).toBeVisible();
  await expect(page.getByRole("heading", { name: /أندرويد/ })).toBeVisible();
  await expect(page.locator(".install-steps li")).toHaveCount(6);
  await expect(page.getByText("«إضافة إلى الشاشة الرئيسية»").first()).toBeVisible();
  await noHorizontalScroll(page);
  const manifest = await (await page.request.get("/manifest.webmanifest")).json();
  expect(manifest.start_url).toBe("/account");
  expect(manifest.display).toBe("standalone");
  for (const icon of manifest.icons) expect((await page.request.get(icon.src)).status()).toBe(200);
  expect((await page.request.get("/apple-icon.png")).status()).toBe(200);

  await login(page, `install-${info.project.name}@e2e.test`);
  await page.getByTestId("install-link").click();
  await expect(page).toHaveURL(/\/install$/);
  await page.context().close();
});

test("«التقييم» يبقى للتقييمات العامة فقط", async ({ browser }, info) => {
  test.skip(info.project.name !== "desktop", "فحص نصوص فقط");
  const page = await newPage(browser, "words");
  for (const path of ["/programs", "/faq", "/"]) {
    await page.goto(path);
    const text = await page.locator("main").innerText();
    for (const old of ["عبّي التقييم", "بعد التقييم", "تعبئة التقييم", "تقييم المتدرب", "تقييم مفصل"]) expect(text, `${path}: ${old}`).not.toContain(old);
  }
  await page.goto("/reviews");
  await expect(page.getByRole("heading", { level: 1 })).toContainText(/تقييم|تجارب/);
  await page.context().close();
});

test("الأعضاء المسجلون وإضافة برنامج يدوياً بدون استبيان", async ({ browser }, info) => {
  const project = info.project.name;
  const coachEmail = `coach4-${project}@e2e.test`;
  const leadEmail = `lead-${project}@e2e.test`;        // سجّل بدون طلب
  const manualEmail = `manual-${project}@e2e.test`;    // لا يملك حساباً، تنشئه المدربة
  const name = `ريم يدوي ${project}`;

  const lead = await newPage(browser, project + "-l");
  await login(lead, leadEmail);
  await lead.context().close();

  const coach = await newPage(browser, project + "-c4");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);

  // ---------- الأعضاء ----------
  await coach.goto("/admin/members?view=no_orders");
  await expect(coach.getByRole("heading", { level: 1 })).toHaveText("الأعضاء المسجلون");
  await expect(coach.getByTestId("members")).toContainText(leadEmail);
  await expect(coach.getByTestId("members")).not.toContainText(coachEmail); // الحسابات الإدارية لا تظهر
  await noHorizontalScroll(coach);

  // ---------- إضافة برنامج يدوياً لبريد جديد ----------
  await coach.goto("/admin/orders/new");
  await coach.getByLabel("بريد المتدرب").fill(manualEmail);
  await coach.getByLabel("الاسم").fill(name);
  const sku = (await coach.locator("#m-sku option").filter({ hasText: "المكثفة — 3 أشهر" }).first().getAttribute("value"))!;
  await coach.locator("#m-sku").selectOption(sku);
  await coach.getByLabel("المبلغ بالريال").fill("0");
  await noHorizontalScroll(coach);
  await coach.getByRole("button", { name: "إنشاء الطلب" }).click();
  await expect(coach).toHaveURL(/\/admin\/orders\/NAV-[\w-]+\?created=1/);
  const orderNo = coach.url().match(/NAV-\d{6}-[A-Z0-9]{5}/)![0];
  await expect(coach.getByText("تم إنشاء الطلب يدوياً")).toBeVisible();
  await expect(coach.locator(".status").first()).toHaveText("البرنامج نشط");

  const add = coach.locator("form", { has: coach.getByRole("button", { name: "إضافة", exact: true }) });
  await add.locator('input[name="title"]').fill("جدول ريم — الشهر الأول");
  await add.locator('input[name="url"]').fill("https://example.com/manual-plan");
  await add.getByRole("button", { name: "إضافة", exact: true }).click();
  await expect(coach.getByText(/تمت الإضافة/)).toBeVisible();

  await coach.goto(`/admin/orders?q=${orderNo}`);
  await expect(coach.locator("tr", { hasText: orderNo })).toContainText("يدوي");
  const mail = await db.query("SELECT body FROM dev_mailbox WHERE recipient = $1 AND body LIKE '%' || $2 || '%'", [manualEmail, orderNo]);
  expect(mail.rowCount).toBeGreaterThan(0);

  // ---------- المتدرب يدخل ببريده ويجد برنامجه وملفه ----------
  const trainee = await newPage(browser, project + "-m");
  await login(trainee, manualEmail);
  await expect(trainee.getByRole("link", { name: /الباقة المكثفة/ })).toBeVisible();
  await trainee.goto(`/account/orders/${orderNo}`);
  await expect(trainee.getByTestId("order-status")).toHaveText("البرنامج نشط");
  await expect(trainee.getByRole("link", { name: "جدول ريم — الشهر الأول" })).toBeVisible();
  await expect(trainee.getByTestId("sub-start")).toBeVisible();
  await expect(trainee.getByTestId("measurements-form")).toHaveCount(0); // لا استبيان ← لا يُطلب منه شيء
  await trainee.context().close();

  await coach.goto(`/admin/members?q=${manualEmail}`);
  await expect(coach.getByTestId("members")).toContainText("1 طلب");
  await coach.context().close();
});
