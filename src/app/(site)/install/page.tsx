import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "إضافة الموقع كتطبيق على جوالك",
  description: "خطوات إضافة Nav Coaching إلى الشاشة الرئيسية في iPhone وأندرويد.",
};

/* رسومات توضيحية مبسطة (ليست لقطات شاشة حقيقية) — شكل الأزرار قد يختلف قليلاً حسب إصدار النظام */
const C = { frame: "#07142a", screen: "#f3f6fa", hi: "#1fb8e8", line: "#9aa6b8" };

function Phone({ children, label }: { children: React.ReactNode; label: string }) {
  return (
    <svg viewBox="0 0 160 240" width="160" height="240" role="img" aria-label={label} className="install-art">
      <rect x="4" y="4" width="152" height="232" rx="22" fill="none" stroke="var(--text)" strokeWidth="4" />
      <rect x="12" y="14" width="136" height="212" rx="14" fill={C.screen} />
      {children}
    </svg>
  );
}
const Lines = ({ y = 44 }: { y?: number }) => (
  <g stroke={C.line} strokeWidth="5" strokeLinecap="round">
    <line x1="28" y1={y} x2="132" y2={y} /><line x1="28" y1={y + 16} x2="110" y2={y + 16} /><line x1="28" y1={y + 32} x2="120" y2={y + 32} />
  </g>
);
const Ring = ({ cx, cy, r = 13 }: { cx: number; cy: number; r?: number }) => (
  <circle cx={cx} cy={cy} r={r} fill="none" stroke={C.hi} strokeWidth="3.5" />
);

const IosShare = () => (
  <Phone label="زر المشاركة أسفل شاشة Safari">
    <Lines />
    <rect x="12" y="192" width="136" height="34" fill="#e3e8ef" />
    <g stroke={C.frame} strokeWidth="2.5" fill="none" strokeLinecap="round">
      <rect x="73" y="204" width="14" height="14" rx="2" /><line x1="80" y1="197" x2="80" y2="211" /><polyline points="75,201 80,196 85,201" />
    </g>
    <Ring cx={80} cy={208} r={16} />
  </Phone>
);
const IosAdd = () => (
  <Phone label="خيار «إضافة إلى الشاشة الرئيسية» في قائمة المشاركة">
    <rect x="12" y="92" width="136" height="134" fill="#fff" />
    {["نسخ", "إضافة إلى الشاشة الرئيسية", "إضافة إشارة مرجعية"].map((t, i) => (
      <g key={t}>
        <text x="136" y={124 + i * 32} fontSize="10" textAnchor="end" fill={C.frame} fontFamily="inherit">{t}</text>
        {i === 1 && <rect x="20" y={108 + i * 32} width="120" height="24" rx="8" fill="none" stroke={C.hi} strokeWidth="3" />}
      </g>
    ))}
    <g stroke={C.frame} strokeWidth="2" fill="none"><rect x="26" y="146" width="14" height="14" rx="3" /><line x1="33" y1="149" x2="33" y2="157" /><line x1="29" y1="153" x2="37" y2="153" /></g>
  </Phone>
);
const Confirm = ({ label, btn }: { label: string; btn: string }) => (
  <Phone label={label}>
    <rect x="12" y="14" width="136" height="36" fill="#e3e8ef" />
    <text x="30" y="37" fontSize="11" fill={C.hi} fontWeight="700" fontFamily="inherit">{btn}</text>
    <Ring cx={40} cy={33} r={17} />
    <rect x="58" y="70" width="44" height="44" rx="10" fill="#07142a" />
    <text x="80" y="98" fontSize="13" textAnchor="middle" fill="#1fb8e8" fontWeight="700" fontFamily="inherit">NAV</text>
    <text x="80" y="132" fontSize="10" textAnchor="middle" fill={C.frame} fontFamily="inherit">Nav Coaching</text>
  </Phone>
);
const AndroidMenu = () => (
  <Phone label="زر القائمة بثلاث نقاط أعلى Chrome">
    <rect x="12" y="14" width="136" height="30" fill="#e3e8ef" />
    <rect x="40" y="21" width="84" height="16" rx="8" fill="#fff" />
    <g fill={C.frame}><circle cx="24" cy="23" r="2.4" /><circle cx="24" cy="29" r="2.4" /><circle cx="24" cy="35" r="2.4" /></g>
    <Ring cx={24} cy={29} r={12} />
    <Lines y={70} />
  </Phone>
);
const AndroidAdd = () => (
  <Phone label="خيار «إضافة إلى الشاشة الرئيسية» أو «تثبيت التطبيق» في قائمة Chrome">
    <Lines y={70} />
    <rect x="16" y="20" width="100" height="128" rx="8" fill="#fff" stroke="#d5dbe4" />
    {["علامة تبويب جديدة", "السجل", "تثبيت التطبيق", "الإعدادات"].map((t, i) => (
      <g key={t}>
        <text x="108" y={44 + i * 28} fontSize="9.5" textAnchor="end" fill={C.frame} fontFamily="inherit">{t}</text>
        {i === 2 && <rect x="21" y={29 + i * 28} width="90" height="22" rx="7" fill="none" stroke={C.hi} strokeWidth="3" />}
      </g>
    ))}
  </Phone>
);

