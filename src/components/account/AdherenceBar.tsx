import type { Adherence } from "@/lib/adherence";
import { REWARD_MIN, REWARD_WEEKS } from "@/lib/adherence";

const weeksText = (n: number) => (n === 1 ? "أسبوع واحد" : n === 2 ? "أسبوعين" : n <= 10 ? `${n} أسابيع` : `${n} أسبوعاً`);

/** شريط الالتزام (تمرين + مراجعة أسبوعية) والـ streak وتقدّم مكافأة 3 أشهر */
export default function AdherenceBar({ a, rewarded, compact, coach }: { a: Adherence & { rewarded?: boolean }; rewarded?: boolean; compact?: boolean; coach?: boolean }) {
  const got = rewarded ?? a.rewarded;
  const p = a.avg == null ? null : Math.round(a.avg * 100);
  const tone = p == null ? "" : p >= REWARD_MIN * 100 ? "good" : p >= 70 ? "mid" : "low";
  return (
    <div className={`adherence stack${compact ? " compact" : ""}`} data-testid="adherence" style={{ ["--space" as string]: "8px" }}>
      <div className="row" style={{ justifyContent: "space-between", alignItems: "baseline", gap: 8 }}>
        <b>{coach ? "الالتزام" : "التزامك"} {p == null ? "" : <span className="num" data-testid="adherence-pct">{p}%</span>}</b>
        {a.streak > 0 && <span className="streak" data-testid="streak" title="أسابيع متتالية بالتزام 90% فأكثر">🔥 {weeksText(a.streak)} متتالية</span>}
      </div>
      {p == null ? (
        <p className="small muted" style={{ margin: 0 }}>{coach ? "لا يوجد أسبوع مكتمل بعد." : "يبدأ حساب التزامك بعد أول أسبوع كامل: تسجيل تمارينك + مراجعتك الأسبوعية."}</p>
      ) : (
        <div className={`meter ${tone}`} role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={p} aria-label="نسبة الالتزام">
          <span style={{ inlineSize: `${Math.min(100, p)}%` }} />
          <i style={{ insetInlineStart: `${REWARD_MIN * 100}%` }} aria-hidden="true" />
        </div>
      )}
      {a.rewardable && coach && (
        <p className="small" style={{ margin: 0 }} data-testid="reward-progress">
          {got ? "🎁 مُنحت مكافأة الالتزام لهذا الاشتراك."
            : a.eligible ? "🎉 مستحق لمكافأة 3 أشهر مجاناً (90% فأكثر خلال 12 أسبوعاً)."
            : `أسابيع محسوبة: ${a.scored} من ${REWARD_WEEKS} المطلوبة للمكافأة.`}
        </p>
      )}
      {a.rewardable && !coach && (
        <p className="small" style={{ margin: 0 }} data-testid="reward-progress">
          {got ? "🎁 حصلت على مكافأة الالتزام: 3 أشهر مجاناً. استمر!"
            : a.eligible ? "🎉 أحسنت! التزامك 90% فأكثر خلال 3 أشهر، واستحققت اشتراكاً مجانياً لـ 3 أشهر. ستتواصل معك المدربة."
            : a.weeksLeft > 0 ? `حافظ على التزام 90% فأكثر، وباقي ${weeksText(a.weeksLeft)} وتحصل على 3 أشهر مجاناً 🎁`
            : `التزام 90% فأكثر خلال ${REWARD_WEEKS} أسبوعاً يمنحك 3 أشهر مجاناً. ارفع التزامك في الأسابيع الجاية 💪`}
        </p>
      )}
    </div>
  );
}
