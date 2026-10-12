// أيقونات خطية بسيطة مرسومة لهذا المشروع.
type P = { size?: number; className?: string };
const S = ({ size = 22, className, children }: P & { children: React.ReactNode }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"
    strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={className}>{children}</svg>
);
export const IconArrow = (p: P) => <S {...p}><path d="M19 12H5M11 6l-6 6 6 6" /></S>;
export const IconTarget = (p: P) => <S {...p}><circle cx="12" cy="12" r="8" /><circle cx="12" cy="12" r="4" /><circle cx="12" cy="12" r="0.5" /></S>;
export const IconChat = (p: P) => <S {...p}><path d="M4 5h16v10H9l-5 4z" /><path d="M8 9h8M8 12h5" /></S>;
export const IconTrend = (p: P) => <S {...p}><path d="M3 17l6-6 4 4 7-7" /><path d="M14 8h6v6" /></S>;
export const IconDumbbell = (p: P) => <S {...p}><path d="M6 7v10M3 9v6M18 7v10M21 9v6M6 12h12" /></S>;
export const IconMenu = (p: P) => <S {...p}><path d="M4 7h16M4 12h16M4 17h16" /></S>;
export const IconPlay = (p: P) => <svg width={p.size ?? 28} height={p.size ?? 28} viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5.5v13l11-6.5z" fill="currentColor" /></svg>;
export const IconCheck = (p: P) => <S {...p}><path d="M5 12.5l4.5 4.5L19 7.5" /></S>;
export const IconFile = (p: P) => <S {...p}><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" /><path d="M14 3v5h5M9 13h6M9 17h6" /></S>;
export const IconLink = (p: P) => <S {...p}><path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1" /><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" /></S>;
export const IconShield = (p: P) => <S {...p}><path d="M12 3l7 3v6c0 4.5-3 7.8-7 9-4-1.2-7-4.5-7-9V6z" /><path d="M9 12l2 2 4-4" /></S>;
export const IconUser = (p: P) => <S {...p}><circle cx="12" cy="8" r="4" /><path d="M4 21c1.5-4 4.5-6 8-6s6.5 2 8 6" /></S>;
export const IconWhatsApp = ({ size = 28 }: P) => (
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" fill="currentColor">
    <path d="M12 2a10 10 0 0 0-8.6 15.1L2 22l5-1.3A10 10 0 1 0 12 2zm0 18.2a8.2 8.2 0 0 1-4.2-1.1l-.3-.2-3 .8.8-2.9-.2-.3A8.2 8.2 0 1 1 12 20.2zm4.5-6.1c-.2-.1-1.5-.7-1.7-.8s-.4-.1-.6.1-.7.8-.8 1-.3.2-.5.1a6.7 6.7 0 0 1-3.3-2.9c-.3-.4.3-.4.7-1.3.1-.2 0-.3 0-.4l-.8-1.8c-.2-.5-.4-.4-.6-.4h-.5a1 1 0 0 0-.7.3 3 3 0 0 0-.9 2.2 5.2 5.2 0 0 0 1.1 2.7 11.8 11.8 0 0 0 4.5 4c1.7.7 2.3.8 3.2.6.5-.1 1.5-.6 1.7-1.2s.2-1.1.1-1.2l-.5-.3z" />
  </svg>
);
export const IconInstagram = ({ size = 24 }: P) => (
  <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.8">
    <rect x="3" y="3" width="18" height="18" rx="5" /><circle cx="12" cy="12" r="4" /><circle cx="17.3" cy="6.7" r="1.1" fill="currentColor" stroke="none" />
  </svg>
);
// أيقونات بأسلوب Lucide (خطية، 24px، سماكة 1.8) بدل الإيموجي في الصفحات العامة
export const IconClipboard = (p: P) => <S {...p}><rect x="6" y="4" width="12" height="17" rx="2" /><path d="M9 4.5V3h6v1.5M9 11h6M9 15h4" /></S>;
export const IconEye = (p: P) => <S {...p}><path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z" /><circle cx="12" cy="12" r="3" /></S>;
export const IconVideo = (p: P) => <S {...p}><rect x="3" y="6" width="13" height="12" rx="2" /><path d="M16 10.5l5-3v9l-5-3" /></S>;
export const IconZap = (p: P) => <S {...p}><path d="M13 2.5L4.5 13.5H12l-1 8 8.5-11H12z" /></S>;
export const IconCrosshair = (p: P) => <S {...p}><circle cx="12" cy="12" r="8" /><path d="M12 2.5v4M12 17.5v4M2.5 12h4M17.5 12h4" /></S>;
export const IconChair = (p: P) => <S {...p}><path d="M7 3h10v8H7zM5 11h14v3H5zM7 14v7M17 14v7" /></S>;
export const IconGamepad = (p: P) => <S {...p}><path d="M7 8h10a4 4 0 0 1 4 4v1.5a3 3 0 0 1-5.4 1.8L14.5 14h-5l-1.1 1.3A3 3 0 0 1 3 13.5V12a4 4 0 0 1 4-4z" /><path d="M7.5 10.5v3M6 12h3M15.5 11.5h.01M17.5 13h.01" /></S>;
export const IconLock = (p: P) => <S {...p}><rect x="4.5" y="10.5" width="15" height="10" rx="2" /><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3" /></S>;
export const IconReceipt = (p: P) => <S {...p}><path d="M6 3h12v18l-3-2-3 2-3-2-3 2z" /><path d="M9 8h6M9 12h6M9 16h3" /></S>;
export const IconSalad = (p: P) => <S {...p}><path d="M3.5 12h17a8.5 8.5 0 0 1-17 0z" /><path d="M8 12c0-3 1.5-5 4-6M12 12c0-2.5 1.2-4.5 3.5-5.5M7 21h10" /></S>;
export const IconBook = (p: P) => <S {...p}><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5z" /><path d="M4 20.5A2.5 2.5 0 0 0 6.5 23H20v-5" /></S>;
export const IconHome = (p: P) => <S {...p}><path d="M4 11l8-7 8 7" /><path d="M6 10v10h12V10" /><path d="M10 20v-6h4v6" /></S>;
export const IconClose = (p: P) => <S {...p}><path d="M6 6l12 12M18 6L6 18" /></S>;
export const IconChevron = (p: P) => <S {...p}><path d="M15 6l-6 6 6 6" /></S>;
export const IconClock = (p: P) => <S {...p}><circle cx="12" cy="12" r="8.5" /><path d="M12 7.5V12l3 2" /></S>;
