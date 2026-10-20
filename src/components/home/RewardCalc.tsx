"use client";
import { useState } from "react";

const words = (n: number) => (n === 0 ? "ولا أسبوع" : n === 1 ? "أسبوع واحد" : n === 2 ? "أسبوعين" : n <= 10 ? `${n} أسابيع` : `${n} أسبوعاً`);
const R = 90, C = 2 * Math.PI * R;

/** حاسبة مكافأة الالتزام: 90% خلال 12 أسبوع في باقات 3 أشهر ← 3 أشهر مجاناً (المدربة تمنحها بعد التحقق). تقديرية فقط. */
export default function RewardCalc() {
  const [adh, setAdh] = useState(90);
  const [wk, setWk] = useState(4);
  const left = 12 - wk;
  const verdict = adh < 90 ? `بالتزام ${adh}% ما توصل للمكافأة. رفعه إلى 90% يبقي الفرصة قائمة.`
    : left <= 0 ? "استحقيت 3 أشهر مجاناً، والمدربة تتواصل معك لمنحها."
    : `باقي ${words(left)} بالتزام ${adh}% وتحصل على 3 أشهر مجاناً.`;
  return (
    <div className="v3-meter reveal" data-testid="reward-calc">
      <div className="v3-ring">
        <svg width="200" height="200" viewBox="0 0 210 210" aria-hidden="true">
          <circle className="trk" cx="105" cy="105" r={R} />
          <circle className="bar" cx="105" cy="105" r={R} strokeDasharray={C} strokeDashoffset={C * (1 - adh / 100)} />
        </svg>
        <div className="val"><span className="num">{adh}%</span><small>نسبة الالتزام</small></div>
      </div>
      <div className="v3-ctrl">
        <label>نسبة الالتزام الأسبوعي
          <input type="range" min={50} max={100} step={5} value={adh} onChange={(e) => setAdh(+e.target.value)} />
        </label>
        <label>الأسابيع المنجزة: <span className="num">{words(wk)}</span>
          <input type="range" min={0} max={12} value={wk} onChange={(e) => setWk(+e.target.value)} />
        </label>
        <div className="v3-weeks" aria-hidden="true">{Array.from({ length: 12 }, (_, i) => <i key={i} className={i < wk ? "on" : undefined} />)}</div>
      </div>
      <p className="v3-verdict" aria-live="polite">{verdict}<small>الالتزام = تسجيل تمارين الأسبوع + إرسال المراجعة. المكافأة تمنحها المدربة بعد التحقق.</small></p>
    </div>
  );
}
