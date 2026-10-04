---
name: page-brief
description: Build the SEO brief for one target keyword. Use when asked to rank for a keyword, optimise a page, or before creating any new page.
---
1. Send ChatSEO (send_message, siteId), word for word:
   "I want to rank first on <keyword>. Tell me if I should optimise an
   existing page or create a new one, then give me the full brief."
2. Poll until complete. From the reply, extract:
   - create or optimise, and which URL
   - primary keyword and every secondary keyword
   - the page type and sections the top 3 all have
   - the title and meta description ChatSEO proposes
3. If an existing URL already gets clicks or impressions for the
   keyword, STOP any plan to create a new page. We optimise.
4. Check the title contains the primary keyword, fits the pixel limit
   without truncating in a SERP preview, and carries the secondary
   modifiers where they fit.
5. Save the brief to briefs/<keyword-slug>.md. Do not edit the site yet.
