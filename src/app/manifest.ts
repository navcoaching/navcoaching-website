import type { MetadataRoute } from "next";

// يسمح بإضافة الموقع للشاشة الرئيسية وفتحه بملء الشاشة. لا يوجد Service Worker:
// الموقع يحتاج اتصالاً بالإنترنت، ولا توجد إشعارات Push من المتصفح.
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "Nav Coaching",
    short_name: "Nav",
    description: "حسابك في Nav Coaching: طلباتك، ملفات برنامجك، ومراجعتك الأسبوعية.",
    lang: "ar",
    dir: "rtl",
    start_url: "/account",
    scope: "/",
    display: "standalone",
    background_color: "#07142a",
    theme_color: "#07142a",
    icons: [
      { src: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
      { src: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
      { src: "/icons/icon-maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  };
}
