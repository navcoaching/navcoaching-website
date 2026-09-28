"use client";
import { useState } from "react";
import { CopyButton } from "@/components/FormBits";
import { generateVapidKeysAction } from "@/app/actions/push";

/** توليد مفتاحي إشعارات الجوال وعرضهما مرة واحدة لنسخهما إلى Netlify */
export default function VapidKeys({ email }: { email: string }) {
  const [k, setK] = useState<{ publicKey: string; privateKey: string } | null>(null);
  const [err, setErr] = useState("");
  const rows: [string, string, string][] = k ? [
    ["NEXT_PUBLIC_VAPID_PUBLIC_KEY", k.publicKey, "عادي"],
    ["VAPID_PRIVATE_KEY", k.privateKey, "سرّي (Secret)"],
    ["VAPID_SUBJECT", `mailto:${email}`, "عادي"],
  ] : [];
  return (
    <div className="stack" style={{ ["--space" as string]: "10px" }} data-testid="vapid">
      {!k ? (
        <button type="button" className="btn btn-sm" style={{ width: "fit-content" }}
          onClick={async () => { const r = await generateVapidKeysAction(); if (r.ok) setK({ publicKey: r.publicKey!, privateKey: r.privateKey! }); else setErr(r.error ?? ""); }}>
          توليد مفاتيح الإشعارات
        </button>
      ) : (
        <>
          <p className="alert warn small" style={{ margin: 0 }}>انسخي القيم الثلاث الآن إلى Netlify ← Site configuration ← Environment variables، ثم أعيدي النشر (Deploy). المفاتيح لا تُحفظ هنا، ولو خرجتي من الصفحة ولّدي مفاتيح جديدة. لا ترسلي المفتاح السرّي لأي أحد.</p>
          {rows.map(([name, value, kind]) => (
            <div key={name} className="vapid-row">
              <div><b dir="ltr">{name}</b> <span className="small muted">({kind})</span></div>
              <code dir="ltr">{value}</code>
              <CopyButton value={value} label="نسخ" />
            </div>
          ))}
        </>
      )}
      {err && <p className="err-msg small">{err}</p>}
    </div>
  );
}
