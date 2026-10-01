import { IconDumbbell } from "@/components/Icons";

/** صورة الغلاف (من الصور المعتمدة في لوحة الإدارة) أو أيقونة بديلة */
export default function PlanCover({ imageId, title }: { imageId: string | null; title: string }) {
  return (
    <div className="fp-cover">
      {imageId
        // eslint-disable-next-line @next/next/no-img-element
        ? <img src={`/api/files/media/${imageId}`} alt={title} loading="lazy" />
        : <span aria-hidden="true"><IconDumbbell size={44} /></span>}
    </div>
  );
}
