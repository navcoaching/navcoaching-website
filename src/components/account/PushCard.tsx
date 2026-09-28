"use client";
import { useEffect, useState } from "react";
import Link from "next/link";
import { deletePushSubscriptionAction, savePushSubscriptionAction, sendTestPushAction } from "@/app/actions/push";

type State = "loading" | "unsupported" | "ios-install" | "denied" | "off" | "on";

function urlBase64ToUint8Array(base64: string) {
  const padding = "=".repeat((4 - (base64.length % 4)) % 4);
  const raw = atob((base64 + padding).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}
const sameKey = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((x, i) => x === b[i]);
const isIos = () => /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.userAgent.includes("Macintosh") && navigator.maxTouchPoints > 1);
const isStandalone = () => window.matchMedia("(display-mode: standalone)").matches || (navigator as { standalone?: boolean }).standalone === true;
const deviceName = () => {
  const ua = navigator.userAgent;
  return /iPhone/.test(ua) ? "iPhone" : /iPad/.test(ua) || (ua.includes("Macintosh") && navigator.maxTouchPoints > 1) ? "iPad" : /Android/.test(ua) ? "Android" : "متصفح";
};
const MOCK_KEY = "nav_push_mock_endpoint";

/** بطاقة «إشعارات الجوال»: تفعيل/إيقاف الإشعارات على هذا الجهاز + إشعار تجربة */
export default function PushCard({ publicKey, intro }: { publicKey: string; intro?: string }) {
  const mock = publicKey === "mock"; // بيئة الاختبار فقط (PUSH_MOCK)
  const [state, setState] = useState<State>("loading");
  const [endpoint, setEndpoint] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    (async () => {
      if (mock) {
        const e = localStorage.getItem(MOCK_KEY);
        setEndpoint(e); setState(e ? "on" : "off"); return;
      }
      if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) {
        setState(isIos() && !isStandalone() ? "ios-install" : "unsupported"); return;
      }
      if (isIos() && !isStandalone()) { setState("ios-install"); return; }
      if (Notification.permission === "denied") { setState("denied"); return; }
      const reg = await navigator.serviceWorker.getRegistration("/");
      let sub = await reg?.pushManager.getSubscription();
      // اشتراك قديم بمفاتيح سابقة: خوادم Apple/Google ترفضه، فنلغيه ويفعّل من جديد
      const key = sub?.options.applicationServerKey;
      if (sub && key && !sameKey(new Uint8Array(key), urlBase64ToUint8Array(publicKey))) {
        await sub.unsubscribe().catch(() => {});
        await deletePushSubscriptionAction(sub.endpoint).catch(() => {});
        sub = null;
        setMsg({ ok: false, text: "تغيّرت مفاتيح الإشعارات. فعّلها من جديد على هذا الجهاز." });
      }
      // مزامنة الاشتراك مع الموقع (لو انحذف من عندنا يرجع تلقائياً)
      if (sub) await savePushSubscriptionAction(JSON.parse(JSON.stringify(sub)), deviceName()).catch(() => {});
      setEndpoint(sub?.endpoint ?? null);
      setState(sub ? "on" : "off");
    })().catch(() => setState("unsupported"));
  }, [mock]);

  async function enable() {
    setBusy(true); setMsg(null);
    try {
      let sub: unknown;
      if (mock) {
        const e = `https://push.example.test/${crypto.randomUUID()}`;
        sub = { endpoint: e, keys: { p256dh: "B".repeat(40), auth: "A".repeat(16) } };
      } else {
        const perm = await Notification.requestPermission();
        if (perm !== "granted") { setState(perm === "denied" ? "denied" : "off"); return; }
        const reg = (await navigator.serviceWorker.getRegistration("/")) ?? (await navigator.serviceWorker.register("/sw.js", { scope: "/", updateViaCache: "none" }));
        await navigator.serviceWorker.ready;
        const s = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(publicKey) });
        sub = JSON.parse(JSON.stringify(s));
      }
      const r = await savePushSubscriptionAction(sub, deviceName());
      if (!r.ok) { setMsg({ ok: false, text: r.error ?? "تعذّر التفعيل." }); return; }
      const e = (sub as { endpoint: string }).endpoint;
      if (mock) localStorage.setItem(MOCK_KEY, e);
      setEndpoint(e); setState("on");
      setMsg({ ok: true, text: "تم تفعيل الإشعارات على هذا الجهاز ✅" });
    } catch {
      setMsg({ ok: false, text: "تعذّر تفعيل الإشعارات على هذا الجهاز." });
    } finally { setBusy(false); }
  }

  async function disable() {
    setBusy(true); setMsg(null);
    try {
      if (!mock) {
        const reg = await navigator.serviceWorker.getRegistration("/");
        await (await reg?.pushManager.getSubscription())?.unsubscribe();
      } else localStorage.removeItem(MOCK_KEY);
      if (endpoint) await deletePushSubscriptionAction(endpoint);
      setEndpoint(null); setState("off");
      setMsg({ ok: true, text: "تم إيقاف الإشعارات على هذا الجهاز." });
    } finally { setBusy(false); }
  }

  async function test() {
    setBusy(true); setMsg(null);
    const r = await sendTestPushAction().catch(() => ({ ok: false, error: "تعذّر الإرسال." }));
    setMsg(r.ok ? { ok: true, text: "أرسلنا إشعار تجربة. إذا ما ظهر خلال دقيقة، تأكد من إعدادات الإشعارات في جهازك." } : { ok: false, text: r.error ?? "تعذّر الإرسال." });
    setBusy(false);
  }

  return (
    <div className="card stack" aria-labelledby="push-h" data-testid="push-card" data-state={state}>
      <h3 id="push-h" style={{ fontSize: 16 }}>🔔 إشعارات الجوال</h3>
      <p className="small muted" style={{ margin: 0 }}>{intro ?? "تنبيه على جوالك عند رد المدربة، أو تحديث برنامجك، أو موعد المراجعة. بدون أي بيانات صحية."}</p>
      {state === "loading" && <p className="small muted" style={{ margin: 0 }}>…</p>}
      {state === "unsupported" && <p className="small" style={{ margin: 0 }}>هذا المتصفح ما يدعم الإشعارات. جرّب Chrome على أندرويد، أو Safari على الآيفون بعد إضافة التطبيق للشاشة الرئيسية.</p>}
      {state === "ios-install" && (
        <p className="small" style={{ margin: 0 }}>على الآيفون تشتغل الإشعارات بعد إضافة التطبيق للشاشة الرئيسية (iOS 16.4 أو أحدث). <Link href="/install">طريقة الإضافة ←</Link></p>
      )}
      {state === "denied" && <p className="small" style={{ margin: 0 }}>الإشعارات مرفوضة لهذا الموقع. فعّلها من إعدادات الجهاز أو المتصفح، ثم ارجع هنا.</p>}
      {state === "off" && <button type="button" className="btn btn-sm" onClick={enable} disabled={busy}>فعّل الإشعارات على هذا الجهاز</button>}
      {state === "on" && (
        <div className="row" style={{ gap: 8 }}>
          <span className="status ok">مفعّلة على هذا الجهاز</span>
          <button type="button" className="btn btn-ghost btn-sm" onClick={test} disabled={busy}>إرسال تجربة</button>
          <button type="button" className="btn btn-ghost btn-sm" onClick={disable} disabled={busy}>إيقاف</button>
        </div>
      )}
      {msg && <p className={`small ${msg.ok ? "ok-text" : "err-msg"}`} role="status" style={{ margin: 0 }}>{msg.text}</p>}
    </div>
  );
}
