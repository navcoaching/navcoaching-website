/** يستخرج معرّف المقطع من روابط Shorts أو watch أو youtu.be. يرجع null لأي رابط آخر. */
export function youtubeId(url: string | null | undefined): string | null {
  if (!url) return null;
  let u: URL;
  try {
    u = new URL(url.trim());
  } catch {
    return null;
  }
  const host = u.hostname.replace(/^www\.|^m\./, "");
  let id: string | null = null;
  if (host === "youtu.be") id = u.pathname.slice(1);
  else if (host === "youtube.com") {
    const m = u.pathname.match(/^\/(shorts|embed|live)\/([^/?#]+)/);
    id = m ? m[2] : u.searchParams.get("v");
  }
  return id && /^[A-Za-z0-9_-]{11}$/.test(id) ? id : null;
}

/**
 * معرّف مقطع تيك توك من رابط كامل مثل tiktok.com/@user/video/123… أو tiktok.com/embed/v2/123…
 * الروابط المختصرة (vm.tiktok.com / vt.tiktok.com) لا تحمل المعرّف، فتفتح خارج الموقع.
 */
export function tiktokId(url: string | null | undefined): string | null {
  if (!url) return null;
  let u: URL;
  try { u = new URL(url.trim()); } catch { return null; }
  if (u.protocol !== "https:" || u.hostname.replace(/^www\.|^m\./, "") !== "tiktok.com") return null;
  const m = u.pathname.match(/\/(?:video|embed\/v2|player\/v1)\/(\d{8,25})(?:\/|$)/);
  return m ? m[1] : null;
}
