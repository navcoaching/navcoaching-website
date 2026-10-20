"use client";
/** نموذج بحث (GET) يُرسل تلقائياً عند تغيير أي قائمة منسدلة — للفلاتر المتسلسلة */
export default function AutoSubmitForm({ children, className = "filters" }: { children: React.ReactNode; className?: string }) {
  return (
    <form className={className} role="search" onChange={(e) => { if ((e.target as HTMLElement).tagName === "SELECT") e.currentTarget.requestSubmit(); }}>
      {children}
    </form>
  );
}
