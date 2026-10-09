// محوّل node:sqlite بنفس واجهة expo-sqlite المستخدمة في repo.ts (للاختبارات فقط)
import { DatabaseSync } from "node:sqlite";
import type { Db } from "../src/lib/tracker/repo.ts";

export function memoryDb(): Db {
  const d = new DatabaseSync(":memory:");
  let depth = 0;
  return {
    async execAsync(sql) { d.exec(sql); },
    async runAsync(sql, params) { d.prepare(sql).run(...params); },
    async getAllAsync<T>(sql: string, params: (string | number | null)[]) { return d.prepare(sql).all(...params).map((r) => ({ ...r })) as T[]; },
    async getFirstAsync<T>(sql: string, params: (string | number | null)[]) { const r = d.prepare(sql).get(...params); return r ? ({ ...r } as T) : null; },
    async withTransactionAsync(fn) {
      // مثل expo-sqlite: معاملة واحدة؛ المعاملات المتداخلة تنضم للخارجية
      if (depth > 0) { depth++; try { await fn(); } finally { depth--; } return; }
      depth++; d.exec("BEGIN");
      try { await fn(); d.exec("COMMIT"); } catch (e) { d.exec("ROLLBACK"); throw e; } finally { depth--; }
    },
  };
}
