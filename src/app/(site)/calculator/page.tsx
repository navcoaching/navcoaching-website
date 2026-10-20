import type { Metadata } from "next";
import CalculatorForm from "./CalculatorForm";
import IntakeCalculator from "./IntakeCalculator";

export const metadata: Metadata = {
  title: "حاسبة السعرات اليومية وتوازن الطاقة",
  description: "السعرات اليومية حسب الهدف (تنشيف، محافظة، تضخيم) من الوزن وتركيبة الجسم والتمرين، وسعرات المحافظة الفعلية من التغيّر في الجسم بين قياسين.",
};

const FAQ = [
  {
    q: "أي حاسبة أستخدم؟",
    a: "البداية من حاسبة السعرات اليومية: تعطي نقطة بداية من الوزن وتركيبة الجسم والتمرين. بعد 4 أسابيع أو أكثر، ومع وجود قياسين (مثل InBody) وأكل مسجّل، حاسبة توازن الطاقة هي الأنسب لمعرفة سعرات المحافظة الفعلية والتعديل عليها.",
  },
  {
    q: "ليش نسبة الدهون تعطي نتيجة أدق؟",
    a: "العضلات والأعضاء هي اللي تصرف أغلب الطاقة وقت الراحة، والدهون تصرف قليل. لما نعرف الكتلة الخالية من الدهون نحسب الأيض الأساسي منها مباشرة، بدل تقديره من الوزن والطول والعمر.",
  },
  {
    q: "وش الفرق بين هذي الحاسبة والحاسبات العادية؟",
    a: "الحاسبات العادية تقدّر سعراتك بمعادلات عامة (عمر، وزن، طول، نشاط) وقد تخطئ مئات السعرات. هذي الحاسبة تحسب توازن طاقتك الفعلي من التغيّر الحقيقي في جسمك وأكلك الفعلي، فتعطيك سعرات المحافظة الخاصة فيك.",
  },
  {
    q: "من وين أجيب أرقام الكتلة الخالية من الدهون وكتلة الدهون؟",
    a: "من فحصين InBody (أو أي جهاز تحليل جسم) على نفس الجهاز وبنفس الظروف: الصبح، على الريق، وبعد دخول الحمام. المطلوب: الفرق في «كتلة الدهون» بالكيلو (مو النسبة)، والفرق في «الكتلة الخالية من الدهون» (الوزن − كتلة الدهون).",
  },
  {
    q: "كم لازم تكون المدة بين القياسين؟",
    a: "4 أسابيع أو أكثر. المدد القصيرة تتأثر كثيراً بالماء والأكل وأخطاء الجهاز، فتطلع النتيجة غير دقيقة.",
  },
  {
    q: "كيف أحسب سعرات يوم التمرين ويوم الراحة؟",
    a: "من تطبيق تسجيل الأكل خلال نفس الفترة: متوسط السعرات في أيام التمرين، ومتوسطها في أيام الراحة. كل ما كان التسجيل أدق، كانت النتيجة أدق.",
  },
];

export default function Calculator() {
  return (
    <div className="pub">
      <section className="page-hero">
        <div className="wrap">
          <span className="eyebrow">أداة مجانية</span>
          <h1 style={{ fontSize: "clamp(30px,5vw,50px)", marginTop: 12 }}>حاسبة السعرات</h1>
          <p className="lead">السعرات اليومية حسب الهدف من الوزن وتركيبة الجسم والتمرين، أو معرفة سعرات المحافظة الفعلية من التغيّر الحقيقي في الجسم بين قياسين.</p>
          <nav className="row" style={{ marginTop: 18 }} aria-label="الحاسبات">
            <a className="btn btn-ghost btn-sm" href="#daily">حاسبة السعرات اليومية</a>
            <a className="btn btn-ghost btn-sm" href="#energy-balance">حاسبة توازن الطاقة</a>
          </nav>
        </div>
      </section>
      <section className="section tight">
        <div className="wrap stack" style={{ ["--space" as string]: "22px", maxWidth: 900 }}>
          <div id="daily" className="stack" style={{ ["--space" as string]: "12px", scrollMarginTop: 90 }}>
            <h2 style={{ fontSize: 26 }}>حاسبة السعرات اليومية</h2>
            <p className="muted">نقطة بداية لسعراتك حسب هدفك، من وزنك وتركيبة جسمك ونشاطك وتمرينك.</p>
            <IntakeCalculator />
          </div>
          <div id="energy-balance" className="stack" style={{ ["--space" as string]: "12px", scrollMarginTop: 90, marginTop: 24 }}>
            <h2 style={{ fontSize: 26 }}>حاسبة توازن الطاقة</h2>
            <p className="muted">لمن عنده قياسين (مثل فحصي InBody) بينهما 4 أسابيع أو أكثر: تحسب عجزك أو فائضك الفعلي وسعرات المحافظة الحقيقية لجسمك.</p>
            <CalculatorForm />
          </div>
          <p className="alert warn" role="note">
            هذه الحاسبة توفر إرشادات عامة مناسبة لمعظم الأشخاص ولا تعوض عن الاستشارة الطبية. في حال وجود حالة صحية مثل السكري أو ارتفاع ضغط الدم، يجب استشارة مختص قبل إجراء تغييرات كبيرة في نظامك الغذائي أو التمريني.
          </p>
          <div className="stack" style={{ ["--space" as string]: "12px" }}>
            <h2 style={{ fontSize: 24 }}>أسئلة شائعة</h2>
            <div className="faq">
              {FAQ.map((f) => (
                <details key={f.q}>
                  <summary>{f.q}</summary>
                  <div className="ans"><p>{f.a}</p></div>
                </details>
              ))}
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}
