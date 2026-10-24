// سياسة أمان المحتوى: السكربتات الخارجية Google Analytics (بعد موافقة الزائر وفي الصفحات العامة فقط) وTurnstile (الدخول والاستبيان)، والإطارات الخارجية يوتيوب (بعد نقر المستخدم) وTurnstile.
// next.config يطبّقها على كل الصفحات، وproxy.ts يبدّل script-src فيها بـ nonce للصفحات الخاصة.
export const isDev = process.env.NODE_ENV !== "production";

export const CSP = [
  "default-src 'self'",
  `script-src 'self' 'unsafe-inline' https://www.googletagmanager.com https://challenges.cloudflare.com${isDev ? " 'unsafe-eval'" : ""}`,
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https://i.ytimg.com https://*.google-analytics.com https://*.googletagmanager.com",
  "font-src 'self'",
  "connect-src 'self' https://*.google-analytics.com https://*.analytics.google.com https://*.googletagmanager.com",
  "frame-src https://www.youtube-nocookie.com https://www.tiktok.com https://challenges.cloudflare.com",
  "worker-src 'self'",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join("; ");
