"use server";
import { revalidatePath } from "next/cache";
import { dbErrorMessage, withUser, type Tx } from "@/lib/db";
import { getCurrentUser } from "@/lib/session";
import { cleanUpload, newKey, UploadError } from "@/lib/uploads";
import { storage } from "@/lib/storage";
import type { ActionState } from "./client";

const GENERIC = "تعذّر الحفظ. حاولي مرة أخرى.";
const UUID = /^[0-9a-f-]{36}$/;
const s = (fd: FormData, k: string) => String(fd.get(k) ?? "").trim();
const fail = (err: unknown): ActionState => {
  if (err instanceof UploadError) return { error: err.message };
  const m = (err as Error).message ?? "";
  if (m.startsWith("user:")) return { error: m.slice(5) };
  return { error: dbErrorMessage(err) ?? GENERIC };
};
const bad = (msg: string) => new Error(`user:${msg}`);

async function asCoach<T>(fn: (tx: Tx, userId: string) => Promise<T>): Promise<T> {
  const u = await getCurrentUser();
  if (!u || u.role !== "coach") throw bad("للمدربة فقط.");
  return withUser(u.id, (tx) => fn(tx, u.id));
}
const refresh = () => { revalidatePath("/admin/booklets"); revalidatePath("/account"); };

/** المدربة: رفع كتيب PDF جديد */
export async function uploadBookletAction(_: ActionState, fd: FormData): Promise<ActionState> {
  let key = "";
  try {
    const title = s(fd, "title"), description = s(fd, "description") || null;
    if (title.length < 2 || title.length > 120) throw bad("اكتبي اسم الكتيب (حتى 120 حرفاً).");
    if (description && description.length > 300) throw bad("الوصف أطول من 300 حرف.");
    await asCoach(async () => {});
    const clean = await cleanUpload(fd.get("file") as File | null, "pdf");
    key = newKey("booklets", "pdf");
    await (await storage()).put(key, clean.data, clean.mime);
    await asCoach(async (tx, uid) => {
      await tx.query(
        `INSERT INTO booklets (title, description, file_key, file_size, file_sha256, published, sort, created_by)
         VALUES ($1,$2,$3,$4,$5,$6,(SELECT coalesce(max(sort),0)+1 FROM booklets),$7)`,
        [title, description, key, clean.size, clean.sha256, fd.get("published") === "on", uid]);
      await tx.query("INSERT INTO admin_log (actor_id, action, target, details) VALUES ($1,'booklet.upload',$2,$3)", [uid, title, JSON.stringify({ size: clean.size })]);
    });
  } catch (err) {
    if (key) await (await storage()).remove(key).catch(() => {});
    return fail(err);
  }
  refresh();
  return { ok: true, message: "تم رفع الكتيب." };
}

/** المدربة: تعديل الاسم والوصف والظهور */
export async function saveBookletAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const id = s(fd, "id");
  if (!UUID.test(id)) return { error: GENERIC };
  try {
    const title = s(fd, "title"), description = s(fd, "description") || null;
    if (title.length < 2 || title.length > 120) throw bad("اكتبي اسم الكتيب (حتى 120 حرفاً).");
    if (description && description.length > 300) throw bad("الوصف أطول من 300 حرف.");
    await asCoach(async (tx) => {
      const r = await tx.query(`UPDATE booklets SET title=$2, description=$3, published=$4, updated_at=now() WHERE id=$1`,
        [id, title, description, fd.get("published") === "on"]);
      if (!r.rowCount) throw bad("الكتيب غير موجود.");
    });
  } catch (err) { return fail(err); }
  refresh();
  return { ok: true, message: "تم الحفظ." };
}

/** المدربة: حذف كتيب (يُحذف الملف من التخزين) */
export async function deleteBookletAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const id = s(fd, "id");
  if (!UUID.test(id)) return { error: GENERIC };
  let key = "";
  try {
    await asCoach(async (tx, uid) => {
      const { rows: [b] } = await tx.query(`DELETE FROM booklets WHERE id = $1 RETURNING file_key, title`, [id]);
      if (!b) throw bad("الكتيب غير موجود.");
      key = b.file_key;
      await tx.query("INSERT INTO admin_log (actor_id, action, target) VALUES ($1,'booklet.delete',$2)", [uid, b.title]);
    });
  } catch (err) { return fail(err); }
  await (await storage()).remove(key).catch(() => {});
  refresh();
  return { ok: true, message: "تم الحذف." };
}
