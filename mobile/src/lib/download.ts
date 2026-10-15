import { fetch } from "expo/fetch";
import { File, Paths } from "expo-file-system";
import * as Sharing from "expo-sharing";
import { authClient } from "./auth-client";
import { API_URL } from "./config";

/**
 * يحمّل ملفاً محمياً بالجلسة (ملفات البرنامج، الجداول المجانية، الكتيبات) ثم يفتحه بعارض الجوال.
 * لا يتبع التحويلات: صفحات التحميل في الموقع تحوّل لصفحة الحساب عند الخطأ، فنعتبرها فشلاً بدل حفظ صفحة HTML كملف.
 */
export async function downloadAndOpen(path: string, name: string, mime = "application/pdf") {
  const cookie = await authClient.getCookie();
  const res = await fetch(`${API_URL}${path}`, { headers: cookie ? { Cookie: cookie } : {}, redirect: "manual" });
  const type = res.headers.get("content-type") ?? "";
  if (!res.ok || type.startsWith("text/html")) throw new Error(`download ${res.status}`);
  const file = new File(Paths.cache, name.replace(/[^\w.\-]+/g, "_"));
  if (file.exists) file.delete();
  file.write(await res.bytes());
  await Sharing.shareAsync(file.uri, { mimeType: type || mime, dialogTitle: name });
}
