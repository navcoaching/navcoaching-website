import Link from "next/link";
import { requireCoach } from "@/lib/session";
import ImportForm from "./ImportForm";

/** استيراد قالب من ملف Markdown: رفع، ثم مراجعة الأسماء غير المطابقة إن وُجدت، ثم إنشاء القالب */
export default async function ImportTemplate() {
  await requireCoach();
  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 820 }}>
      <nav className="small"><Link href="/admin/templates">قوالب البرامج</Link> / استيراد من ملف</nav>
      <h1>استيراد قالب من ملف</h1>
      <ol className="stack" style={{ ["--space" as string]: "8px", paddingInlineStart: 20 }}>
        <li>ارفعي ملف البرنامج (‎.md‎) كما يرجع من الذكاء الاصطناعي، أو الصقي نصه. يُفهم جدول الأيام مع أعمدة «الأسبوع 1–2» و«3 × 8–12» وRIR والإيقاع والراحة والملاحظات.</li>
        <li>إذا في أسماء تمارين غير موجودة في مكتبتك بنفس الاسم، تختارين المقابل لكل اسم مرة واحدة، ويُحفظ للملفات القادمة.</li>
        <li>يُنشأ قالب جديد بأيامه وتمارينه وخطة كل أسبوع، وأقسام مثل قواعد السلامة والإحماء تصير تعليمات البلوك. ثم يفتح في المحرر للمراجعة.</li>
      </ol>
      <p className="small muted">لا يُنشأ شيء إذا في الملف خطأ. تحسين اختياري: <a href="/admin/templates/import/guide" download data-testid="import-guide">ملف الدليل</a> فيه أسماء تمارين مكتبتك كما هي، أرفقيه مع طلب البرنامج فتطابق الأسماء من أول مرة.</p>
      <div className="card"><ImportForm /></div>
    </div>
  );
}
