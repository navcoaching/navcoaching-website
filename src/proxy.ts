import { createHash, randomBytes } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { CSP, isDev } from "@/lib/csp";
import { THEME_SCRIPT } from "@/lib/theme-script";

// الصفحات الخاصة ديناميكية أصلاً، فتأخذ سكربتات بـ nonce لكل طلب بدل 'unsafe-inline'؛ الصفحات العامة تبقى ثابتة وسريعة.
// باقي السياسة نفس سياسة next.config، وnext.config يستثني هذه المسارات حتى تبقى سياسة واحدة.
const THEME_HASH = `'sha256-${createHash("sha256").update(THEME_SCRIPT).digest("base64")}'`;

function strictCsp(nonce: string) {
  return CSP.replace(/script-src [^;]+/, `script-src 'self' 'nonce-${nonce}' 'strict-dynamic' ${THEME_HASH}${isDev ? " 'unsafe-eval'" : ""}`);
}

export function proxy(req: NextRequest) {
  const csp = strictCsp(randomBytes(16).toString("base64"));
  // Next يقرأ الـ nonce من ترويسة الطلب ويضيفه لسكربتاته تلقائياً
  const headers = new Headers(req.headers);
  headers.set("Content-Security-Policy", csp);
  const res = NextResponse.next({ request: { headers } });
  res.headers.set("Content-Security-Policy", csp);
  return res;
}

export const config = { matcher: ["/account/:path*", "/admin/:path*", "/login/:path*", "/checkout/:path*"] };
