// المتابعة بعد الاشتراك: ملاحظات المدربة، وسوم الباقات، صفحة الباقات والمتدربين، تواريخ الاشتراك،
// سجل المراجعات الأسبوعية، التذكيرات (المجدولة والفورية)، الإشعارات وسجلها، تفضيلات التواصل، القياسات الناقصة،
// دليل الإضافة للشاشة الرئيسية، ومسميات «الاستبيان». كل البيانات في قاعدة nav_e2e المنفصلة.
import { test, expect, type Page, type Browser } from "@playwright/test";
import pg from "pg";
import { readFileSync } from "node:fs";

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
  await expect(coach.getByTestId("intake").locator("summary")).toContainText("قياسات ناقصة");
  await coach.getByTestId("intake").locator("summary").click();
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
  // قرب انتهاء الاشتراك انتقل إلى قائمة «اشتراكات قربت تنتهي»
  await expect(coach.getByTestId("dash-ending").locator("li", { has: coach.locator(`a[href="/admin/orders/${orderNo}"]`) })).toHaveCount(1);
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
  await expect(coach.getByTestId("intake").locator("summary")).not.toContainText("قياسات ناقصة");
  await coach.getByTestId("intake").locator("summary").click();
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
  // الباقة مفعّل فيها «مراجعة بالفيديو» ← تظهر خانة رابط الفيديو مع الرد
  await db.query(`UPDATE products SET video_review = true WHERE slug = 'intensive'`);
  await coach.reload();
  await coach.getByText(/بانتظار الرد|مراجعة/).first().click().catch(() => {});
  const reply = coach.locator("form", { has: coach.getByRole("button", { name: "إرسال الرد" }) }).first();
  await reply.locator('textarea[name="reply"]').fill("ممتاز! نزيد الأوزان الأسبوع الجاي.");
  await reply.getByLabel("🎥 رابط فيديو شرح المراجعة (اختياري)").fill("http://youtu.be/bad");
  await reply.getByRole("button", { name: "إرسال الرد" }).click();
  await expect(reply.getByText("رابط الفيديو لازم يبدأ بـ https://")).toBeVisible();
  await reply.getByLabel("🎥 رابط فيديو شرح المراجعة (اختياري)").fill("https://youtu.be/rvWeek1abcd");
  await reply.getByRole("button", { name: "إرسال الرد" }).click();
  await expect(coach.getByText(/الإشعار:/).first()).toBeVisible();
  logs = await logRows(orderNo);
  expect(logs.some((l) => l.kind === "checkin_reply" && l.channel === "email")).toBe(true);
  for (const l of logs) expect(l.body).not.toContain("الركبة");

  await trainee.goto(`/account/orders/${orderNo}`);
  await expect(trainee.getByTestId("review-history").locator("li.wk").nth(2)).toContainText("✅"); // مراجعة من الموقع تُحتسب
  // المتدرب يشوف رابط فيديو شرح المراجعة مع الرد
  await trainee.getByText(/وصل الرد 🎥/).first().click();
  // الفيديو يشتغل داخل الموقع في نافذة منبثقة
  await trainee.getByTestId("checkin-video").first().click();
  await expect(trainee.getByTestId("video-iframe")).toHaveAttribute("src", /youtube-nocookie\.com\/embed\/rvWeek1abcd/);
  await trainee.getByRole("button", { name: "إغلاق الفيديو" }).click();
  await expect(trainee.getByTestId("video-iframe")).toHaveCount(0);

  // رسالة من المدربة للمتدرب: تظهر في صفحة طلبه، والتنبيه بدون نص الرسالة
  await coach.goto(`/admin/orders/${orderNo}`);
  const msg = coach.getByTestId("coach-message");
  await msg.getByLabel("الرسالة").fill("خففي الكارديو هذا الأسبوع وركزي على النوم.");
  await msg.getByRole("button", { name: "إرسال للمتدرب" }).click();
  await expect(msg.getByText(/أُرسلت الرسالة/)).toBeVisible();
  logs = await logRows(orderNo);
  const m = logs.find((l) => l.kind === "coach_message" && l.channel === "email");
  expect(m).toBeTruthy();
  expect(m!.body).not.toContain("الكارديو");
  await trainee.goto(`/account/orders/${orderNo}`);
  await expect(trainee.getByTestId("coach-messages")).toContainText("خففي الكارديو هذا الأسبوع");
  await noHorizontalScroll(trainee);

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
  // الطلب الفعّال يظهر في «برنامجي» (وما يتكرر في «طلباتي»)
  await expect(trainee.getByTestId("my-program")).toContainText("الباقة المكثفة");
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

