# SEO operating rules

Site: https://navcoaching.com (Arabic, `lang="ar"`; Next.js hosted on Netlify).
Coaching brand: personalised training and nutrition programs with Coach Sarah.
Money pages: `/programs`, `/programs/{basic,advanced,intensive,nutrition,gamers}`.
Supporting pages: `/about`, `/faq`, `/reviews`, `/calculator`, `/free-plans`, `/policies`.
Site source code: NOT in this repo yet. Until it is, skills may research and write
briefs, but must not claim to edit or publish pages.

Roles:
- Claude Code is the Chief of SEO: plans, orchestrates, edits the site, runs the routines.
- The ChatSEO MCP (`https://api.chatseo.app/mcp`) is the data layer: Search Console,
  keyword volumes, live SERP, competitor pages, domain authority.
- The owner approves anything that touches a live page.

Skills in `.claude/skills/`, in the order they are used:
1. `money-keywords`: commercial keyword patterns → `keywords.md`
2. `page-brief`: optimise or create, plus the full brief → `briefs/<keyword-slug>.md`
3. `ship-page`: write the page, pass the diff gate, publish after approval
4. `pattern-drip`: one new pattern page per run (daily routine)
5. `weekly-seo`: Monday review → `reviews/<date>.md`
6. `geo-rankings`: start in month three → `geo.md`

Hard rules:
- Never invent a number (volume, position, clicks). If ChatSEO did not return it, write "n/a".
- One keyword, one page. Check for an existing ranking URL before creating anything.
- Never publish without the diff gate and an explicit yes. Branch or draft first, never straight live.
- Never touch a page edited in the last 60 days.
- At most one new page per day.
- If the ChatSEO MCP is not connected, stop and say so; do not substitute guesses for its data.
