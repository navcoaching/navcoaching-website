import { z } from "zod";
import { AGE_MAX, AGE_MIN, OPT } from "./intake.ts";

// استبيان العضو بدون طلب (من «بياناتي»): نفس خيارات استبيان الطلب بدون الباقة والدفع والموافقات.
// يُحفظ في member_profiles (الإجابات العامة منفصلة عن البيانات الصحية، كما في الطلب).
const oneOf = <T extends readonly string[]>(list: T, msg: string) => z.enum(list as unknown as [string, ...string[]], { message: msg });
const opt = <T extends readonly string[]>(list: T) => z.union([z.literal(""), oneOf(list, "اختيار غير صالح")]).optional().default("");
const text = (max: number) => z.string().trim().max(max, `النص أطول من ${max} حرفاً`).optional().default("");

export const profileSchema = z.object({
  gender: oneOf(OPT.gender, "اختر الجنس"),
  age: z.string().trim().regex(/^\d{1,3}$/, `اكتب عمرك رقماً بين ${AGE_MIN} و ${AGE_MAX}.`).transform(Number).refine((n) => n >= AGE_MIN && n <= AGE_MAX, `اكتب عمرك رقماً بين ${AGE_MIN} و ${AGE_MAX}.`),
  city: opt(OPT.city),
  goal: oneOf(OPT.goal, "اختر هدفاً"),
  level: oneOf(OPT.level, "اختر مستواك"),
  place: oneOf(OPT.place, "اختر مكان التمرين"),
  equip: z.array(oneOf(OPT.equip, "اختيار غير صالح")).max(OPT.equip.length).default([]),
  days: oneOf(OPT.days, "اختر عدد الأيام"),
  duration: oneOf(OPT.duration, "اختر الوقت المتاح"),
  injury: oneOf(OPT.yesno, "اختر نعم أو لا"),
  condition: oneOf(OPT.yesno, "اختر نعم أو لا"),
  pregnancy: opt(OPT.pregnancy),
  health_notes: text(600),
  weight: z.coerce.number({ message: "اكتب وزنك بالكيلوغرام." }).min(30, "اكتب وزناً بين 30 و 250 كغ.").max(250, "اكتب وزناً بين 30 و 250 كغ."),
  height: z.coerce.number({ message: "اكتب طولك بالسنتيمتر." }).min(120, "اكتب طولاً بين 120 و 230 سم.").max(230, "اكتب طولاً بين 120 و 230 سم."),
  bodyfat: opt([...new Set([...OPT.bodyfat_male, ...OPT.bodyfat_female])]),
  steps: opt(OPT.steps),
  sleep: opt(OPT.sleep),
  job: opt(OPT.job),
  calories: opt(OPT.calories),
  challenge: text(600),
  notes: text(800),
});
export type ProfileInput = z.infer<typeof profileSchema>;

export function splitProfile(v: ProfileInput) {
  const health = { injury: v.injury, condition: v.condition, pregnancy: v.pregnancy, health_notes: v.health_notes, weight: v.weight, height: v.height, bodyfat: v.bodyfat };
  const answers = {
    gender: v.gender, age: v.age, city: v.city, goal: v.goal, level: v.level, place: v.place, equip: v.equip, days: v.days, duration: v.duration,
    steps: v.steps, sleep: v.sleep, job: v.job, calories: v.calories, challenge: v.challenge, notes: v.notes,
  };
  const flag = v.injury === "نعم" || v.condition === "نعم" || ["حامل", "بعد الولادة"].includes(v.pregnancy);
  return { answers, health, flag };
}
