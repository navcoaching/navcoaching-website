// منطق اختبار «أي باقة تناسبني؟». المبتدئ يُقترح له حسب احتياجه ونوع المتابعة مثل غيره، لكن بدون ملفات بلا متابعة.
export type QuizAnswers = { level: string; need: string; follow: string; live: string };
export const QUIZ_SKU: Record<string, string> = {
  int: "int1", adv: "adv1", bas: "bas1", nut: "nut1", diy: "diy", diyN: "diyN", cT: "cT", cN: "cN",
};

const WHY_EN: Record<string, string> = {
  "عندك أسئلة محددة في التمرين، فجلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك.": "You have specific training questions, so one session is enough to adjust your plan and correct technique.",
  "عندك أسئلة محددة في التغذية، فجلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل.": "You have specific nutrition questions, so one session is enough to set your calories and food advice.",
  "الجلسة الحضورية لتصحيح التكنيك موجودة في الباقة المكثفة فقط.": "The in-person technique session is only included in the Intensive plan.",
  "تغذية بدون متابعة: جلسة استشارة تغذية تعطيك حسبة السعرات والاقتراحات.": "Nutrition without follow-up: a nutrition consultation gives you a calorie target and suggestions.",
  "مستواك يسمح إنك تمشي على جدول مخصص بدون متابعة.": "Your level lets you follow a custom plan without follow-up.",
  "الملفات بدون متابعة مصممة للمتقدمين، فاقترحنا لك أخف باقة فيها متابعة تناسب البداية.": "Plans without follow-up are designed for advanced trainees, so we suggested the lightest plan with follow-up for a good start.",
  "تغذية فقط: باقة التغذية فيها خطة تغذية شاملة وتعليم حساب السعرات مع متابعة أسبوعية.": "Nutrition only: the Nutrition plan includes a complete nutrition plan, calorie-counting coaching, and weekly follow-up.",
  "متابعة أسبوعية مع مكالمات: المكثفة فيها 4 مكالمات زوم شهرياً مع المراجعة الأسبوعية.": "Weekly follow-up with calls: Intensive includes 4 Zoom calls a month alongside the weekly review.",
  "تمرين فقط: الأساسية فيها خطة تمرين ومتابعة كل أسبوعين.": "Training only: Basic includes a training plan and a review every two weeks.",
  "تمرين وتغذية مع مراجعة أسبوعية بدون مكالمات زوم.": "Training and nutrition with a weekly review, without Zoom calls.",
  "خبرة سابقة مع احتياج تمرين وتغذية ومراجعة أسبوعية، بدون زوم.": "Previous experience, needing training, nutrition, and a weekly review, without Zoom.",
  "للمتابعة الأقرب في البداية (مكالمات زوم وشرح MyFitnessPal) فالمكثفة خيار أقوى.": "For closer follow-up at the start (Zoom calls and the MyFitnessPal guide), Intensive is the stronger option.",
};

export function recommend(a: QuizAnswers, lang: "ar" | "en" = "ar"): { k: string; alt?: string; why: string[] } {
  const r = recommendAr(a);
  return lang === "en" ? { ...r, why: r.why.map((w) => WHY_EN[w] ?? w) } : r;
}

function recommendAr(a: QuizAnswers): { k: string; alt?: string; why: string[] } {
  const why: string[] = [];
  const beg = a.level === "beg";
  let k: string;
  let alt: string | undefined;
  if (a.need === "askT") { k = "cT"; why.push("عندك أسئلة محددة في التمرين، فجلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك."); alt = "int"; }
  else if (a.need === "askN") { k = "cN"; why.push("عندك أسئلة محددة في التغذية، فجلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل."); alt = "nut"; }
  else if (a.live === "yes") { k = "int"; why.push("الجلسة الحضورية لتصحيح التكنيك موجودة في الباقة المكثفة فقط."); }
  else if (a.follow === "none" && !beg) {
    if (a.need === "food") { k = "cN"; why.push("تغذية بدون متابعة: جلسة استشارة تغذية تعطيك حسبة السعرات والاقتراحات."); alt = "nut"; }
    else { k = a.need === "both" ? "diyN" : "diy"; why.push("مستواك يسمح إنك تمشي على جدول مخصص بدون متابعة."); alt = a.need === "both" ? "adv" : "bas"; }
  } else {
    // نفس الاختيار للمبتدئ وغيره حسب احتياجه ونوع المتابعة؛ المبتدئ فقط ما نقترح له ملفات بدون متابعة
    if (beg && a.follow === "none") why.push("الملفات بدون متابعة مصممة للمتقدمين، فاقترحنا لك أخف باقة فيها متابعة تناسب البداية.");
    if (a.need === "food") { k = "nut"; why.push("تغذية فقط: باقة التغذية فيها خطة تغذية شاملة وتعليم حساب السعرات مع متابعة أسبوعية."); alt = a.follow === "close" ? "int" : "adv"; }
    else if (a.follow === "close") { k = "int"; why.push("متابعة أسبوعية مع مكالمات: المكثفة فيها 4 مكالمات زوم شهرياً مع المراجعة الأسبوعية."); alt = a.need === "train" ? "bas" : "adv"; }
    else if (a.need === "train") { k = "bas"; why.push("تمرين فقط: الأساسية فيها خطة تمرين ومتابعة كل أسبوعين."); alt = beg ? "int" : "adv"; }
    else { k = "adv"; why.push(beg ? "تمرين وتغذية مع مراجعة أسبوعية بدون مكالمات زوم." : "خبرة سابقة مع احتياج تمرين وتغذية ومراجعة أسبوعية، بدون زوم."); alt = "int"; }
    if (beg && k !== "int") why.push("للمتابعة الأقرب في البداية (مكالمات زوم وشرح MyFitnessPal) فالمكثفة خيار أقوى.");
  }
  return { k, alt, why };
}
