---
name: pattern-drip
description: Publish the next page of a keyword pattern. Use for scheduled runs, or when asked to scale a pattern or duplicate a page.
---
1. Open keywords.md. Take the next pattern keyword with no URL yet,
   highest volume first.
2. Run page-brief on it. If the brief says "optimise", stop and flag it.
3. Duplicate the reference page for this pattern. Replace everything
   specific: city facts, prices, examples, testimonials. A page that
   only swaps the city name does not ship.
4. Run ship-page. Diff it against the REFERENCE page as well: anything
   the reference has that this one lost gets restored.
5. One page per run. Never more.
