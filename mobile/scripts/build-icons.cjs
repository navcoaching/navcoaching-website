// الاستخدام (من مجلد mobile بعد npm ci في جذر المشروع): node scripts/build-icons.cjs
// يبني أيقونة التطبيق وشاشة البداية من شعار الموقع (public/brand/logo-mark.png)
const sharp = require("../../node_modules/sharp");
const path = require("node:path");
const SRC = path.join(__dirname, "../../public/brand/logo-mark.png");
const OUT = path.join(__dirname, "../assets/");
const NAVY = "#07142a";

async function mark(widthPx) {
  // تكبير ×4 ثم قصّ الحواف بعتبة 50% ثم تصغير: حواف حادة نظيفة بدل التمويه (الشعار أشكال مستقيمة)
  const big = widthPx * 4;
  const { data, info } = await sharp(SRC).resize({ width: big, kernel: "lanczos3" }).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  let r = 0, g = 0, b = 0, n = 0;
  for (let i = 0; i < data.length; i += 4) if (data[i + 3] > 250) { r += data[i]; g += data[i + 1]; b += data[i + 2]; n++; }
  const col = [Math.round(r / n), Math.round(g / n), Math.round(b / n)];
  for (let i = 0; i < data.length; i += 4) { data[i] = col[0]; data[i + 1] = col[1]; data[i + 2] = col[2]; data[i + 3] = data[i + 3] >= 128 ? 255 : 0; }
  const png = await sharp(data, { raw: info }).png().toBuffer();
  return { png: await sharp(png).resize({ width: widthPx, kernel: "lanczos3" }).png().toBuffer(), col };
}

(async () => {
  // أيقونة iOS: 1024×1024 بدون شفافية، الشعار ~60% من العرض
  const m = await mark(620);
  const meta = await sharp(m.png).metadata();
  await sharp({ create: { width: 1024, height: 1024, channels: 3, background: NAVY } })
    .composite([{ input: m.png, left: Math.round((1024 - meta.width) / 2), top: Math.round((1024 - meta.height) / 2) }])
    .flatten({ background: NAVY }).removeAlpha().png().toFile(OUT + "icon.png");
  // شعار شاشة البداية (شفاف، يوضع على خلفية كحلية من app.json)
  const s = await mark(600);
  const sm = await sharp(s.png).metadata();
  await sharp({ create: { width: 1024, height: 1024, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
    .composite([{ input: s.png, left: Math.round((1024 - sm.width) / 2), top: Math.round((1024 - sm.height) / 2) }])
    .png().toFile(OUT + "splash-icon.png");
  // Android لاحقاً: نفس الشعار في المنطقة الآمنة
  const a = await mark(420);
  const am = await sharp(a.png).metadata();
  await sharp({ create: { width: 1024, height: 1024, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
    .composite([{ input: a.png, left: Math.round((1024 - am.width) / 2), top: Math.round((1024 - am.height) / 2) }])
    .png().toFile(OUT + "android-icon-foreground.png");
  console.log("mark color", m.col);
})();
