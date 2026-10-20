import { useFocusEffect } from "expo-router";
import { useCallback, useState } from "react";
import { api } from "./api";
import { authClient } from "./auth-client";
import { useTracker } from "./tracker/context";

// «ناف برو»: بدائل الكوتش لكل تمرين. تُجلب من الموقع (الاستحقاق تقرره قاعدة البيانات) وتُحفظ على الجهاز
// حتى تعمل في النادي بدون إنترنت. النسخة المحفوظة تخص صاحب الحساب فقط، وتُتجاهل بعد الخروج أو تغيير الحساب.
const KEY = "coach_alts";
type Saved = { userId: string; pro: boolean; alts: Record<string, string[]> };
export type CoachAlts = { pro: boolean; altsFor: (exerciseId: string) => string[] };

export function useCoachAlts(): CoachAlts {
  const tracker = useTracker();
  const { data: session } = authClient.useSession();
  const userId = session?.user.id ?? null;
  const [saved, setSaved] = useState<Saved | null>(null);

  useFocusEffect(useCallback(() => {
    if (!userId) { setSaved(null); return; }
    let live = true;
    tracker.getSetting(KEY).then((raw) => {
      const s = raw ? (JSON.parse(raw) as Saved) : null;
      if (live && s?.userId === userId) setSaved(s);
    }).catch(() => {});
    api<{ pro: boolean; alts: Record<string, string[]> }>("/coach-alts").then(async (r) => {
      const s: Saved = { userId, pro: r.pro, alts: r.alts };
      if (live) setSaved(s);
      await tracker.setSetting(KEY, JSON.stringify(s));
    }).catch(() => {}); // بدون اتصال: تبقى النسخة المحفوظة
    return () => { live = false; };
  }, [userId]));

  const cur = saved && saved.userId === userId ? saved : null;
  return { pro: !!cur?.pro, altsFor: (id) => (cur?.pro ? cur.alts[id] ?? [] : []) };
}
