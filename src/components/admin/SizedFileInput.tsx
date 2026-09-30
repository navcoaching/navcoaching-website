"use client";
import { useState } from "react";

/**
 * حقل ملف يرفض الملف الكبير في المتصفح قبل الإرسال برسالة واضحة.
 * بدونه يوصل الملف فوق حد الخادم (6 ميجابايت على Netlify) وتطلع صفحة «صار خطأ غير متوقع» بدل رسالة مفهومة.
 */
export default function SizedFileInput({ maxMb = 5, ...props }: React.InputHTMLAttributes<HTMLInputElement> & { maxMb?: number }) {
  const [msg, setMsg] = useState("");
  return (
    <>
      <input {...props} type="file" aria-invalid={msg ? true : undefined}
        onChange={(e) => {
          const f = e.currentTarget.files?.[0];
          const m = f && f.size > maxMb * 1024 * 1024
            ? `حجم الملف ${(f.size / 1024 / 1024).toFixed(1)} ميجابايت، والحد ${maxMb} ميجابايت. اضغطي الملف (مثل ilovepdf.com ← Compress PDF، أو من Canva: تنزيل ← PDF Standard مع «ضغط الملف») ثم ارفعيه.`
            : "";
          e.currentTarget.setCustomValidity(m);
          setMsg(m);
        }} />
      {msg && <span className="alert err small" role="alert" data-testid="file-too-big">{msg}</span>}
    </>
  );
}
