import { Text, View } from "react-native";
import { useTheme } from "@/lib/theme";

type Row = { label: string; got: number; goal: number | null; unit: string };

/** ما أُكل مقابل الهدف لكل قيمة، مع المتبقي (أو الزيادة) بنص واضح */
export function MacroBars({ rows }: { rows: Row[] }) {
  const t = useTheme();
  const r1 = (v: number) => Math.round(v * 10) / 10;
  return (
    <View style={{ gap: 10 }}>
      {rows.map((r) => {
        const pct = r.goal ? Math.min(1, r.got / r.goal) : 0;
        const over = r.goal != null && r.got > r.goal;
        const left = r.goal == null ? null : r1(r.goal - r.got);
        return (
          <View key={r.label} accessible accessibilityLabel={`${r.label}: ${r1(r.got)} من ${r.goal ?? "بدون هدف"} ${r.unit}`}>
            <View style={{ flexDirection: "row", justifyContent: "space-between" }}>
              <Text style={{ color: t.text, fontSize: 15, fontWeight: "600" }}>{r.label}</Text>
              <Text style={{ color: over ? t.err : t.muted, fontSize: 14, fontVariant: ["tabular-nums"] }}>
                {r1(r.got)}{r.goal != null ? ` / ${r.goal}` : ""} {r.unit}{left != null ? (over ? ` · زيادة ${-left}` : ` · باقي ${left}`) : ""}
              </Text>
            </View>
            {r.goal != null && (
              <View style={{ height: 8, borderRadius: 4, backgroundColor: t.line, overflow: "hidden", marginTop: 4 }}>
                <View style={{ width: `${pct * 100}%`, height: 8, backgroundColor: over ? t.err : t.navy }} />
              </View>
            )}
          </View>
        );
      })}
    </View>
  );
}
