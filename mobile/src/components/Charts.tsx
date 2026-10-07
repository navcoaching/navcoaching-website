import { useState } from "react";
import { Text, View, type LayoutChangeEvent } from "react-native";
import Svg, { Circle, G, Line, Polyline, Rect, Text as SvgText } from "react-native-svg";
import { useTheme } from "@/lib/theme";

const fmt = (v: number) => (Math.abs(v) >= 100 ? String(Math.round(v)) : String(Math.round(v * 10) / 10));

function useWidth() {
  const [w, setW] = useState(0);
  return { w, onLayout: (e: LayoutChangeEvent) => setW(e.nativeEvent.layout.width) };
}

/**
 * رسم خطي بسيط: الزمن من اليسار لليمين (مثل رسوم الموقع)، مع آخر قيمة واضحة.
 * القارئ الصوتي يقرأ الملخص النصي (accessibilityLabel) بدل الرسم.
 */
export function LineChart({ points, label, unit, height = 180 }: {
  points: { x: string; y: number }[]; label: string; unit: string; height?: number;
}) {
  const t = useTheme();
  const { w, onLayout } = useWidth();
  if (points.length === 0) return null;
  const L = 40, R = 14, T = 14, B = 26;
  const ys = points.map((p) => p.y);
  let min = Math.min(...ys), max = Math.max(...ys);
  if (min === max) { min -= 1; max += 1; }
  const pad = (max - min) * 0.12; min -= pad; max += pad;
  const x = (i: number) => (points.length === 1 ? L + (w - L - R) / 2 : L + (i * (w - L - R)) / (points.length - 1));
  const y = (v: number) => T + (1 - (v - min) / (max - min)) * (height - T - B);
  const every = Math.max(1, Math.ceil(points.length / 5));
  const last = points[points.length - 1];
  const first = points[0];
  const summary = `${label}: من ${fmt(first.y)} إلى ${fmt(last.y)} ${unit} خلال ${points.length} تمارين`;
  return (
    <View onLayout={onLayout} accessible accessibilityRole="image" accessibilityLabel={summary} style={{ direction: "ltr" }}>
      {w > 0 && (
        <Svg width={w} height={height}>
          {[0, 0.5, 1].map((f) => {
            const v = min + f * (max - min);
            return (
              <G key={f}>
                <Line x1={L} x2={w - R} y1={y(v)} y2={y(v)} stroke={t.line} strokeWidth={1} />
                <SvgText x={L - 6} y={y(v) + 4} fontSize={11} fill={t.muted} textAnchor="end">{fmt(v)}</SvgText>
              </G>
            );
          })}
          {points.length > 1 && (
            <Polyline points={points.map((p, i) => `${x(i)},${y(p.y)}`).join(" ")} fill="none" stroke={t.navy} strokeWidth={2.5} />
          )}
          {points.map((p, i) => <Circle key={i} cx={x(i)} cy={y(p.y)} r={i === points.length - 1 ? 5 : 3} fill={t.navy} />)}
          {points.map((p, i) => (i % every === 0 || i === points.length - 1) && (
            <SvgText key={`l${i}`} x={x(i)} y={height - 8} fontSize={11} fill={t.muted} textAnchor="middle">{p.x}</SvgText>
          ))}
        </Svg>
      )}
      <Text style={{ color: t.muted, fontSize: 13, textAlign: "center" }}>{label} · آخر قيمة {fmt(last.y)} {unit}</Text>
    </View>
  );
}

/** أعمدة عدد التمارين في الأسبوع */
export function WeekBars({ weeks, height = 110 }: { weeks: { label: string; count: number }[]; height?: number }) {
  const t = useTheme();
  const { w, onLayout } = useWidth();
  const max = Math.max(3, ...weeks.map((x) => x.count));
  const B = 20, T = 14;
  const slot = weeks.length ? w / weeks.length : 0;
  const total = weeks.reduce((s, x) => s + x.count, 0);
  return (
    <View onLayout={onLayout} accessible accessibilityRole="image"
      accessibilityLabel={`تمارينك آخر ${weeks.length} أسابيع: ${total} تمريناً، وهذا الأسبوع ${weeks[weeks.length - 1]?.count ?? 0}`} style={{ direction: "ltr" }}>
      {w > 0 && (
        <Svg width={w} height={height}>
          {weeks.map((wk, i) => {
            const h = ((height - B - T) * wk.count) / max;
            const bw = Math.min(28, slot * 0.6);
            const cx = slot * i + slot / 2;
            const current = i === weeks.length - 1;
            return (
              <G key={i}>
                <Rect x={cx - bw / 2} y={height - B - h} width={bw} height={Math.max(h, 2)} rx={4} fill={current ? t.navy : t.cyan} opacity={wk.count ? 1 : 0.35} />
                {wk.count > 0 && <SvgText x={cx} y={height - B - h - 4} fontSize={11} fill={t.text} textAnchor="middle">{wk.count}</SvgText>}
                <SvgText x={cx} y={height - 6} fontSize={10} fill={t.muted} textAnchor="middle">{wk.label}</SvgText>
              </G>
            );
          })}
        </Svg>
      )}
    </View>
  );
}
