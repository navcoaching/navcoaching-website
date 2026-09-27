// قوائم مكتبة التمارين — مطابقة لورقة «قوائم مساعدة» و«مكتبة التمارين» في قالب ملف التدريب.
export const MUSCLES = ["Quadriceps / الأمامية", "Glutes / المؤخرة", "Hamstrings / الخلفية", "Chest / الصدر", "Back & Lats / الظهر واللاتس", "Shoulders / الأكتاف", "Biceps / البايسبس", "Triceps / الترايسبس", "Core / البطن والكور", "Calves / البطات", "Adductors / الأفخاذ الداخلية", "Abductors / مبعدات الفخذ", "Rotator cuffs / الكفة المدورة", "Lower back / أسفل الظهر", "Stretching / الإطالات", "Plyometrics / التمارين الانفجارية", "CrossFit / كروس فت", "Functional / التمارين الوظيفية", "Forearms / الساعد", "Neck / الرقبة"] as const;
export const PATTERNS = ["Ankle Plantar Flexion / ثني أخمصي للكاحل", "Core Activation & Breathing / تفعيل الجذع والتنفس", "Core Stability (Anti-movement) / ثبات الجذع (مقاومة الحركة)", "Elbow Extension / مد الكوع", "Elbow Flexion / ثني الكوع", "Full-body Integrated / حركة متكاملة للجسم", "Glute Hip Abduction / دفع جانبي للورك", "Glute Hip Extension / دفع خلفي للورك", "Hip Adduction / تقريب الورك", "Hip Hinge (Hip-dominant) / مفصلة الورك (هيمنة الورك)", "Horizontal Adduction (Fly) / تقريب أفقي للكتف (فلاي)", "Horizontal Pull / سحب أفقي", "Horizontal Push / دفع أفقي", "Jump / Plyometric / قفز وحركات انفجارية", "Knee Extension / مد الركبة", "Knee Flexion / ثني الركبة", "Loaded Carry / حمل ومشي", "Locomotion / مشي وجري ودفع", "Lunge / Single-leg / لانج وحركات الرجل الواحدة", "Mobility / Stretch / إطالة ومرونة", "Neck Flexion (Deep Flexors) / ثني الرقبة العميق", "Olympic Lift (Triple Extension) / رفعات أولمبية (بسط ثلاثي)", "Scapular Elevation / رفع لوح الكتف", "Shoulder Front Raise / رفع أمامي للكتف", "Shoulder Lateral Raise / رفع جانبي للكتف", "Shoulder Rear Pull / سحب خلفي للكتف", "Shoulder Rotation & Scapular Control / دوران الكتف والتحكم بلوح الكتف", "Spinal Extension / بسط الجذع", "Squat (Knee-dominant) / سكوات (هيمنة الركبة)", "Trunk Flexion / ثني الجذع", "Trunk Rotation / دوران الجذع", "Vertical Pull / سحب عمودي", "Vertical Push / دفع عمودي", "Wrist Extension / مد الرسغ"] as const;
export const EQUIPMENT = ["وزن الجسم", "دمبل", "بار", "كيبل", "جهاز", "سميث", "مطاط", "كيتلبل", "كرة سويسرية", "TRX", "أخرى"] as const;
export const KINDS = ["قوة", "كور", "قدرة", "مرونة", "إحماء/تفعيل", "كارديو"] as const;
export const LEVELS = ["مبتدئ", "متوسط", "متقدم"] as const;
export const EX_STATUS = { approved: "معتمد", review: "يحتاج مراجعة", rejected: "غير معتمد" } as const;
export type ExStatus = keyof typeof EX_STATUS;

/** المكان يُشتق من المعدات (نفس معادلة الشيت) */
export function placeFor(equipment: string | null | undefined): "نادي" | "منزل" | "بدون معدات" | null {
  if (!equipment) return null;
  if (equipment === "وزن الجسم") return "بدون معدات";
  if (["دمبل", "مطاط", "كرة سويسرية", "TRX", "كيتلبل"].includes(equipment)) return "منزل";
  return "نادي";
}

/** الجزء العربي من اسم العضلة «Chest / الصدر» ← «الصدر» */
export const muscleAr = (m: string) => m.split(" / ")[1] ?? m;
export const SECONDARY_MUSCLES = [...MUSCLES, "Trapezius / الترابيس"] as const;
