// سكربت الثيم في <head>؛ proxy.ts يسمح به في سياسة الصفحات الخاصة بالـ hash، فأي تعديل هنا يُحدّث الـ hash تلقائياً.
export const THEME_SCRIPT = "document.documentElement.classList.add('js');try{var t=localStorage.getItem('nav_theme');if(t==='light'||t==='dark')document.documentElement.dataset.theme=t}catch(e){}";