test("حاسبة السعرات: توازن الطاقة (معادلة Henselmans)، التحقق، والنتائج", async ({ browser }, info) => {
  const page = await newPage(browser, info.project.name + "-calc");
  await page.goto("/");
  // موجودة في آخر الصفحة الرئيسية
  await expect(page.locator("#calculator").getByRole("button", { name: "احسب السعرات" })).toBeVisible();
  if (await page.getByLabel("فتح القائمة").isVisible()) {
    await page.getByLabel("فتح القائمة").click();
    await page.locator(".menu-panel").getByRole("link", { name: "حاسبة السعرات" }).click();
  } else {
    await page.locator(".nav").getByRole("link", { name: "حاسبة السعرات" }).click();
  }
  await expect(page).toHaveURL(/\/calculator$/);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("حاسبة السعرات");
  await noHorizontalScroll(page);

  // ---------- حاسبة السعرات اليومية: مثال ملف Henselmans (Cunningham) ----------
  await page.fill("#i-weight", "80");
  await page.getByRole("button", { name: "احسب السعرات", exact: true }).click();
  await expect(page.getByText("اكتب نسبة الدهون.")).toBeVisible();
  await page.fill("#i-bodyFat", "15");
  await page.getByRole("button", { name: "احسب السعرات", exact: true }).click(); // الافتراضي: نشاط 1.0، 60 دقيقة، 4 أيام، تنشيف 0.8
  await expect(page.getByTestId("intake-target")).toHaveText("2,029");
  await expect(page.getByTestId("intake-maintenance")).toHaveText("2,536");
  await expect(page.getByTestId("intake-bmr")).toHaveText("1,839");
  await expect(page.getByTestId("intake-training-day")).toHaveText("2,226");
  await expect(page.getByTestId("intake-rest-day")).toHaveText("1,765");
  // الماكروز: بروتين معتدل 1.6 غ/كغ ودهون 0.8 غ/كغ من 80 كغ = 128 و 64، والكارب الباقي من السعرات
  const row = (id: string) => page.getByTestId(id).locator("b.num");
  await expect(row("macros-avg")).toHaveText(["128", "235", "64"]);       // (2029 − 512 − 576) ÷ 4
  await expect(row("macros-training")).toHaveText(["128", "285", "64"]);  // (2226 − 1088) ÷ 4 = 284.5
  await expect(row("macros-rest")).toHaveText(["128", "169", "64"]);      // (1765 − 1088) ÷ 4
  await page.selectOption("#i-mp", "high");                               // عالي 2.2 غ/كغ = 176
  await expect(row("macros-avg")).toHaveText(["176", "187", "64"]);       // (2029 − 704 − 576) ÷ 4
  await page.fill("#i-mf", "9");
  await expect(page.getByText("الدهون بين 0.3 و 2 غ/كغ.")).toBeVisible();
  await expect(page.getByTestId("macros-avg")).toHaveCount(0);
  await page.fill("#i-mf", "0.8");
  await page.selectOption("#i-mp", "moderate");
  // Ten Haaf: يطلب الطول والعمر والجنس
  await page.locator(".method", { hasText: "ما أعرف نسبة الدهون" }).click();
  await page.fill("#i-weight", "85");
  await page.getByRole("button", { name: "احسب السعرات", exact: true }).click();
  await expect(page.getByText("اختر الجنس.")).toBeVisible();
  await page.fill("#i-heightCm", "178");
  await page.fill("#i-age", "35");
  await page.locator(".choice", { has: page.locator('input[name="i-sex"][value="male"]') }).click();
  await page.getByRole("button", { name: "احسب السعرات", exact: true }).click();
  await expect(page.getByTestId("intake-maintenance")).toHaveText("2,745");
  await expect(page.getByTestId("intake-target")).toHaveText("2,196");
  await noHorizontalScroll(page);

  // تحقق: حقول فارغة
  await page.getByRole("button", { name: "احسب توازن الطاقة" }).click();
  await expect(page.getByText(/اكتب تغيّر الكتلة الخالية من الدهون/)).toBeVisible();
  await expect(page.getByText("اختر تاريخ القياس الأول.")).toBeVisible();

  // مثال ملف Henselmans: عضل +5، دهون −3، 31 يوم، 2069 × 6 أيام تمرين، 1548 يوم الراحة
  await page.fill("#c-lean", "5");
  await page.locator(".choice", { has: page.locator('input[name="c-fatDir"][value="down"]') }).click();
  await page.fill("#c-fat", "3");
  await page.fill("#c-startDate", "2019-12-10");
  await page.fill("#c-endDate", "2020-01-10");
  await page.fill("#c-trainingKcal", "2069");
  await page.selectOption("#c-trainingDays", "6");
  await page.fill("#c-restKcal", "0");
  await page.getByRole("button", { name: "احسب توازن الطاقة" }).click();
  await expect(page.getByText("سعرات يوم الراحة لازم تكون أكبر من صفر.")).toBeVisible();
  await page.fill("#c-restKcal", "1548");
  await page.getByRole("button", { name: "احسب توازن الطاقة" }).click();
  await expect(page.getByTestId("calc-daily")).toHaveText("−620");
  await expect(page.getByTestId("calc-net")).toHaveText("−19,227");
  await expect(page.getByTestId("calc-days")).toHaveText("31");
  await expect(page.getByTestId("calc-avg")).toHaveText("1,995");
  await expect(page.getByTestId("calc-maintenance")).toHaveText("2,615");
  await expect(page.getByText("24٪")).toBeVisible();
  await noHorizontalScroll(page);
  await page.getByText("وش الفرق بين هذي الحاسبة والحاسبات العادية؟").click();
  await expect(page.getByText(/توازن طاقتك الفعلي/)).toBeVisible();
  await page.context().close();
});

