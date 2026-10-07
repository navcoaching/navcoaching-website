import * as WebBrowser from "expo-web-browser";
import { API_URL } from "./config";

/** صفحات الموقع داخل التطبيق (متصفح آمن من النظام): البرامج والطلب بالتحويل البنكي */
export function openSite(path: string) {
  return WebBrowser.openBrowserAsync(`${API_URL}${path}`, { presentationStyle: WebBrowser.WebBrowserPresentationStyle.PAGE_SHEET });
}
