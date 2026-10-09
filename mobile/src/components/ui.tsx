import type React from "react";
import type { ReactNode } from "react";
import { Ionicons } from "@expo/vector-icons";
import { ActivityIndicator, Pressable, StyleSheet, Text, TextInput, View, type TextInputProps } from "react-native";
import { useTheme } from "@/lib/theme";

export function Card({ children }: { children: ReactNode }) {
  const t = useTheme();
  return <View style={[s.card, { backgroundColor: t.surface, borderColor: t.line }]}>{children}</View>;
}

export function Title({ children }: { children: ReactNode }) {
  const t = useTheme();
  return <Text style={[s.title, { color: t.heading }]}>{children}</Text>;
}

export function Body({ children, muted }: { children: ReactNode; muted?: boolean }) {
  const t = useTheme();
  return <Text style={[s.body, { color: muted ? t.muted : t.text }]}>{children}</Text>;
}

export function ErrorText({ children }: { children: ReactNode }) {
  const t = useTheme();
  return <Text style={[s.error, { color: t.err, backgroundColor: t.errBg }]} accessibilityRole="alert">{children}</Text>;
}

/** زر بارتفاع 50 نقطة على الأقل (أكبر من حد Apple 44) لسهولة الضغط في النادي */
export function Button({ title, onPress, busy, disabled, variant = "primary" }: {
  title: string; onPress: () => void; busy?: boolean; disabled?: boolean; variant?: "primary" | "ghost";
}) {
  const t = useTheme();
  const off = disabled || busy;
  const primary = variant === "primary";
  return (
    <Pressable
      onPress={onPress}
      disabled={off}
      accessibilityRole="button"
      accessibilityState={{ disabled: !!off, busy: !!busy }}
      style={({ pressed }) => [
        s.button,
        primary ? { backgroundColor: t.navy } : { borderColor: t.line, borderWidth: 1 },
        (pressed || off) && { opacity: 0.6 },
      ]}
    >
      {busy ? <ActivityIndicator color={primary ? t.onAccent : t.text} /> : (
        <Text style={[s.buttonText, { color: primary ? t.onAccent : t.text }]}>{title}</Text>
      )}
    </Pressable>
  );
}

export function Field(props: TextInputProps & { label: string }) {
  const t = useTheme();
  const { label, style, ...rest } = props;
  return (
    <View style={{ gap: 6 }}>
      <Text style={[s.label, { color: t.text }]}>{label}</Text>
      <TextInput
        placeholderTextColor={t.muted}
        {...rest}
        style={[s.input, { color: t.text, borderColor: t.line, backgroundColor: t.paper }, style]}
      />
    </View>
  );
}

const s = StyleSheet.create({
  card: { borderWidth: 1, borderRadius: 16, padding: 18, gap: 10 },
  title: { fontSize: 20, fontWeight: "700", textAlign: "left" },
  body: { fontSize: 16, lineHeight: 24, textAlign: "left" },
  error: { fontSize: 15, padding: 10, borderRadius: 10, textAlign: "left", overflow: "hidden" },
  label: { fontSize: 15, fontWeight: "600", textAlign: "left" },
  input: { minHeight: 50, borderWidth: 1, borderRadius: 12, paddingHorizontal: 14, fontSize: 17, textAlign: "right" },
  button: { minHeight: 50, borderRadius: 12, alignItems: "center", justifyContent: "center", paddingHorizontal: 16 },
  buttonText: { fontSize: 17, fontWeight: "700" },
  chip: { borderWidth: 1, borderRadius: 999, paddingHorizontal: 14, minHeight: 36, justifyContent: "center" },
});

/** زر أيقونة بمساحة لمس 44×44 على الأقل */
export function IconButton({ name, label, onPress, color }: { name: React.ComponentProps<typeof Ionicons>["name"]; label: string; onPress: () => void; color?: string }) {
  const t = useTheme();
  return (
    <Pressable onPress={onPress} accessibilityRole="button" accessibilityLabel={label} hitSlop={6}
      style={({ pressed }) => [{ minWidth: 44, minHeight: 44, alignItems: "center", justifyContent: "center" }, pressed && { opacity: 0.5 }]}>
      <Ionicons name={name} size={22} color={color ?? t.muted} />
    </Pressable>
  );
}

export function Chip({ label, active, onPress }: { label: string; active?: boolean; onPress: () => void }) {
  const t = useTheme();
  return (
    <Pressable onPress={onPress} accessibilityRole="button" accessibilityState={{ selected: !!active }}
      style={[s.chip, { borderColor: active ? t.navy : t.line, backgroundColor: active ? t.navy : t.surface }]}>
      <Text style={{ color: active ? t.onAccent : t.text, fontSize: 14, fontWeight: "600" }}>{label}</Text>
    </Pressable>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  const t = useTheme();
  return <Text style={{ color: t.muted, fontSize: 15, textAlign: "center", paddingVertical: 24, lineHeight: 22 }}>{children}</Text>;
}
