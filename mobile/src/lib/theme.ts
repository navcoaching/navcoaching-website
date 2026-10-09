import { useColorScheme } from "react-native";

// نفس ألوان الموقع (src/app/globals.css)
const light = {
  ink: "#07142a", navy: "#284da0", cyan: "#4cc5ed", paper: "#f3f6fa", surface: "#ffffff",
  line: "#d8e1ea", text: "#15233a", heading: "#0b1a33", muted: "#56667a", err: "#b42318", errBg: "#fdecea",
  onAccent: "#ffffff",
};
const dark: typeof light = {
  ink: "#07142a", navy: "#3558b0", cyan: "#4cc5ed", paper: "#0b1622", surface: "#122232",
  line: "#26394c", text: "#d5e1ea", heading: "#eef4f8", muted: "#93a6b7", err: "#f97066", errBg: "#3a1714",
  onAccent: "#ffffff",
};
export type Theme = typeof light;

export function useTheme(): Theme {
  return useColorScheme() === "dark" ? dark : light;
}
