/** شريط متحرك بنقاط «ليش Nav» (نص فقط، بدون جافاسكربت). يتوقف مع تفضيل تقليل الحركة. */
export default function Marquee({ items }: { items: string[] }) {
  if (!items.length) return null;
  const row = [...items, ...items];
  return (
    <div className="v3-marquee" aria-hidden="true">
      <div className="v3-track">{row.map((t, i) => <span key={i}>{t}</span>)}</div>
    </div>
  );
}
