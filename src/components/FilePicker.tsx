"use client";
import { useState } from "react";

/**
 * حقل اختيار ملف بمنطقة كبيرة قابلة للضغط، يعمل على الآيباد والآيفون.
 * حقل الملف الأصلي في Safari على iOS لا يستجيب إلا عند الضغط على زره الصغير بالضبط، فنغطي المنطقة كاملة
 * بالحقل نفسه (شفاف) حتى يفتح اختيار الملفات من أي مكان فيها، ونعرض اسم الملف المختار.
 * ويرفض الملف الكبير في المتصفح برسالة واضحة (بدون هذا يوصل الملف فوق حد الخادم 6 ميجابايت وتطلع صفحة خطأ).
 */
export default function FilePicker({ maxMb = 5, hint, ...props }: React.InputHTMLAttributes<HTMLInputElement> & { maxMb?: number; hint?: string }) {
  const [names, setNames] = useState<string[]>([]);
  const [msg, setMsg] = useState("");
  return (
    <>
      <div className={`file-picker${names.length ? " has-file" : ""}${msg ? " bad" : ""}`}>
        <input {...props} type="file" aria-invalid={msg ? true : undefined}
          onChange={(e) => {
            const files = Array.from(e.currentTarget.files ?? []);
            const big = files.find((f) => f.size > maxMb * 1024 * 1024);
            const m = big
              ? `حجم الملف ${(big.size / 1024 / 1024).toFixed(1)} ميجابايت، والحد ${maxMb} ميجابايت. اضغطي الملف (مثل ilovepdf.com ← Compress PDF، أو من Canva: تنزيل ← PDF Standard مع «ضغط الملف») ثم ارفعيه.`
              : "";
            e.currentTarget.setCustomValidity(m);
            setMsg(m);
            setNames(files.map((f) => f.name));
            props.onChange?.(e);
          }} />
        <span className="file-picker-face" aria-hidden="true">
          <b>{names.length ? `📎 ${names.join("، ")}` : "📎 اضغط لاختيار ملف"}</b>
          <span className="small muted">{names.length ? "اضغط للتغيير" : hint ?? `حتى ${maxMb} ميجابايت`}</span>
        </span>
      </div>
      {msg && <span className="alert err small" role="alert" data-testid="file-too-big">{msg}</span>}
    </>
  );
}
