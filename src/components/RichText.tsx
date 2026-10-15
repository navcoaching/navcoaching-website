// يعرض نصاً عادياً: الأسطر التي تبدأ بـ "- " تصبح قائمة، والباقي فقرات. لا HTML خام (آمن من الحقن).
export default function RichText({ text, className = "rich" }: { text: string; className?: string }) {
  const blocks: ({ type: "p"; text: string } | { type: "ul"; items: string[] })[] = [];
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith("- ")) {
      const last = blocks[blocks.length - 1];
      if (last?.type === "ul") last.items.push(line.slice(2));
      else blocks.push({ type: "ul", items: [line.slice(2)] });
    } else blocks.push({ type: "p", text: line });
  }
  return (
    <div className={className}>
      {blocks.map((b, i) => b.type === "p" ? <p key={i}>{b.text}</p> : <ul key={i}>{b.items.map((t, j) => <li key={j}>{t}</li>)}</ul>)}
    </div>
  );
}
