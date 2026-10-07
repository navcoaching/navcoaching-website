import { Stack } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { useTheme } from "@/lib/theme";

export default function RootLayout() {
  const t = useTheme();
  return (
    <>
      <StatusBar style="auto" />
      <Stack
        screenOptions={{
          headerStyle: { backgroundColor: t.surface },
          headerTintColor: t.heading,
          contentStyle: { backgroundColor: t.paper },
          headerBackButtonDisplayMode: "minimal",
        }}
      >
        <Stack.Screen name="index" options={{ title: "Nav Coaching" }} />
        <Stack.Screen name="login" options={{ title: "الدخول", presentation: "modal" }} />
        <Stack.Screen name="account" options={{ title: "حسابي" }} />
      </Stack>
    </>
  );
}
