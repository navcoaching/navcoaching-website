// كل خطأ غير متوقع في الخادم (صفحة، API، إجراء) يُسجَّل وتُنبَّه المدربة. Next يتجاهل redirect/notFound هنا.
export async function onRequestError(error: unknown, request: { path: string; method: string }, context: { routeType: string }) {
  if (process.env.NEXT_RUNTIME !== "nodejs") return;
  const { reportIssue } = await import("./lib/ops");
  const e = error as { message?: string; digest?: string };
  // بوتات تفحص ثغرات Server Actions بطلبات POST مزيّفة على / و/api و/app؛ Next يرفضها، فلا تنبيه عنها
  if (String(e?.message).includes("Expected RSC response")) return;
  await reportIssue("server_error", `${request.method} ${request.path.split("?")[0]} (${context.routeType}): ${String(e?.message ?? error).slice(0, 300)}${e?.digest ? ` [${e.digest}]` : ""}`);
}
