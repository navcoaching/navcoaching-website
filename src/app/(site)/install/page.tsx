import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "إضافة الموقع كتطبيق على جوالك",
  description: "خطوات إضافة Nav Coaching إلى الشاشة الرئيسية في iPhone وأندرويد.",
};

/* رسومات توضيحية مبسطة (ليست لقطات شاشة حقيقية) — شكل الأزرار قد يختلف قليلاً حسب إصدار النظام */
const C = { ink: "#07142a", screen: "#f3f6fa", bar: "#e1e7ef", hi: "#1fb8e8", hiBg: "#dff4fc", line: "#b4bfcd", muted: "#5b6b80" };
const F = "IBM Plex Sans Arabic, Tahoma, sans-serif";

/** إطار جوال بسيط. النصوص داخل الرسم RTL: textAnchor="start" يعني المحاذاة من اليمين */
function Phone({ children, label }: { children: React.ReactNode; label: string }) {
  return (
    <svg viewBox="0 0 220 360" width="220" height="360" role="img" aria-label={label} className="install-art" style={{ direction: "rtl" }} fontFamily={F}>
      <rect x="6" y="6" width="208" height="348" rx="30" fill="#fff" stroke="var(--text)" strokeWidth="5" />
      <rect x="16" y="18" width="188" height="324" rx="20" fill={C.screen} />
      {children}
    </svg>
  );
}
const T = ({ x, y, size = 14, bold, color = C.ink, children }: { x: number; y: number; size?: number; bold?: boolean; color?: string; children: React.ReactNode }) => (
  <text x={x} y={y} fontSize={size} fontWeight={bold ? 700 : 500} fill={color} textAnchor="start">{children}</text>
);
const Lines = ({ y }: { y: number }) => (
  <g stroke={C.line} strokeWidth="7" strokeLinecap="round">
    <line x1="40" y1={y} x2="180" y2={y} /><line x1="70" y1={y + 22} x2="180" y2={y + 22} /><line x1="55" y1={y + 44} x2="180" y2={y + 44} />
  </g>
);
const Ring = ({ cx, cy, r = 22 }: { cx: number; cy: number; r?: number }) => (
  <circle cx={cx} cy={cy} r={r} fill="none" stroke={C.hi} strokeWidth="4.5" />
);
const Tap = ({ x, y, text }: { x: number; y: number; text: string }) => (
  <g>
    <rect x={x - 46} y={y - 17} width="92" height="28" rx="14" fill={C.hi} />
    <text x={x} y={y + 2} fontSize="13" fontWeight={700} fill={C.ink} textAnchor="middle">{text}</text>
  </g>
);
const AppIcon = ({ y = 120 }: { y?: number }) => (
  <g>
    <rect x="80" y={y} width="60" height="60" rx="14" fill={C.ink} />
    <text x="110" y={y + 37} fontSize="17" fontWeight={700} fill={C.hi} textAnchor="middle" fontFamily="Arial, sans-serif">NAV</text>
    <text x="110" y={y + 84} fontSize="14" fontWeight={600} fill={C.ink} textAnchor="middle" fontFamily="Arial, sans-serif">Nav Coaching</text>
  </g>
);

