import type { NextConfig } from "next";
import { CSP as csp, isDev } from "./src/lib/csp";

const nextConfig: NextConfig = {
  distDir: process.env.NEXT_DIST_DIR || ".next",
  poweredByHeader: false,
  reactStrictMode: true,
  serverExternalPackages: ["sharp", "pg"],
  experimental: {
    serverActions: { bodySizeLimit: "6mb" },
  },
  images: {
    remotePatterns: [{ protocol: "https", hostname: "i.ytimg.com" }],
  },
  // اللغات: العربية بلا بادئة (تُعاد كتابتها داخلياً إلى /ar/...)، والإنجليزية تحت /en. الحساب واللوحة والدخول والدفع بالعربية فقط.
  async redirects() {
    return [
      { source: "/ar", destination: "/", permanent: true },
      { source: "/ar/:path*", destination: "/:path*", permanent: true },
      { source: "/en/:seg(account|login|checkout|admin|install)", destination: "/:seg", permanent: false },
      { source: "/en/:seg(account|login|checkout|admin)/:path*", destination: "/:seg/:path*", permanent: false },
    ];
  },
  async rewrites() {
    return { afterFiles: [{ source: "/:path((?!en(?:/|$)|ar(?:/|$)|admin(?:/|$)|api(?:/|$)).*)", destination: "/ar/:path" }] };
  },
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "X-Frame-Options", value: "DENY" },
          { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
          ...(isDev ? [] : [{ key: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains" }]),
        ],
      },
      // الصفحات الخاصة تأخذ سياستها من proxy.ts فقط (Netlify يطبّق هذه الترويسات بعد proxy فكانت ستلغي الـ nonce)
      { source: "/((?!(?:account|admin|login|checkout)(?:/|$)).*)", headers: [{ key: "Content-Security-Policy", value: csp }] },
      { source: "/sw.js", headers: [{ key: "Cache-Control", value: "no-cache, no-store, must-revalidate" }, { key: "Content-Type", value: "application/javascript; charset=utf-8" }] },
      { source: "/(account|admin|login|checkout)(.*)", headers: [{ key: "X-Robots-Tag", value: "noindex" }, { key: "Cache-Control", value: "private, no-store" }] },
    ];
  },
};

export default nextConfig;
