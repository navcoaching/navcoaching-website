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

export type ActionResult = { ok?: boolean; message?: string; error?: string };

/** يستدعي عملية من عمليات الموقع (نفس التحقق والصلاحيات) ويرجع نتيجتها بدل رمي الأخطاء المتوقعة */
export async function apiAction(name: string, fd: FormData): Promise<ActionResult> {
  const cookie = await authClient.getCookie();
  try {
    const res = await fetch(`${API_URL}/api/mobile/v1/actions/${name}`, {
      method: "POST", body: fd, credentials: "omit",
      headers: { Accept: "application/json", ...(cookie ? { Cookie: cookie } : {}) },
    });
    const body = (await res.json().catch(() => ({}))) as ActionResult;
    if (res.status === 401) return { error: "انتهت جلستك. سجّل الدخول مرة ثانية." };
    return res.ok ? body : { error: body.error ?? "تعذّر الحفظ. حاول مرة ثانية." };
  } catch {
    return { error: "تحتاج اتصالاً بالإنترنت لهذه العملية." };
  }
}

export type PlanWeek = { sets: number; reps: number[]; rir: number | null };
export type CoachingItem = {
  id: string; note: string | null; plan: PlanWeek[];
  exercise: { id: string; name: string; muscle: string | null; video: string | null; instructions: string | null };
};
export type Coaching = {
  order: { order_no: string; product_name: string; status: string };
  block: null | { id: string; name: string; weeks: number; start_date: string; instructions: string | null; read_only: boolean; current_week: number };
  days?: { id: string; title: string; items: CoachingItem[] }[];
  logs?: { item: string; week: number; weights: number[]; reps: number[]; rir: number | null }[];
  notes?: { id: number; week: number | null; body: string }[];
};

export type Order = { order_no: string; product_name: string; status: string; status_label: string; amount: string | null; created_at: string };
export type Orders = { orders: Order[]; bank: { accountName: string; bankName: string; iban: string } | null };
