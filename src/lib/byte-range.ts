/** ترويسة Range لنطاق واحد (bytes=a-b أو a- أو -N) ← البداية والنهاية شاملة، null بدونها، "invalid" لنطاق خارج الملف */
export function byteRange(header: string | null, size: number): { start: number; end: number } | null | "invalid" {
  const m = /^bytes=(\d*)-(\d*)$/.exec(header ?? "");
  if (!m || (!m[1] && !m[2])) return null;
  let start = 0, end = size - 1;
  if (m[1]) { start = Number(m[1]); if (m[2]) end = Math.min(Number(m[2]), end); }
  else start = Math.max(0, size - Number(m[2]));
  return start > end ? "invalid" : { start, end };
}
