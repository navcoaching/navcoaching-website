import "server-only";
import { createHash, randomUUID } from "node:crypto";
import { fileTypeFromBuffer } from "file-type";
import sharp from "sharp";

export const MAX_UPLOAD_BYTES = 5 * 1024 * 1024;

export type CleanFile = { data: Buffer; mime: string; ext: string; size: number; sha256: string; width?: number; height?: number };

type Kind = "proof" | "image" | "deliverable" | "pdf";

const ALLOWED: Record<Kind, string[]> = {
  proof: ["image/jpeg", "image/png", "image/webp", "application/pdf"],
  image: ["image/jpeg", "image/png", "image/webp"],
  pdf: ["application/pdf"],
  deliverable: [
    "application/pdf",
    "image/jpeg", "image/png", "image/webp",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ],
};

/**
 * يتحقق من الملف بمحتواه الفعلي (magic bytes) لا بامتداده أو نوعه المعلن، ويرفض ما عدا الأنواع المسموحة.
 * الصور يُعاد ترميزها (يزيل بيانات الموقع EXIF وأي محتوى مخفي داخل الملف).
 * ملاحظة: لا يوجد فحص فيروسات هنا؛ ملفات PDF تُخدم دائماً كتحميل مع nosniff.
 */
export async function cleanUpload(file: File | null, kind: Kind): Promise<CleanFile> {
  if (!file || typeof file === "string" || file.size === 0) throw new UploadError("اختر ملفاً.");
  if (file.size > MAX_UPLOAD_BYTES) throw new UploadError("حجم الملف أكبر من 5 ميجابايت.");
  const raw = Buffer.from(await file.arrayBuffer());
  const type = await fileTypeFromBuffer(raw);
  // ملفات Office (xlsx/docx) تُكتشف كـ zip في بعض الحالات؛ نعتمد الامتداد فقط إذا كان المحتوى zip فعلاً.
  let mime = type?.mime ?? "";
  if (kind === "deliverable" && mime === "application/zip") {
    if (file.name.toLowerCase().endsWith(".xlsx")) mime = ALLOWED.deliverable[4];
    if (file.name.toLowerCase().endsWith(".docx")) mime = ALLOWED.deliverable[5];
  }
  if (!ALLOWED[kind].includes(mime)) throw new UploadError(kind === "pdf" ? "الملف لازم يكون PDF." : "نوع الملف غير مسموح. المسموح: صور JPG/PNG/WebP أو PDF.");

  if (mime.startsWith("image/")) {
    try {
      const img = sharp(raw, { limitInputPixels: 40_000_000 }).rotate();
      const out = await img.resize({ width: 2400, height: 2400, fit: "inside", withoutEnlargement: true }).webp({ quality: 82 }).toBuffer({ resolveWithObject: true });
      return { data: out.data, mime: "image/webp", ext: "webp", size: out.data.length, sha256: sha(raw), width: out.info.width, height: out.info.height };
    } catch {
      throw new UploadError("تعذّرت قراءة الصورة. جرّب صورة أخرى.");
    }
  }
  const ext = mime === "application/pdf" ? "pdf" : mime.includes("spreadsheet") ? "xlsx" : "docx";
  return { data: raw, mime, ext, size: raw.length, sha256: sha(raw) };
}

export const newKey = (prefix: string, ext: string) => `${prefix}/${new Date().toISOString().slice(0, 7)}/${randomUUID()}.${ext}`;
const sha = (b: Buffer) => createHash("sha256").update(b).digest("hex");

export class UploadError extends Error {}
