import * as ImagePicker from "expo-image-picker";
import { Stack } from "expo-router";
import { useMemo, useState } from "react";
import { Alert, Pressable, Text, TextInput, View } from "react-native";
import { AddonForm } from "@/components/AddonForm";
import { Body, Button, Card, Empty, Title } from "@/components/ui";
import { useAddons } from "@/lib/addons";
import { searchExercises } from "@/lib/exercises";
import { useTheme } from "@/lib/theme";

const MAX_BYTES = 5 * 1024 * 1024;
const MAX_SECONDS = 20;

// «تصحيح أداء تمرين»: مقطع قصير (حتى 20 ثانية، مضغوط ليكون تحت 5 ميجا) لتمرين واحد
export default function FormCheck() {
  const t = useTheme();
  const { addons } = useAddons();
  const addon = addons?.find((a) => a.kind === "form_check");
  const [q, setQ] = useState("");
  const [ex, setEx] = useState<string | null>(null);
  const [video, setVideo] = useState<ImagePicker.ImagePickerAsset | null>(null);
  const results = useMemo(() => (q.trim().length >= 2 ? searchExercises(q, null).slice(0, 6) : []), [q]);
  if (!addon) return addons ? <Empty>الخدمة غير متاحة حالياً.</Empty> : null;

  async function pick(source: "camera" | "library") {
    const opts: ImagePicker.ImagePickerOptions = {
      mediaTypes: ["videos"], videoMaxDuration: MAX_SECONDS,
      videoQuality: ImagePicker.UIImagePickerControllerQualityType.Medium,
      videoExportPreset: ImagePicker.VideoExportPreset.MediumQuality,
    };
    if (source === "camera" && !(await ImagePicker.requestCameraPermissionsAsync()).granted) {
      return Alert.alert("الكاميرا مقفلة", "اسمح للتطبيق بالكاميرا من إعدادات الجوال، أو اختر مقطعاً من الألبوم.");
    }
    const r = source === "camera" ? await ImagePicker.launchCameraAsync(opts) : await ImagePicker.launchImageLibraryAsync(opts);
    if (r.canceled) return;
    const a = r.assets[0];
    if (a.duration != null && a.duration / 1000 > MAX_SECONDS + 1) return Alert.alert("المقطع طويل", `اختر مقطعاً حتى ${MAX_SECONDS} ثانية (جولة واحدة تكفي).`);
    if (a.fileSize != null && a.fileSize > MAX_BYTES) return Alert.alert("المقطع كبير", "حجمه أكبر من 5 ميجا. صوّر جولة واحدة أقصر.");
    setVideo(a);
  }

  return (
    <View style={{ flex: 1 }}>
      <Stack.Screen options={{ title: addon.name }} />
      <AddonForm addon={addon} build={async () => {
        if (!ex) return { error: "اختر التمرين." };
        if (!video) return { error: "أرفق مقطع الفيديو." };
        const name = video.fileName ?? (video.mimeType === "video/mp4" ? "form.mp4" : "form.mov");
        return { fields: { video: { uri: video.uri, name, type: video.mimeType ?? "video/quicktime" } as unknown as Blob, payload: JSON.stringify({ exercise: ex }) } };
      }}>
        <Card>
          <Title>التمرين</Title>
          {ex ? (
            <View style={{ flexDirection: "row", justifyContent: "space-between", alignItems: "center" }}>
              <Text style={{ color: t.text, fontSize: 16, fontWeight: "700" }}>{ex}</Text>
              <Pressable onPress={() => setEx(null)} hitSlop={10}><Text style={{ color: t.navy }}>تغيير</Text></Pressable>
            </View>
          ) : (
            <>
              <TextInput value={q} onChangeText={setQ} placeholder="ابحث باسم التمرين" placeholderTextColor={t.muted}
                style={{ minHeight: 46, borderWidth: 1, borderRadius: 10, borderColor: t.line, color: t.text, paddingHorizontal: 12, textAlign: "right" }} />
              {results.map((r) => (
                <Pressable key={r.id} onPress={() => { setEx(r.name); setQ(""); }} style={{ minHeight: 40, justifyContent: "center" }}>
                  <Text style={{ color: t.navy, fontSize: 15, textAlign: "left" }}>{r.name} · {r.muscle}</Text>
                </Pressable>
              ))}
            </>
          )}
        </Card>
        <Card>
          <Title>المقطع</Title>
          <Body muted>صوّر جولة واحدة من الجنب، والجسم كامل ظاهر. حتى {MAX_SECONDS} ثانية.</Body>
          {video && <Body>✓ مقطع جاهز ({Math.round((video.duration ?? 0) / 1000)} ثانية{video.fileSize ? ` · ${(video.fileSize / 1048576).toFixed(1)} ميجا` : ""})</Body>}
          <Button title="صوّر الآن" variant={video ? "ghost" : "primary"} onPress={() => pick("camera")} />
          <Button title="اختر من الألبوم" variant="ghost" onPress={() => pick("library")} />
        </Card>
      </AddonForm>
    </View>
  );
}
