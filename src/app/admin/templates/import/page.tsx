import Link from "next/link";
import { requireCoach } from "@/lib/session";
import ActionForm from "@/components/admin/ActionForm";
import { importTemplateAction } from "@/app/actions/training";

/** استيراد قالب من ملف: دليل الصيغة للذكاء الاصطناعي، ثم رفع الملف فيُبنى القالب تلقائياً */
export default async function ImportTemplate() {
  await requireCoach();
  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 820 }}>
      <nav className="small"><Link href="/admin/templates">قوالب البرامج</Link> / استيراد من ملف</nav>
      <h1>استيراد قالب من ملف</h1>
      <ol className="stack" style={{ ["--space" as string]: "8px", paddingInlineStart: 20 }}>
        <li>نزّلي <a href="/admin/templates/import/guide" download data-testid="import-guide">ملف الدليل</a>: فيه الصيغة ومثال وأسماء تمارين مكتبتك كما هي.</li>
        <li>أعطيه للذكاء الاصطناعي مع طلبك، مثل: «صمم برنامج 4 أيام للنادي بهذه الصيغة».</li>
        <li>ارفعي الملف اللي يرجعه (أو الصقي نصه)، فيُنشأ قالب جديد بأيامه وتمارينه وخطة كل أسبوع.</li>
      </ol>
      <p className="small muted">لا يُنشأ شيء إذا في الملف خطأ أو تمرين غير موجود في المكتبة: تظهر الأخطاء بمكانها مع أقرب اسم. بعد الإنشاء يفتح القالب في المحرر للمراجعة والتعديل.</p>
      <div className="card">
        <ActionForm action={importTemplateAction} className="form import-form" submit="استيراد وإنشاء القالب">
          <div className="field"><label htmlFor="imp-file">الملف (‎.md‎)</label>
            <input id="imp-file" name="file" type="file" accept=".md,.markdown,.txt,text/markdown,text/plain" data-testid="import-file" /></div>
          <div className="field"><label htmlFor="imp-text">أو الصقي النص</label>
            <textarea id="imp-text" name="text" rows={10} maxLength={200000} dir="ltr" placeholder={"# اسم القالب\n- الأسابيع: 5\n- المكان: النادي\n\n## اليوم 1: UPPER\n| التمرين | الأسبوع 1 | … |"} /></div>
        </ActionForm>
      </div>
    </div>
  );
}