test("الجداول المجانية: عرض، طلب بعد الدخول، تنزيل محمي، وإدارة", async ({ browser }, info) => {
  const project = info.project.name;
  const coachEmail = `coach5-${project}@e2e.test`;
  const userEmail = `plan-user-${project}@e2e.test`;
  const otherEmail = `plan-other-${project}@e2e.test`;
  const slug = `e2e-plan-${project}`;
  const hiddenSlug = `e2e-hidden-${project}`;
  const pdf = Buffer.from(`%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[]/Count 0>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n% ${project}\n`);

  // ---------- المدربة تضيف جدولاً منشوراً وآخر مخفياً ----------
  const coach = await newPage(browser, project + "-c5");
  await login(coach, coachEmail, "/admin");
  await db.query(`UPDATE "user" SET role = 'coach' WHERE email = $1`, [coachEmail]);
  for (const [s, title, publish] of [[slug, `جدول تجريبي ${project}`, true], [hiddenSlug, `جدول مخفي ${project}`, false]] as const) {
    await coach.goto("/admin/free-plans/new");
    await coach.getByLabel("اسم الجدول").fill(title);
    await coach.getByLabel("رابط الصفحة (بالإنجليزي)").fill(s);
    await coach.getByLabel("وصف مختصر").fill("وصف اختباري لجدول تجريبي في بيئة الاختبار فقط.");
    await coach.setInputFiles("#fp-file", { name: "plan.pdf", mimeType: "application/pdf", buffer: pdf });
    if (publish) await coach.locator('input[name="status"][value="published"]').check();
    await coach.getByRole("button", { name: "إنشاء الجدول" }).click();
    await expect(coach.getByText("تم إنشاء الجدول.")).toBeVisible();
  }
  // ملف غير PDF يُرفض على الخادم
  await coach.goto("/admin/free-plans/new");
  await coach.getByLabel("اسم الجدول").fill("ملف مزيف");
  await coach.getByLabel("رابط الصفحة (بالإنجليزي)").fill(`fake-${project}`);
  await coach.getByLabel("وصف مختصر").fill("محاولة رفع ملف ليس PDF لاختبار الرفض.");
  await coach.setInputFiles("#fp-file", { name: "evil.pdf", mimeType: "application/pdf", buffer: Buffer.from("<script>alert(1)</script>") });
  await coach.getByRole("button", { name: "إنشاء الجدول" }).click();
  await expect(coach.getByText("الملف لازم يكون PDF.")).toBeVisible();

  // ---------- الزائر: يرى المنشور فقط، ولا يطلب بدون حساب ----------
  const page = await newPage(browser, project + "-fp");
  await page.goto("/");
  if (await page.getByLabel("فتح القائمة").isVisible()) {
    await page.getByLabel("فتح القائمة").click();
    await page.locator(".menu-panel").getByRole("link", { name: "الجداول المجانية" }).click();
  } else {
    await page.locator(".nav").getByRole("link", { name: "الجداول المجانية" }).click();
  }
  await expect(page).toHaveURL(/\/free-plans$/);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("جداول تدريب مجانية");
  const list = page.getByTestId("free-plans");
  await expect(list).toContainText(`جدول تجريبي ${project}`);
  await expect(list).not.toContainText(`جدول مخفي ${project}`);
  await noHorizontalScroll(page);
  expect((await page.goto(`/free-plans/${hiddenSlug}`))?.status()).toBe(404);
  const anonDl = await page.request.get(`/api/free-plans/00000000-0000-0000-0000-000000000000`, { maxRedirects: 0 });
  expect(anonDl.status()).toBe(303);
  expect(anonDl.headers().location).toContain("/login");

  // ---------- الطلب يعيد المستخدم لنفس الجدول بعد الدخول ----------
  await page.goto("/free-plans");
  await list.locator(".fp-card", { hasText: `جدول تجريبي ${project}` }).getByRole("link", { name: "اطلب الجدول مجانًا" }).click();
  await expect(page).toHaveURL(new RegExp(`/login\\?next=%2Ffree-plans%2F${slug}`));
  await page.getByLabel("البريد الإلكتروني").fill(userEmail);
  await page.getByRole("button", { name: "أرسل رمز الدخول" }).click();
  await page.getByLabel("رمز الدخول").fill(await latestOtp(userEmail));
  await page.getByRole("button", { name: "دخول" }).click();
  await expect(page).toHaveURL(new RegExp(`/free-plans/${slug}$`));
  await page.getByRole("button", { name: "اطلب الجدول مجانًا" }).dblclick();
  await expect(page.getByText("أُضيف الجدول إلى «جداولي المجانية»")).toBeVisible();
  await page.reload();
  await expect(page.getByTestId("plan-owned")).toContainText("موجود في جداولي");
  const { rows: [{ n }] } = await db.query(
    `SELECT count(*)::int n FROM free_plan_requests r JOIN "user" u ON u.id = r.user_id JOIN free_plans p ON p.id = r.plan_id WHERE u.email = $1 AND p.slug = $2`, [userEmail, slug]);
  expect(n).toBe(1); // لا تكرار رغم الضغط المزدوج والتحديث

  // ---------- جداولي المجانية + تنزيل الملف الحقيقي ----------
  await page.getByRole("link", { name: /افتح جداولي المجانية/ }).click();
  const mine = page.getByTestId("my-free-plans");
  await expect(mine).toContainText(`جدول تجريبي ${project}`);
  const href = (await mine.getByRole("link", { name: "تحميل PDF" }).getAttribute("href"))!;
  const [download] = await Promise.all([page.waitForEvent("download"), mine.getByRole("link", { name: "تحميل PDF" }).click()]);
  expect(download.suggestedFilename()).toBe(`nav-${slug}.pdf`);
  const saved = await download.path();
  expect(readFileSync(saved).equals(pdf)).toBe(true);
  await noHorizontalScroll(page);

  // ---------- مستخدم آخر لا يصل للرابط ----------
  const other = await newPage(browser, project + "-fo");
  await login(other, otherEmail);
  const res = await other.request.get(href, { maxRedirects: 0 });
  expect(res.status()).toBe(303);
  expect(res.headers().location).toContain("plan=notfound");
  await other.goto(href);
  await expect(other.getByText("تعذّر تحميل الملف")).toBeVisible();
  await expect(other.getByTestId("my-free-plans")).toHaveCount(0); // لم يطلب جداول، فلا تظهر إلا رسالة الخطأ
  await other.context().close();

  // ---------- الإدارة: عدد الطلبات، والإخفاء يمنع الطلب الجديد ويُبقي الملف لمن طلبه ----------
  await coach.goto("/admin/free-plans");
  await expect(coach.getByTestId("admin-free-plans").locator("tr", { hasText: `جدول تجريبي ${project}` })).toContainText("1");
  await coach.getByTestId("admin-free-plans").locator("tr", { hasText: `جدول تجريبي ${project}` }).getByRole("link", { name: "تعديل" }).click();
  await coach.locator('input[name="status"][value="hidden"]').check();
  await coach.getByRole("button", { name: "حفظ التعديلات" }).click();
  await expect(coach.getByText("تم الحفظ.")).toBeVisible();
  expect((await page.goto(`/free-plans/${slug}`))?.status()).toBe(404);
  await page.goto("/account");
  await expect(page.getByTestId("my-free-plans")).toContainText(`جدول تجريبي ${project}`);
  const again = await page.request.get(href);
  expect(again.headers()["content-type"]).toBe("application/pdf");
  await coach.goto("/admin");
  await expect(coach.getByTestId("stat-new-orders")).toBeVisible();
  await coach.context().close();
  await page.context().close();
});
