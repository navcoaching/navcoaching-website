import { notFound } from "next/navigation";

/** أي مسار غير معروف داخل اللغة يعرض صفحة 404 الخاصة بالموقع (بدل صفحة Next الافتراضية) */
export default function CatchAll() {
  notFound();
}
