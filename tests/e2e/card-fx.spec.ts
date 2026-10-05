// حركة البطاقات في الصفحات العامة: الضغط على بطاقة يلمّعها ويدوّرها 360° ثم ترجع لوضعها، بدون تمرير أفقي.
import { test, expect } from "@playwright/test";

test("البطاقات: الضغط يلمّع البطاقة ويدوّرها ثم ترجع", async ({ page }) => {
  await page.goto("/");
  const card = page.locator(".bento .card.feature").first();
  await card.scrollIntoViewIfNeeded();
  await card.click();
  await expect(card).toHaveClass(/fx-spin/);
  await expect(card.locator(".fx-shine")).toHaveCount(1);
  // بعد انتهاء الحركة: تُزال اللمعة والدوران
  await expect(card).not.toHaveClass(/fx-spin/, { timeout: 3000 });
  await expect(card.locator(".fx-shine")).toHaveCount(0);
  const step = page.locator("#how .steps > li").first();
  await step.click();
  await expect(step).toHaveClass(/fx-spin/);
  expect(await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)).toBeLessThanOrEqual(0);
});

test("البطاقات: تفضيل تقليل الحركة يلغي الدوران", async ({ browser }) => {
  const ctx = await browser.newContext({ reducedMotion: "reduce" });
  const page = await ctx.newPage();
  await page.goto("http://localhost:3100/");
  const card = page.locator(".bento .card.feature").first();
  await card.scrollIntoViewIfNeeded();
  await card.click();
  expect(await card.evaluate((e) => getComputedStyle(e).animationName)).toBe("none");
  await ctx.close();
});

test("بطاقات البرامج: تلمع وتدور ثم تفتح صفحة الباقة", async ({ page }) => {
  await page.goto("/programs");
  const card = page.locator(".pcard:visible").first();
  const href = await card.getAttribute("href");
  await card.click();
  await expect(card).toHaveClass(/fx-spin/);
  await expect(page).toHaveURL(new RegExp(`${href}$`), { timeout: 5000 });
  await expect(page.locator("h1")).toHaveCount(1);
});
