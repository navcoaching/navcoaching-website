// الصفحة الرئيسية (أكتوبر 2026): ترتيب الأقسام، الهيرو بعمودين، الهيدر والتذييل، وعدم وجود تمرير أفقي على العروض الصغيرة.
import { test, expect } from "@playwright/test";

test("الرئيسية: الترتيب والهيرو والهيدر والتذييل", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("html")).toHaveAttribute("lang", "ar");
  await expect(page.locator("html")).toHaveAttribute("dir", "rtl");

  // الهيرو: العنوان بسطرين، زر واحد، رابط نصي للاختبار، وسطر ثقة بدون الشعار اللفظي الإنجليزي
  const hero = page.locator(".hero-split");
  await expect(hero.locator("h1")).toContainText("برنامج مبني عليك،");
  await expect(hero.locator("h1 .hl")).toHaveText("مو جدول جاهز");
  expect(parseFloat(await hero.locator("h1").evaluate((e) => getComputedStyle(e).lineHeight)) / parseFloat(await hero.locator("h1").evaluate((e) => getComputedStyle(e).fontSize))).toBeGreaterThanOrEqual(1.59);
  await expect(hero.locator(".btn")).toHaveCount(1);
  await expect(hero.getByRole("link", { name: /البرامج والأسعار/ })).toHaveAttribute("href", "#programs");
  await expect(hero.locator("a.text-link", { hasText: "أي برنامج يناسبني؟" })).toHaveAttribute("href", "/programs#quiz");
  await expect(page.getByTestId("trust-line")).toContainText("أدرّب منذ 2017");
  await expect(page.locator("body")).not.toContainText("Where Passion Meets Quality");
  await expect(hero.locator(".hero-frame img:visible")).toHaveCount(1);

  // ترتيب الأقسام: الهيرو، المدربة، البرامج، ليش Nav، (التقييمات)، الخطوات، الأسئلة
  const heads = await page.locator("main .eyebrow").allTextContents();
  const order = ["عن المدربة", "البرامج", "ليش Nav Coaching", "طريقة الاشتراك", "الأسئلة الشائعة"].map((t) => heads.findIndex((h) => h.trim() === t));
  expect(order.every((i) => i >= 0), JSON.stringify(heads)).toBe(true);
  expect([...order].sort((a, b) => a - b)).toEqual(order);
  await expect(page.locator(".stats")).toHaveCount(0);
  await expect(page.locator("#calculator")).toHaveCount(0);

  // البرامج: 3 بطاقات رئيسية بالترتيب، وزر/رابط واحد في كل بطاقة
  const main = page.locator("#programs .grid.g3").first().locator(".pcard");
  await expect(main).toHaveCount(3);
  expect(await main.evaluateAll((els) => els.map((e) => e.getAttribute("href")))).toEqual(["/programs/intensive", "/programs/advanced", "/programs/basic"]);
  await expect(page.locator("#programs")).toContainText("خصم 10% للطلاب · مجاني لأهل غزة · الدفع بتحويل بنكي");

  // الهيدر: روابط القائمة بلون واحد، وزر «البرامج والأسعار»
  if (await page.locator(".nav").isVisible()) {
    const links = page.locator(".nav > a:not(.btn)");
    expect(await links.allTextContents()).toEqual(["البرامج", "عن المدربة", "التقييمات", "الأسئلة الشائعة"]);
    const colors = new Set(await links.evaluateAll((els) => els.map((e) => getComputedStyle(e).color)));
    expect(colors.size).toBe(1);
    await expect(page.locator(".nav .btn", { hasText: "البرامج والأسعار" })).toBeVisible();
  }
  // التذييل: «أدوات مجانية»
  const foot = page.locator(".site-footer");
  await expect(foot.getByRole("heading", { name: "أدوات مجانية" })).toBeVisible();
  await expect(foot.getByRole("link", { name: "حاسبة السعرات" })).toHaveAttribute("href", "/calculator");
  // رابط الجداول المجانية يظهر فقط إذا فيه جدول منشور
  const fp = foot.getByRole("link", { name: "الجداول المجانية" });
  if (await fp.count()) await expect(fp).toHaveAttribute("href", "/free-plans");
  await expect(foot.getByRole("link", { name: "نظرة داخل البرنامج" })).toHaveAttribute("href", "/program-preview");
  // حسابات التواصل: تيك توك يظهر بجانب انستقرام
  await expect(foot.getByRole("link", { name: "تيك توك" })).toHaveAttribute("href", "https://www.tiktok.com/@navcoaching");
  await expect(page.getByText("الانتقال إلى المحتوى")).toHaveCount(1);
});

test("الرئيسية: لا تمرير أفقي على 320 و375 و414 و768، والأزرار على سطر واحد", async ({ page }) => {
  for (const width of [320, 375, 414, 768]) {
    await page.setViewportSize({ width, height: 800 });
    await page.goto("/");
    const [sw, iw] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
    expect(sw, `width ${width}`).toBeLessThanOrEqual(iw);
    const wrapped = await page.locator("main .btn:visible").evaluateAll((els) =>
      els.filter((e) => { const cs = getComputedStyle(e); return e.getBoundingClientRect().height > parseFloat(cs.lineHeight || "0") * 1.9 + 30; }).map((e) => e.textContent));
    expect(wrapped, `width ${width}`).toEqual([]);
  }
});

test("نظرة داخل البرنامج: صفحة مستقلة", async ({ page }) => {
  await page.goto("/program-preview");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("كيف يبدو البرنامج من الداخل؟");
  await expect(page.locator("img").first()).toBeVisible();
});

test("صفحة الباقة: السعر وزر الاشتراك في أول الشاشة، وشريط ثابت على الجوال", async ({ page }, info) => {
  await page.goto("/programs/intensive");
  const offers = page.locator("#offers");
  const top = await offers.evaluate((e) => e.getBoundingClientRect().top + scrollY);
  const phone = (page.viewportSize()?.width ?? 1440) <= 760;
  if (phone) {
    // صندوق المدة مباشرة بعد العنوان، والشريط الثابت ظاهر
    expect(top).toBeLessThan(900);
    await expect(page.getByTestId("buy-bar")).toBeVisible();
    await expect(page.getByTestId("hero-buy")).toBeHidden();
  } else {
    await expect(page.getByTestId("hero-buy")).toBeVisible();
    await expect(page.getByTestId("buy-bar")).toBeHidden();
  }
  // توفير عرض الـ 3 أشهر محسوب من سعر الشهر
  await expect(offers).toContainText("توفير");
  // خط «وش يصير بعد الطلب؟» بدون خطوات مكتملة
  await expect(page.locator(".timeline li.done")).toHaveCount(0);
  // رأس الصفحات الداخلية بدون شبكة النقاط
  expect(await page.locator(".page-hero").evaluate((e) => getComputedStyle(e).backgroundImage)).not.toContain("radial-gradient");
  const [sw, iw] = await page.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  expect(sw).toBeLessThanOrEqual(iw);
  void info;
});