const IOS = [
  { art: <IosShare />, text: <>افتح <b>navcoaching.com</b> في متصفح <b>Safari</b>، ثم اضغط زر <b>المشاركة</b> (مربع وسهم للأعلى) أسفل الشاشة. في iPad تجده أعلى الشاشة.</> },
  { art: <IosAdd />, text: <>انزل في القائمة واختر <b>«إضافة إلى الشاشة الرئيسية»</b>. إذا ما ظهر، اضغط «تعديل الإجراءات» وفعّله.</> },
  { art: <Confirm label="زر «إضافة» في أعلى الشاشة" btn="إضافة" />, text: <>اضغط <b>«إضافة»</b> أعلى الشاشة. بتلقى أيقونة Nav على شاشتك الرئيسية، ويفتح منها حسابك مباشرة.</> },
];
const ANDROID = [
  { art: <AndroidMenu />, text: <>افتح <b>navcoaching.com</b> في متصفح <b>Chrome</b>، ثم اضغط زر <b>القائمة ⋮</b> (ثلاث نقاط) أعلى الشاشة.</> },
  { art: <AndroidAdd />, text: <>اختر <b>«تثبيت التطبيق»</b> أو <b>«إضافة إلى الشاشة الرئيسية»</b> (الاسم يختلف حسب إصدار الجوال).</> },
  { art: <Confirm label="زر «تثبيت» في نافذة التأكيد" btn="تثبيت" />, text: <>أكّد بالضغط على <b>«تثبيت»</b> أو <b>«إضافة»</b>. تظهر أيقونة Nav على الشاشة الرئيسية أو قائمة التطبيقات.</> },
];

export default function InstallGuide() {
  return (
    <section className="section tight">
      <div className="wrap stack" style={{ ["--space" as string]: "20px", maxWidth: 900 }}>
        <div>
          <span className="eyebrow">دليل سريع</span>
          <h1 style={{ fontSize: "clamp(26px,4vw,36px)", marginTop: 8 }}>أضف الموقع كتطبيق على جوالك</h1>
          <p className="muted">أيقونة على شاشتك الرئيسية تفتح حسابك بضغطة، بدون تحميل من المتجر. الموقع نفسه يفتح بملء الشاشة ويحتاج اتصال إنترنت، والتنبيهات تصلك بالبريد (وواتساب عند تفعيله) وليس كإشعارات من التطبيق.</p>
        </div>
        {[["ios", "iPhone و iPad (متصفح Safari)", IOS], ["android", "أندرويد (متصفح Chrome)", ANDROID]].map(([id, title, steps]) => (
          <div key={id as string} className="card stack" aria-labelledby={`${id}-h`}>
            <h2 id={`${id}-h`} style={{ fontSize: 22 }}>{title as string}</h2>
            <ol className="install-steps">
              {(steps as typeof IOS).map((s, i) => (
                <li key={i}>
                  <span className="n" aria-hidden="true">{i + 1}</span>
                  {s.art}
                  <p>{s.text}</p>
                </li>
              ))}
            </ol>
          </div>
        ))}
        <p className="small muted">في iPhone تعمل الإضافة من Safari فقط. الرسومات توضيحية، وقد يختلف شكل القوائم حسب إصدار النظام.</p>
        <Link href="/account" className="btn" style={{ width: "fit-content" }}>رجوع لحسابي</Link>
      </div>
    </section>
  );
}
