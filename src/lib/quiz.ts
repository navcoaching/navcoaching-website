// منقول من منطق اختبار «أي باقة تناسبني؟» في الموقع الحالي كما هو.
export type QuizAnswers = { level: string; need: string; follow: string; live: string };
export const QUIZ_SKU: Record<string, string> = {
  int: "int1", adv: "adv1", bas: "bas1", nut: "nut1", diy: "diy", diyN: "diyN", cT: "cT", cN: "cN",
};

export function recommend(a: QuizAnswers): { k: string; alt?: string; why: string[] } {
  const why: string[] = [];
  let k: string;
  let alt: string | undefined;
  if (a.need === "askT") { k = "cT"; why.push("عندك أسئلة محددة في التمرين، فجلسة وحدة تكفي لتعديل جدولك وتصحيح التكنيك."); alt = "int"; }
  else if (a.need === "askN") { k = "cN"; why.push("عندك أسئلة محددة في التغذية، فجلسة وحدة تكفي لحسبة سعراتك ونصائح الأكل."); alt = "nut"; }
  else if (a.live === "yes") { k = "int"; why.push("الجلسة الحضورية لتصحيح التكنيك موجودة في الباقة المكثفة فقط."); }
  else if (a.level === "beg") {
    k = "int";
    why.push("الباقة المكثفة هي الأفضل للمبتدئين: متابعة أسبوعية و4 مكالمات زوم وشرح MyFitnessPal.");
    if (a.follow === "none") why.push("الملفات بدون متابعة مصممة للمتقدمين، والبداية الصحيحة تحتاج أحد يتابع معك.");
    if (a.need === "train" || a.need === "food") why.push("المكثفة تشمل التمرين والتغذية معاً، وهذا يختصر عليك الطريق في البداية.");
    alt = a.need === "food" ? "nut" : a.need === "train" ? "bas" : "adv";
  } else if (a.follow === "none") {
    if (a.need === "food") { k = "cN"; why.push("تبي تغذية بدون متابعة، فجلسة استشارة تغذية تعطيك حسبة السعرات والاقتراحات."); alt = "nut"; }
    else { k = a.need === "both" ? "diyN" : "diy"; why.push("مستواك يسمح إنك تمشي على جدول مخصص بدون متابعة."); alt = a.need === "both" ? "adv" : "bas"; }
  } else if (a.need === "food") { k = "nut"; why.push("تحتاج تغذية فقط، وباقة التغذية فيها خطة تغذية شاملة وتعلّمك حساب السعرات مع متابعة أسبوعية."); alt = "adv"; }
  else if (a.follow === "close") { k = "int"; why.push("تبي متابعة أسبوعية مع مكالمات، والمكثفة فيها 4 مكالمات زوم شهرياً مع المراجعة الأسبوعية."); alt = a.need === "train" ? "bas" : "adv"; }
  else if (a.need === "train") { k = "bas"; why.push("تحتاج تمرين فقط، والأساسية فيها خطة تمرين ومتابعة كل أسبوعين."); alt = "adv"; }
  else { k = "adv"; why.push("عندك خبرة وتحتاج تمرين وتغذية مع مراجعة أسبوعية، بدون زوم."); alt = "int"; }
  return { k, alt, why };
}
