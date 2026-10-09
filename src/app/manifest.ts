import type { MetadataRoute } from "next";

// تطبيق من المتصفح (PWA): إضافة للشاشة الرئيسية وفتح بملء الشاشة، واختصارات عند الضغط المطوّل على الأيقونة.
// الإشعارات وصفحة عدم الاتصال في public/sw.js.
export default function manifest(): MetadataRoute.Manifest {
  return {
    id: "/account",
    name: "Nav Coaching",
    short_name: "Nav",
    description: "حسابك في Nav Coaching: طلباتك، ملفات برنامجك، ومراجعتك الأسبوعية.",
    lang: "ar",
    dir: "rtl",
    start_url: "/account",
    scope: "/",
    display: "standalone",
    orientation: "portrait",
    categories: ["health", "fitness", "lifestyle"],
    background_color: "#07142a",
    theme_color: "#07142a",
    icons: [
      { src: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
      { src: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
      { src: "/icons/icon-maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
    shortcuts: [
      { name: "جدول التمرين", short_name: "التمرين", url: "/account/go/training", icons: [{ src: "/icons/icon-192.png", sizes: "192x192" }] },
      { name: "سجّل أكلك", short_name: "الأكل", url: "/account/go/food", icons: [{ src: "/icons/icon-192.png", sizes: "192x192" }] },
      { name: "المراجعة الأسبوعية", short_name: "المراجعة", url: "/account/go/checkin", icons: [{ src: "/icons/icon-192.png", sizes: "192x192" }] },
      { name: "التقدم", short_name: "التقدم", url: "/account/go/progress", icons: [{ src: "/icons/icon-192.png", sizes: "192x192" }] },
    ],
  };
}
