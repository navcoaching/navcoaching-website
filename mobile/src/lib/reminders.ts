import * as Notifications from "expo-notifications";
import type { Tracker } from "./tracker/repo";

export type ReminderPrefs = { days: number[]; hour: number; minute: number };
export const DEFAULT_PREFS: ReminderPrefs = { days: [], hour: 18, minute: 0 };
// 1 = الأحد (نفس ترقيم expo-notifications للأسبوع)
export const WEEKDAYS = ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"];

export async function loadPrefs(tr: Tracker): Promise<ReminderPrefs> {
  try {
    const v = await tr.getSetting("reminders");
    return v ? { ...DEFAULT_PREFS, ...(JSON.parse(v) as Partial<ReminderPrefs>) } : DEFAULT_PREFS;
  } catch { return DEFAULT_PREFS; }
}

/**
 * يحفظ أيام ووقت التذكير ويعيد جدولة التنبيهات الأسبوعية (محلية، بدون خادم).
 * يرجع false إذا رفض المستخدم إذن التنبيهات.
 */
export async function savePrefs(tr: Tracker, prefs: ReminderPrefs): Promise<boolean> {
  const old = JSON.parse((await tr.getSetting("reminder_ids")) ?? "[]") as string[];
  for (const id of old) await Notifications.cancelScheduledNotificationAsync(id).catch(() => {});
  await tr.setSetting("reminders", JSON.stringify(prefs));
  await tr.setSetting("reminder_ids", "[]");
  if (prefs.days.length === 0) return true;

  let perm = await Notifications.getPermissionsAsync();
  if (!perm.granted && perm.canAskAgain) perm = await Notifications.requestPermissionsAsync({ ios: { allowAlert: true, allowSound: true } });
  if (!perm.granted) return false;

  const ids: string[] = [];
  for (const weekday of prefs.days) {
    ids.push(await Notifications.scheduleNotificationAsync({
      content: { title: "يوم تمرين 💪", body: "جدولك جاهز. افتح Nav وابدأ تمرين اليوم.", sound: true },
      trigger: { type: Notifications.SchedulableTriggerInputTypes.WEEKLY, weekday, hour: prefs.hour, minute: prefs.minute },
    }));
  }
  await tr.setSetting("reminder_ids", JSON.stringify(ids));
  return true;
}

export function timeLabel(hour: number, minute: number): string {
  const h12 = hour % 12 === 0 ? 12 : hour % 12;
  return `${h12}:${String(minute).padStart(2, "0")} ${hour < 12 ? "ص" : "م"}`;
}
