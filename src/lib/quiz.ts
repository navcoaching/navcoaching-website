// منطق اختبار «أي باقة تناسبني؟». المبتدئ يُقترح له حسب احتياجه ونوع المتابعة مثل غيره، لكن بدون ملفات بلا متابعة.
export type QuizAnswers = { level: string; need: string; follow: string; live: string };
export const QUIZ_SKU: Record<string, string> = {
  int: "int1", adv: "adv1", bas: "bas1", nut: "nut1", diy: "diy", diyN: "diyN", cT: "cT", cN: "cN",
};

export function recommend(a: QuizAnswers): { k: string; alt?: string; why: string[] } {
  const why: string[] = [];
  const beg = a.level === "beg";
  let k: string;
  let alt: string | undefined;
  if (a.need === "askT") { k = "cT"; why.push("عندك أسئلة محددة في التمرين، فجلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك."); alt = "int"; }
  else if (a.need === "askN") { k = "cN"; why.push("عندك أسئلة محددة في التغذية، فجلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل."); alt = "nut"; }
  else if (a.live === "yes") { k = "int"; why.push("الجلسة الحضورية لتصحيح التكنيك موجودة في الباقة المكثفة فقط."); }
  else if (a.follow === "none" && !beg) {
    if (a.need === "food") { k = "cN"; why.push("تبي تغذية بدون متابعة، فجلسة استشارة تغذية تعطيك حسبة السعرات والاقتراحات."); alt = "nut"; }
    else { k = a.need === "both" ? "diyN" : "diy"; why.push("مستواك يسمح إنك تمشي على جدول مخصص بدون متابعة."); alt = a.need === "both" ? "adv" : "bas"; }
  } else {
    // نفس الاختيار للمبتدئ وغيره حسب احتياجه ونوع المتابعة؛ المبتدئ فقط ما نقترح له ملفات بدون متابعة
    if (beg && a.follow === "none") why.push("الملفات بدون متابعة مصممة للمتقدمين، فاقترحنا لك أخف باقة فيها متابعة تناسب البداية.");
    if (a.need === "food") { k = "nut"; why.push("تحتاج تغذية فقط، وباقة التغذية فيها خطة تغذية شاملة وتعلّمك حساب السعرات مع متابعة أسبوعية."); alt = a.follow === "close" ? "int" : "adv"; }
    else if (a.follow === "close") { k = "int"; why.push("تبي متابعة أسبوعية مع مكالمات، والمكثفة فيها 4 مكالمات زوم شهرياً مع المراجعة الأسبوعية."); alt = a.need === "train" ? "bas" : "adv"; }
    else if (a.need === "train") { k = "bas"; why.push("تحتاج تمرين فقط، والأساسية فيها خطة تمرين ومتابعة كل أسبوعين."); alt = beg ? "int" : "adv"; }
    else { k = "adv"; why.push(beg ? "تحتاج تمرين وتغذية مع مراجعة أسبوعية بدون مكالمات زوم." : "عندك خبرة وتحتاج تمرين وتغذية مع مراجعة أسبوعية، بدون زوم."); alt = "int"; }
    if (beg && k !== "int") why.push("إذا تبي متابعة أقرب في البداية (مكالمات زوم وشرح MyFitnessPal) فالمكثفة خيار أقوى.");
  }
  return { k, alt, why };
}
