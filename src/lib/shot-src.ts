/** مسار صورة النموذج التوضيحي من جذر الموقع دائماً (القيمة المحفوظة قد تكون «shots/x.webp» بدون شرطة أولى) */
export const shotSrc = (src: string) => (/^(https?:|\/)/.test(src) ? src : `/${src}`);
