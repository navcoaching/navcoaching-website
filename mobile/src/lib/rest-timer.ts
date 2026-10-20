import * as Notifications from "expo-notifications";
import { useCallback, useEffect, useRef, useState } from "react";

let asked = false;

/** إذن التنبيهات يُطلب مرة واحدة عند أول جولة مكتملة، لا عند فتح التطبيق */
async function canNotify(): Promise<boolean> {
  const cur = await Notifications.getPermissionsAsync();
  if (cur.granted) return true;
  if (asked || !cur.canAskAgain) return false;
  asked = true;
  return (await Notifications.requestPermissionsAsync({ ios: { allowAlert: true, allowSound: true } })).granted;
}

/**
 * مؤقت الراحة بين الجولات. يعتمد على وقت الانتهاء (لا على العدّ) حتى يبقى صحيحاً بعد قفل الجوال،
 * ويجدول تنبيهاً محلياً عند الانتهاء ليصل والتطبيق في الخلفية.
 */
export function useRestTimer() {
  const [endsAt, setEndsAt] = useState<number | null>(null);
  const [now, setNow] = useState(Date.now());
  const notif = useRef<string | null>(null);

  const cancelNotif = useCallback(async () => {
    if (notif.current) await Notifications.cancelScheduledNotificationAsync(notif.current).catch(() => {});
    notif.current = null;
  }, []);

  const schedule = useCallback(async (end: number) => {
    await cancelNotif();
    const seconds = Math.round((end - Date.now()) / 1000);
    if (seconds < 1 || !(await canNotify())) return;
    notif.current = await Notifications.scheduleNotificationAsync({
      content: { title: "انتهت الراحة", body: "جاهز للجولة التالية 💪", sound: true },
      trigger: { type: Notifications.SchedulableTriggerInputTypes.TIME_INTERVAL, seconds },
    }).catch(() => null);
  }, [cancelNotif]);

  const start = useCallback((sec: number) => {
    if (sec <= 0) return;
    const end = Date.now() + sec * 1000;
    setEndsAt(end);
    setNow(Date.now());
    schedule(end);
  }, [schedule]);

  const adjust = useCallback((delta: number) => {
    setEndsAt((e) => {
      if (!e) return e;
      const end = Math.max(Date.now() + 1000, e + delta * 1000);
      schedule(end);
      return end;
    });
  }, [schedule]);

  const skip = useCallback(() => { setEndsAt(null); cancelNotif(); }, [cancelNotif]);

  useEffect(() => {
    if (!endsAt) return;
    const iv = setInterval(() => {
      const n = Date.now();
      setNow(n);
      if (n >= endsAt) { setEndsAt(null); notif.current = null; }
    }, 250);
    return () => clearInterval(iv);
  }, [endsAt]);

  useEffect(() => () => { cancelNotif(); }, [cancelNotif]);

  const remaining = endsAt ? Math.max(0, Math.ceil((endsAt - now) / 1000)) : 0;
  return { active: !!endsAt, remaining, start, adjust, skip };
}
