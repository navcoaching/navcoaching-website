import { authClient } from "./auth-client";
import { API_URL } from "./config";

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

/** طلب لواجهات /api/mobile/v1 مع كوكي الجلسة (التطبيق لا يملك كوكيز متصفح، فنرسلها يدوياً). */
export async function api<T>(path: string, init: Omit<RequestInit, "headers"> & { headers?: Record<string, string> } = {}): Promise<T> {
  const cookie = await authClient.getCookie();
  const res = await fetch(`${API_URL}/api/mobile/v1${path}`, {
    ...init,
    credentials: "omit",
    headers: { Accept: "application/json", ...(cookie ? { Cookie: cookie } : {}), ...init.headers },
  });
  if (!res.ok) throw new ApiError(res.status, `HTTP ${res.status}`);
  return (await res.json()) as T;
}

export type Me = {
  user: { id: string; name: string; email: string };
  coaching: { orderNo: string; training: boolean; nutrition: boolean } | null;
};
