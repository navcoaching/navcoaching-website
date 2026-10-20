/** عنوان الموقع (الخادم). للتجربة على خادم آخر: EXPO_PUBLIC_API_URL=https://... npx expo start */
export const API_URL = (process.env.EXPO_PUBLIC_API_URL ?? "https://navcoaching.com").replace(/\/$/, "");
