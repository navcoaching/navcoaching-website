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