const IosShare = () => (
  <Phone label="زر المشاركة أسفل شاشة Safari">
    <Lines y={70} />
    <Tap x={110} y={230} text="اضغط هنا ↓" />
    <rect x="16" y="282" width="188" height="60" fill={C.bar} />
    <g stroke={C.ink} strokeWidth="3.2" fill="none" strokeLinecap="round" strokeLinejoin="round">
      <path d="M100 300 h-6 v24 h32 v-24 h-6" /><line x1="110" y1="290" x2="110" y2="314" /><polyline points="102,297 110,289 118,297" />
    </g>
    <Ring cx={110} cy={308} r={24} />
  </Phone>
);
const IosAdd = () => (
  <Phone label="خيار «إضافة إلى الشاشة الرئيسية» في قائمة المشاركة">
    <rect x="16" y="120" width="188" height="222" rx="0" fill="#fff" />
    {["نسخ", "إضافة إلى الشاشة الرئيسية", "إضافة إشارة مرجعية"].map((t, i) => {
      const y = 140 + i * 58;
      const on = i === 1;
      return (
        <g key={t}>
          {on && <rect x="22" y={y - 4} width="176" height="50" rx="12" fill={C.hiBg} stroke={C.hi} strokeWidth="4" />}
          <T x={184} y={y + 27} size={14} bold={on}>{t}</T>
        </g>
      );
    })}
  </Phone>
);
const Confirm = ({ label, add, cancel }: { label: string; add: string; cancel: string }) => (
  <Phone label={label}>
    <rect x="16" y="18" width="188" height="56" fill={C.bar} />
    <T x={188} y={52} color={C.muted}>{cancel}</T>
    <text x={48} y={52} fontSize="16" fontWeight={700} fill="#0a7ea8" textAnchor="middle">{add}</text>
    <Ring cx={48} cy={46} r={26} />
    <AppIcon y={140} />
  </Phone>
);
const AndroidConfirm = () => (
  <Phone label="نافذة التأكيد وزر «تثبيت»">
    <rect x="16" y="18" width="188" height="324" rx="20" fill="#00000022" />
    <rect x="28" y="96" width="164" height="196" rx="18" fill="#fff" />
    <text x="110" y="128" fontSize="15" fontWeight={700} fill={C.ink} textAnchor="middle">تثبيت التطبيق؟</text>
    <rect x="86" y="144" width="48" height="48" rx="12" fill={C.ink} />
    <text x="110" y="174" fontSize="14" fontWeight={700} fill={C.hi} textAnchor="middle" fontFamily="Arial, sans-serif">NAV</text>
    <text x="110" y="214" fontSize="13" fontWeight={600} fill={C.ink} textAnchor="middle" fontFamily="Arial, sans-serif">Nav Coaching</text>
    <text x="150" y="262" fontSize="14" fill={C.muted} textAnchor="middle">إلغاء</text>
    <text x="70" y="262" fontSize="15" fontWeight={700} fill="#0a7ea8" textAnchor="middle">تثبيت</text>
    <Ring cx={70} cy={257} r={26} />
  </Phone>
);
const AndroidMenu = () => (
  <Phone label="زر القائمة بثلاث نقاط أعلى Chrome">
    <rect x="16" y="18" width="188" height="56" fill={C.bar} />
    <rect x="66" y="32" width="124" height="28" rx="14" fill="#fff" />
    <text x="128" y="51" fontSize="11" fill={C.muted} textAnchor="middle" fontFamily="Arial, sans-serif">navcoaching.com</text>
    <g fill={C.ink}><circle cx="36" cy="37" r="3.6" /><circle cx="36" cy="46" r="3.6" /><circle cx="36" cy="55" r="3.6" /></g>
    <Ring cx={36} cy={46} r={20} />
    <Tap x={78} y={104} text="↑ اضغط هنا" />
    <Lines y={150} />
  </Phone>
);
const AndroidAdd = () => (
  <Phone label="خيار «تثبيت التطبيق» أو «إضافة إلى الشاشة الرئيسية» في قائمة Chrome">
    <Lines y={200} />
    <rect x="24" y="28" width="150" height="220" rx="12" fill="#fff" stroke="#cfd7e2" strokeWidth="2" />
    {["علامة تبويب جديدة", "السجل", "تثبيت التطبيق", "الإعدادات"].map((t, i) => {
      const y = 40 + i * 50;
      const on = i === 2;
      return (
        <g key={t}>
          {on && <rect x="30" y={y} width="138" height="42" rx="10" fill={C.hiBg} stroke={C.hi} strokeWidth="4" />}
          <T x={158} y={y + 27} size={14} bold={on}>{t}</T>
        </g>
      );
    })}
  </Phone>
);

const IOS = [
  { art: <IosShare />, text: <>افتح <b>navcoaching.com</b> في متصفح <b>Safari</b>، ثم اضغط زر <b>المشاركة</b> (مربع وسهم للأعلى) أسفل الشاشة. في iPad تجده أعلى الشاشة.</> },
  { art: <IosAdd />, text: <>انزل في القائمة واختر <b>«إضافة إلى الشاشة الرئيسية»</b>. إذا ما ظهر، اضغط «تعديل الإجراءات» وفعّله.</> },
  { art: <Confirm label="زر «إضافة» في أعلى الشاشة" add="إضافة" cancel="إلغاء" />, text: <>اضغط <b>«إضافة»</b> أعلى الشاشة. بتلقى أيقونة Nav على شاشتك الرئيسية، ويفتح منها حسابك مباشرة.</> },
];
const ANDROID = [
  { art: <AndroidMenu />, text: <>افتح <b>navcoaching.com</b> في متصفح <b>Chrome</b>، ثم اضغط زر <b>القائمة ⋮</b> (ثلاث نقاط) أعلى الشاشة.</> },
  { art: <AndroidAdd />, text: <>اختر <b>«تثبيت التطبيق»</b> أو <b>«إضافة إلى الشاشة الرئيسية»</b> (الاسم يختلف حسب إصدار الجوال).</> },
  { art: <AndroidConfirm />, text: <>أكّد بالضغط على <b>«تثبيت»</b> أو <b>«إضافة»</b>. تظهر أيقونة Nav على الشاشة الرئيسية أو قائمة التطبيقات.</> },
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
