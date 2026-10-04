---
name: money-keywords
description: Find the commercial keyword patterns for this site. Use when asked which keywords to target, for an SEO strategy, or "where is the money".
---
1. Call ChatSEO list_sites and pick this site's ID.
2. Send ChatSEO (send_message, with the siteId), word for word:
   "Give me the best SEO strategy for my site. Group the opportunities
   by keyword pattern, and only keep the ones with commercial intent."
3. Poll get_conversation_messages until the reply is complete.
4. For each pattern, keep only keywords where the current top 3 are
   landing, service, category or product pages. Drop anything where
   blog posts dominate.
5. Write keywords.md: pattern, keyword, monthly volume, page type
   Google ranks, and whether we already have a URL for it.
6. Never invent a volume. If ChatSEO did not return it, write "n/a".
