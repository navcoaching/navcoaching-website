import "server-only";
import { mkdir, readFile, writeFile, unlink } from "node:fs/promises";
import path from "node:path";

/**
 * تخزين خاص للملفات (إيصالات، ملفات البرامج، الصور).
 * لا يوجد أي رابط عام مباشر: كل ملف يُقرأ عبر /api/files/... بعد التحقق من الصلاحية في قاعدة البيانات.
 * - local: مجلد على الجهاز (للتطوير والاختبار فقط).
 * - netlify: Netlify Blobs (خاص افتراضياً) عند النشر على Netlify.
 */
interface Driver {
  put(key: string, data: Buffer, contentType: string): Promise<void>;
  get(key: string): Promise<Buffer | null>;
  remove(key: string): Promise<void>;
}

const localDriver = (): Driver => {
  const root = path.resolve(/*turbopackIgnore: true*/ process.cwd(), process.env.LOCAL_UPLOAD_DIR ?? ".data/uploads");
  const resolve = (key: string) => {
    const p = path.resolve(/*turbopackIgnore: true*/ root, key);
    if (!p.startsWith(root + path.sep)) throw new Error("invalid key");
    return p;
  };
  return {
    async put(key, data) {
      const p = resolve(key);
      await mkdir(path.dirname(p), { recursive: true });
      await writeFile(p, data);
    },
    async get(key) {
      try { return await readFile(resolve(key)); } catch { return null; }
    },
    async remove(key) {
      await unlink(resolve(key)).catch(() => {});
    },
  };
};

const netlifyDriver = async (): Promise<Driver> => {
  const { getStore } = await import("@netlify/blobs");
  const store = getStore({ name: "private-files", consistency: "strong" });
  return {
    async put(key, data, contentType) {
      await store.set(key, new Blob([new Uint8Array(data)]), { metadata: { contentType } });
    },
    async get(key) {
      const ab = await store.get(key, { type: "arrayBuffer" });
      return ab ? Buffer.from(ab) : null;
    },
    async remove(key) {
      await store.delete(key);
    },
  };
};

let driver: Promise<Driver> | null = null;
export function storage(): Promise<Driver> {
  if (!driver) driver = process.env.STORAGE_DRIVER === "netlify" ? netlifyDriver() : Promise.resolve(localDriver());
  return driver;
}
