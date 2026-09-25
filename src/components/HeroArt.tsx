// رسم توضيحي مملوك للمشروع (SVG): قرص أوزان وبار ودمبل بخطوط الشعار المائلة.
// يُستخدم عند عدم توفر صورة مرخّصة للواجهة، وخفيف جداً على الاتصال الضعيف.
export default function HeroArt() {
  return (
    <div className="hero-art" aria-hidden="true">
      <svg viewBox="0 0 480 480" fill="none">
        <defs>
          <linearGradient id="g1" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor="#4CC5ED" stopOpacity="0.9" />
            <stop offset="1" stopColor="#284DA0" stopOpacity="0.9" />
          </linearGradient>
        </defs>
        {/* قرص الأوزان */}
        <g className="spin-slow">
          <circle cx="240" cy="230" r="170" stroke="url(#g1)" strokeWidth="2" opacity="0.5" />
          <circle cx="240" cy="230" r="150" stroke="#4CC5ED" strokeOpacity="0.25" strokeWidth="26" />
          <circle cx="240" cy="230" r="112" stroke="#4CC5ED" strokeOpacity="0.55" strokeWidth="2" strokeDasharray="4 10" />
          <circle cx="240" cy="230" r="34" fill="#07142a" stroke="#4CC5ED" strokeWidth="3" />
          <circle cx="240" cy="230" r="12" fill="#4CC5ED" />
        </g>
        {/* خطوط N المائلة */}
        <g className="float" opacity="0.95">
          <path d="M96 332 L150 332 L226 128 L172 128 Z" fill="#4CC5ED" />
          <path d="M176 332 L230 332 L306 128 L252 128 Z" fill="#4CC5ED" opacity="0.55" />
          <path d="M256 332 L310 332 L386 128 L332 128 Z" fill="#4CC5ED" opacity="0.25" />
        </g>
        {/* دمبل */}
        <g className="float d2" transform="translate(250 360) rotate(-12)">
          <rect x="0" y="16" width="150" height="10" rx="5" fill="#EAF2FB" />
          <rect x="6" y="0" width="22" height="42" rx="6" fill="#284DA0" stroke="#4CC5ED" strokeWidth="2" />
          <rect x="30" y="5" width="14" height="32" rx="5" fill="#284DA0" stroke="#4CC5ED" strokeWidth="2" />
          <rect x="106" y="5" width="14" height="32" rx="5" fill="#284DA0" stroke="#4CC5ED" strokeWidth="2" />
          <rect x="122" y="0" width="22" height="42" rx="6" fill="#284DA0" stroke="#4CC5ED" strokeWidth="2" />
        </g>
      </svg>
    </div>
  );
}
