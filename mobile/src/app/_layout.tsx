import * as Notifications from "expo-notifications";
import { Stack } from "expo-router";
import { StatusBar } from "expo-status-bar";
import { Suspense } from "react";
import { ActivityIndicator, View } from "react-native";
import { TrackerProvider } from "@/lib/tracker/context";
import { useTheme } from "@/lib/theme";

// تنبيه انتهاء الراحة يظهر حتى لو التطبيق مفتوح
Notifications.setNotificationHandler({
  handleNotification: async () => ({ shouldShowBanner: true, shouldShowList: true, shouldPlaySound: true, shouldSetBadge: false }),
});

export default function RootLayout() {
  const t = useTheme();
  return (
    <Suspense fallback={<View style={{ flex: 1, justifyContent: "center", backgroundColor: t.paper }}><ActivityIndicator /></View>}>
      <TrackerProvider>
        <StatusBar style="auto" />
        <Stack
          screenOptions={{
            headerStyle: { backgroundColor: t.surface },
            headerTintColor: t.heading,
            contentStyle: { backgroundColor: t.paper },
            headerBackButtonDisplayMode: "minimal",
          }}
        >
          <Stack.Screen name="(tabs)" options={{ headerShown: false, title: "الرئيسية" }} />
          <Stack.Screen name="login" options={{ title: "الدخول", presentation: "modal" }} />
          <Stack.Screen name="program/new" options={{ title: "برنامج جديد", presentation: "modal" }} />
          <Stack.Screen name="program/[id]" options={{ title: "تعديل البرنامج" }} />
          <Stack.Screen name="exercise-picker" options={{ title: "اختر تمريناً", presentation: "modal" }} />
          <Stack.Screen name="swap" options={{ title: "بدّل التمرين", presentation: "modal" }} />
          <Stack.Screen name="pro" options={{ title: "ناف برو" }} />
          <Stack.Screen name="checkout/[sku]" options={{ title: "استبيان المتدرب" }} />
          <Stack.Screen name="exercise/[id]" options={{ title: "التمرين" }} />
          <Stack.Screen name="workout/[id]" options={{ title: "التمرين", gestureEnabled: false }} />
          <Stack.Screen name="workout/summary/[id]" options={{ title: "أحسنت 💪", headerBackVisible: false, gestureEnabled: false }} />
          <Stack.Screen name="coach-program/[id]" options={{ title: "برنامج مجاني" }} />
          <Stack.Screen name="reminders" options={{ title: "تذكير التمرين", presentation: "modal" }} />
          <Stack.Screen name="coaching/index" options={{ title: "برنامجي مع الكوتش" }} />
          <Stack.Screen name="coaching/log" options={{ title: "تسجيل التمرين", presentation: "modal" }} />
          <Stack.Screen name="nutrition/index" options={{ title: "التغذية والمكملات" }} />
          <Stack.Screen name="nutrition/add" options={{ title: "أضف أكلاً", presentation: "modal" }} />
          <Stack.Screen name="progress" options={{ title: "تقدمي" }} />
          <Stack.Screen name="services/index" options={{ title: "خدمات الكوتش" }} />
          <Stack.Screen name="services/review" options={{ title: "راجعي جدولي" }} />
          <Stack.Screen name="services/form-check" options={{ title: "تصحيح أداء تمرين" }} />
          <Stack.Screen name="meals" options={{ title: "وجباتي" }} />
          <Stack.Screen name="order/[no]" options={{ title: "الطلب" }} />
          <Stack.Screen name="packages/index" options={{ title: "برامج المتابعة" }} />
          <Stack.Screen name="packages/[slug]" options={{ title: "البرنامج" }} />
          <Stack.Screen name="about" options={{ title: "عن المدربة" }} />
          <Stack.Screen name="reviews" options={{ title: "تقييمات المتدربين" }} />
          <Stack.Screen name="faq" options={{ title: "الأسئلة الشائعة" }} />
          <Stack.Screen name="policies" options={{ title: "السياسات" }} />
          <Stack.Screen name="calculator" options={{ title: "حاسبة السعرات" }} />
          <Stack.Screen name="free-plans" options={{ title: "الجداول المجانية" }} />
          <Stack.Screen name="profile" options={{ title: "بياناتي" }} />
          <Stack.Screen name="orders" options={{ title: "طلباتي" }} />
          <Stack.Screen name="delete-account" options={{ title: "حذف الحساب", presentation: "modal" }} />
          <Stack.Screen name="history/[id]" options={{ title: "تفاصيل التمرين" }} />
        </Stack>
      </TrackerProvider>
    </Suspense>
  );
}
