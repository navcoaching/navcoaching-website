// دالة مجدولة من Netlify: تستدعي مسار التذكيرات في الموقع كل ساعة.
// تحتاج متغير البيئة CRON_SECRET (نفس القيمة في الموقع). URL يضبطه Netlify تلقائياً.
export default async () => {
  const base = process.env.URL;
  if (!base || !process.env.CRON_SECRET) return new Response("missing URL or CRON_SECRET", { status: 500 });
  const res = await fetch(`${base}/api/cron/reminders`, { method: "POST", headers: { "x-cron-secret": process.env.CRON_SECRET } });
  const text = await res.text();
  console.log("reminders", res.status, text.slice(0, 500));
  return new Response(text, { status: res.status });
};

export const config = { schedule: "7 * * * *" };
