---
name: ship-page
description: Write or update a page from its brief and publish it safely. Use after page-brief, when asked to build, rewrite or publish a page.
---
1. Read briefs/<keyword-slug>.md. Write or rewrite the page to cover
   every section the top 3 share, plus one thing they do not have
   (quiz, calculator, photo + credentials, real case numbers, video).
2. One H1 containing the primary keyword. Title and meta from the brief.
3. Add JSON-LD structured data that fits the page type.
4. Add at least 5 internal links TO this page from the most related
   existing pages, exact-match anchors, inside body text.
5. DIFF GATE. Before publishing, list every element present in the old
   version and missing from the new one: tables, rankings, forms,
   quizzes, embeds, images, internal links. Show me that list.
6. Publish only after I say yes. If ChatSEO wrote the article, push it
   with publish_artifact_to_wordpress, status "draft" first.
   Otherwise commit to a branch or save a CMS draft, never straight live.
