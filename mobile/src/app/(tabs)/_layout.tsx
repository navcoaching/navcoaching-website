import { Ionicons } from "@expo/vector-icons";
import { Tabs } from "expo-router";
import { useTheme } from "@/lib/theme";

export default function TabsLayout() {
  const t = useTheme();
  return (
    <Tabs
      screenOptions={{
        headerStyle: { backgroundColor: t.surface },
        headerTintColor: t.heading,
        tabBarStyle: { backgroundColor: t.surface, borderTopColor: t.line },
        tabBarActiveTintColor: t.navy,
        tabBarInactiveTintColor: t.muted,
        sceneStyle: { backgroundColor: t.paper },
      }}
    >
      <Tabs.Screen name="index" options={{ title: "تمريني", tabBarIcon: ({ color, size }) => <Ionicons name="barbell" color={color} size={size} /> }} />
      <Tabs.Screen name="history" options={{ title: "السجل", tabBarIcon: ({ color, size }) => <Ionicons name="time" color={color} size={size} /> }} />
      <Tabs.Screen name="account" options={{ title: "حسابي", tabBarIcon: ({ color, size }) => <Ionicons name="person-circle" color={color} size={size} /> }} />
    </Tabs>
  );
}
