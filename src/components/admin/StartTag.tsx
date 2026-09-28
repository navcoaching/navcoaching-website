import { PRE_ACTIVE } from "@/lib/status";
import { startPrefLabel } from "@/lib/schedule";

/** تاق موعد البداية للمدربة (قبل التفعيل فقط): «⚡ بأقرب وقت» أولوية، أو «📅 يبدأ …» */
export default function StartTag({ status, pref, today }: { status: string; pref: string | null | undefined; today?: string }) {
  if (!PRE_ACTIVE.includes(status)) return null;
  const l = startPrefLabel(pref, today);
  return <span className={`tag ${l.asap ? "asap" : "later"}`} data-testid="start-tag" style={{ marginInlineStart: 6 }}>{l.text}</span>;
}
