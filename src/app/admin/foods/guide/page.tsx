import Link from "next/link";
import { withUser } from "@/lib/db";
import { requireCoach } from "@/lib/session";
import FoodGuide, { loadGuideFoods, type GuideSP } from "@/components/nutrition/FoodGuide";

export const metadata = { title: "دليل مصادر الأكل" };

/** نفس الدليل اللي يشوفه المتدرب (للمدربة) */
export default async function AdminFoodGuide({ searchParams }: { searchParams: Promise<GuideSP> }) {
  const coach = await requireCoach();
  const sp = await searchParams;
  const foods = await withUser(coach.id, (tx) => loadGuideFoods(tx));
  return (
    <div className="stack" style={{ ["--space" as string]: "18px", maxWidth: 1100 }}>
      <nav className="small"><Link href="/admin/foods">قاعدة الأكل</Link> / دليل مصادر الأكل</nav>
      <h1>دليل مصادر الأكل</h1>
      <p className="muted" style={{ margin: 0 }}>هذا نفس الدليل اللي يشوفه المتدرب في «التغذية والمكملات». الأصناف اللي تضيفينها بنفسك تظهر بدون ألياف وفيتامينات حتى تعبّينها.</p>
      <FoodGuide foods={foods} sp={sp} base="/admin/foods/guide" />
    </div>
  );
}
