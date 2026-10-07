import { authClient } from "./auth-client";
import { API_URL } from "./config";

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

/** طلب لواجهات /api/mobile/v1 مع كوكي الجلسة (التطبيق لا يملك كوكيز متصفح، فنرسلها يدوياً). */
export function api<T>(path: string, init: Omit<RequestInit, "headers"> & { headers?: Record<string, string> } = {}): Promise<T> {
  return siteApi<T>(`/api/mobile/v1${path}`, init);
}

/** طلب لأي واجهة في الموقع (مثل /api/foods/search) بنفس الجلسة */
export async function siteApi<T>(path: string, init: Omit<RequestInit, "headers"> & { headers?: Record<string, string> } = {}): Promise<T> {
  const cookie = await authClient.getCookie();
  const res = await fetch(`${API_URL}${path}`, {
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
  ratings?: { day: string; week: number; rating: number }[];
};

export type Order = { order_no: string; product_name: string; status: string; status_label: string; amount: string | null; created_at: string };
export type Orders = { orders: Order[]; bank: { accountName: string; bankName: string; iban: string } | null };

export type Macros = { protein: number; carbs: number; fat: number };
export type MealKind = "breakfast" | "lunch" | "dinner" | "snack";
export const MEAL_KINDS: Record<MealKind, string> = { breakfast: "الفطور", lunch: "الغداء", dinner: "العشاء", snack: "سناك" };
export const MEAL_ICON: Record<MealKind, string> = { breakfast: "🌅", lunch: "☀️", dinner: "🌙", snack: "🍎" };
export type ReadyMeal = Macros & { id: string; kind: MealKind; label: string; kcal: number; own: boolean };
export type Nutrition = {
  order_no: string; date: string; today: string;
  target: { kcal: number | null; protein: number | null; carbs: number | null; fat: number | null; rules: string | null } | null;
  total: Macros & { kcal: number };
  logs: (Macros & { id: number; kind: MealKind; name: string; meal_id: string | null; kcal: number })[];
  plans: { id: string; name: string; notes: string | null; total: Macros & { kcal: number };
    meals: { id: string; kind: MealKind; title: string; method: string | null; items: (Macros & { id: string; food: string; portion: string | null })[]; total: Macros & { kcal: number } }[] }[];
  routine: null | { id: string; name: string; intro: string | null;
    sections: { id: string; title: string; routine: string | null; items: { id: string; name: string; dose: string | null; timing: string | null; importance: string | null; benefit: string | null; link: string | null }[] }[] };
  ready: ReadyMeal[];
  details: { id: string; method: string | null; items: (Macros & { food: string; portion: string | null })[] }[];
};

export type Progress = {
  today: string; order_no: string | null;
  body: { weights: { logged_on: string; kg: number }[]; measurements: { measured_on: string; chest: number | null; waist: number | null; hips: number | null; thigh: number | null }[] };
  records: { exercise_id: string; name: string; best: number; best_at: string; previous: number | null; status: "first" | "new" | "same"; oneRm: number }[];
  steps: null | { block: string; goal_week: number; weeks: number; read_only: boolean; current_week: number; logs: { week_no: number; total: number }[] };
};

export type Addon = { kind: "program_review" | "form_check" | "meal_library"; name: string; about: string | null; sku: string; label: string; price: string };

/** طلب خدمة إضافية (ينشئ طلباً ينتظر التحويل). يرجع رقم الطلب أو رسالة الخطأ. */
export async function orderAddon(fd: FormData): Promise<{ orderNo?: string; error?: string }> {
  const cookie = await authClient.getCookie();
  try {
    const res = await fetch(`${API_URL}/api/mobile/v1/addons`, {
      method: "POST", body: fd, credentials: "omit",
      headers: { Accept: "application/json", ...(cookie ? { Cookie: cookie } : {}) },
    });
    const body = (await res.json().catch(() => ({}))) as { orderNo?: string; error?: string };
    if (res.status === 401) return { error: "login" };
    return res.ok ? { orderNo: body.orderNo } : { error: body.error ?? "تعذّر إرسال الطلب." };
  } catch {
    return { error: "تحتاج اتصالاً بالإنترنت لإرسال الطلب." };
  }
}
