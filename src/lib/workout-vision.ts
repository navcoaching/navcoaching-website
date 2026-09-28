import "server-only";
import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { z } from "zod/v4";
import type { ExtractedExercise } from "./workout-import";

/**
 * قراءة لقطة شاشة تمرين من تطبيق خارجي (Strong وغيره) عبر Claude.
 * الصورة لا تُحفظ في الموقع؛ تُرسل للقراءة فقط، والنتيجة يراجعها المتدرب قبل الحفظ.
 * يعمل فقط عند ضبط ANTHROPIC_API_KEY. في الاختبارات المحلية فقط: WORKOUT_VISION_MOCK=1 يرجع نتيجة ثابتة.
 */
export function visionMock() {
  return process.env.NETLIFY !== "true" && process.env.WORKOUT_VISION_MOCK === "1";
}
export function visionEnabled() {
  return Boolean(process.env.ANTHROPIC_API_KEY) || visionMock();
}

const Schema = z.object({
  is_workout: z.boolean().describe("هل الصورة سجل تمرين مقاومة (تمارين ومجموعات)؟"),
  exercises: z.array(z.object({
    name: z.string().describe("اسم التمرين كما يظهر في الصورة"),
    unit: z.enum(["kg", "lb"]).nullable().describe("وحدة الوزن الظاهرة، أو null إن لم تظهر"),
    sets: z.array(z.object({
      weight: z.number().nullable(),
      reps: z.number().nullable(),
      rpe: z.number().nullable(),
      warmup: z.boolean().describe("مجموعة إحماء (مثل علامة W)"),
    })),
  })),
});

const PROMPT = `This is a screenshot from a workout tracking app (for example Strong or Hevy).
Extract every exercise and each of its sets exactly as shown: weight, reps, RPE if shown, and whether the set is a warm-up (marked "W" or labelled warm-up).
Only report values that are visible. Use null for anything missing or unreadable; do not estimate.
Report the weight unit shown in the screenshot (kg or lb), or null if none is shown.
If the image is not a resistance-training log, set is_workout to false and return an empty list.
When several screenshots are given, they are consecutive parts of the same workout, in order: report each exercise once, keep its sets in order, and if the same set appears in two overlapping screenshots, include it only once.`;

const MOCK: ExtractedExercise[] = [
  { name: "Leg Press (Machine)", unit: "kg", sets: [{ weight: 60, reps: 12, warmup: true }, { weight: 100, reps: 12 }, { weight: 110, reps: 10 }] },
  { name: "Hip Thrust (Barbell)", unit: "kg", sets: [{ weight: 70, reps: 10 }, { weight: 70, reps: 10 }] },
  { name: "Chest Supported Row", unit: "lb", sets: [{ weight: 100, reps: 12 }] },
];

export class VisionError extends Error {}

export const MAX_IMAGES = 4;

/** يقرأ حتى 4 لقطات لنفس التمرين في طلب واحد (بالترتيب)، ويرجع قائمة واحدة */
export async function readWorkoutImages(images: { data: Buffer; mime: string }[]): Promise<ExtractedExercise[]> {
  if (visionMock()) return MOCK;
  if (!process.env.ANTHROPIC_API_KEY) throw new VisionError("قراءة الصور غير مفعّلة حالياً.");
  if (!images.length || images.length > MAX_IMAGES) throw new VisionError(`ارفع من صورة إلى ${MAX_IMAGES} صور.`);
  if (images.some((i) => !["image/jpeg", "image/png", "image/webp", "image/gif"].includes(i.mime))) throw new VisionError("ارفع صور JPG أو PNG.");
  const data = { length: images.reduce((n, i) => n + i.data.length, 0) }; // للسجل فقط

  // مهلة أقصر من حد وظائف الخادم، بدون إعادة محاولة: رسالة واضحة بدل انقطاع الطلب
  const client = new Anthropic({ timeout: 25_000, maxRetries: 0 });
  const started = Date.now();
  let response;
  try {
    response = await client.beta.messages.parse({
      model: "claude-opus-5",
      max_tokens: 8000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: { effort: "low", format: betaZodOutputFormat(Schema) },
      messages: [{
        role: "user",
        content: [
          ...images.map((i) => ({ type: "image" as const, source: { type: "base64" as const, media_type: i.mime as "image/png", data: i.data.toString("base64") } })),
          { type: "text", text: PROMPT },
        ],
      }],
    });
  } catch (err) {
    // كل رسالة معها رمز قصير (V-…) يوصل للمدربة من لقطة شاشة، والتفاصيل في سجلات الخادم
    const ms = Date.now() - started;
    if (err instanceof Anthropic.APIConnectionTimeoutError) { console.error("[vision] timeout", ms, "ms"); throw new VisionError("طالت قراءة الصورة. جرّب مرة ثانية أو سجّل يدوياً. (رمز: V-TIME)"); }
    if (err instanceof Anthropic.APIError) {
      console.error("[vision]", err.status, err.message, ms, "ms");
      if (err instanceof Anthropic.AuthenticationError || err instanceof Anthropic.PermissionDeniedError) throw new VisionError(`خدمة قراءة الصور غير مفعّلة حالياً. سجّل يدوياً. (رمز: V-${err.status})`);
      if (err instanceof Anthropic.RateLimitError) throw new VisionError("الخدمة مشغولة الآن. حاول بعد دقيقة. (رمز: V-429)");
      if (err instanceof Anthropic.BadRequestError) throw new VisionError("تعذّرت قراءة الصورة. جرّب لقطة أوضح أو سجّل يدوياً. (رمز: V-400)");
      throw new VisionError(`تعذّرت قراءة الصورة الآن. حاول لاحقاً أو سجّل يدوياً. (رمز: V-${err.status ?? "NET"})`);
    }
    console.error("[vision] unexpected", (err as Error).name, (err as Error).message, ms, "ms");
    throw new VisionError(`تعذّرت قراءة الصورة. سجّل يدوياً أو حاول لاحقاً. (رمز: V-${(err as Error).name || "ERR"})`);
  }
  console.log("[vision] ok", Date.now() - started, "ms", images.length, "images", data.length, "bytes", response.stop_reason);
  if (response.stop_reason === "refusal") throw new VisionError("تعذّرت قراءة الصورة. جرّب لقطة شاشة من سجل التمرين فقط. (رمز: V-REFUSAL)");
  if (response.stop_reason === "max_tokens") throw new VisionError("الصورة فيها تمارين كثيرة. جرّب لقطة لجزء منها. (رمز: V-MAX)");
  if (!response.parsed_output) throw new VisionError("تعذّرت قراءة الصورة. جرّب لقطة أوضح أو سجّل يدوياً. (رمز: V-PARSE)");
  const out = response.parsed_output;
  if (!out.is_workout || !out.exercises.length) throw new VisionError("ما لقينا تمارين في الصورة. ارفع لقطة شاشة من سجل التمرين.");
  return out.exercises.slice(0, 30).map((e) => ({ name: e.name.slice(0, 120), unit: e.unit, sets: e.sets.slice(0, 15) }));
}
