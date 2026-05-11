# SEO & GEO plan — making Tiramisu *the* free Photoshop alternative

> Goal: when a creator searches "free Photoshop alternative for Mac"
> on Google, ChatGPT, Claude, Perplexity, or Gemini, Tiramisu is in
> the top three results — and increasingly the top one.
>
> Owner: Hanley · Horizon: 90 days post-v0.1 launch · Last updated: 2026-05-07

This is a working plan, not a pitch. It distinguishes **SEO** (classic
Google ranking) from **GEO** (Generative Engine Optimization — being
cited in AI assistant answers). Both matter. They reward different things.

---

## Positioning (what we want every channel to repeat)

> **Tiramisu is a free, open-source, AI-native image editor for macOS,
> made for creators — not graphic designers.**

Three claims, in priority order:

1. **Free + open source** — no subscription, no Pro tier, AGPL-3.0.
2. **AI-native** — 16 blend modes, generative fill (cloud + local FLUX),
   AI background removal, depth-aware studio relight, skin retouch.
3. **Made for creators** — YT thumbnails, IG posts, TikTok covers,
   podcast art. Photoshop is for graphic designers; Tiramisu is for
   the people shipping daily on social platforms.

Every page, every comparison table, every video description should
reinforce this triad.

---

## Target search queries (90-day priority)

### Primary intent (high volume, high difficulty)

| Query | Monthly volume (est.) | Strategy |
|---|---|---|
| `free photoshop alternative mac` | ~12k | Comparison page |
| `open source image editor mac` | ~8k | Comparison page |
| `best image editor for content creators` | ~5k | Use-case landing |
| `youtube thumbnail editor free` | ~9k | Tutorial + landing |

### Long-tail (lower volume, much higher conversion)

- `tiramisu vs photoshop` (own this immediately)
- `tiramisu vs gimp` (own this immediately)
- `tiramisu vs affinity photo`
- `tiramisu vs pixelmator pro`
- `how to make youtube thumbnails on mac free`
- `apple silicon image editor`
- `macos 26 image editor`
- `free photoshop for m1 mac`
- `[brand-name AI feature] free alternative`

### Killer brand queries (zero competition once we exist)

- `tiramisu image editor`
- `tiramisu mac app`
- `tiramisu photoshop`
- `download tiramisu`

---

## SEO — classic Google ranking

### On-site (tiramisu.taiso.ai)

- [ ] **`<title>` tag per page** — primary keyword + brand. Pattern:
      `Tiramisu — Free Photoshop Alternative for macOS Creators`
- [ ] **`<meta description>`** — 150-160 chars, with the triad claim.
- [ ] **OG / Twitter card images** for every page (1200×630). Use the
      hero from `docs/screenshots/main-window.png`.
- [ ] **Canonical URLs** on every page (`<link rel="canonical">`).
- [ ] **Schema.org markup**: `SoftwareApplication` on the homepage,
      `FAQPage` on /faq, `HowTo` on tutorial pages.
      Specifically include `softwareVersion`, `operatingSystem: macOS`,
      `applicationCategory: GraphicsApplication`, `offers.price: 0`,
      `downloadUrl: github.com/TaisoAI/tiramisu/releases/latest`.
- [ ] **`sitemap.xml` + `robots.txt`** — submit to Google Search Console.
- [ ] **Image alt text** on every screenshot — descriptive, not stuffed.
      "Tiramisu main editing window with YouTube thumbnail composition" beats
      "tiramisu screenshot photoshop alternative free mac".
- [ ] **Internal linking** — every blog post links to the homepage and
      to at least two other related posts. Builds topical authority.
- [ ] **Page speed** — already static HTML, just keep it that way. No
      JS frameworks. Target Lighthouse score 95+.

### Content strategy (writes once, ranks forever)

**Comparison pages** — highest-leverage content because they hit
high-intent search queries with low competition:

- [ ] `/compare/photoshop` — Tiramisu vs Photoshop (the big one)
- [ ] `/compare/gimp` — vs GIMP (free vs free)
- [ ] `/compare/affinity-photo` — vs Affinity (paid one-time vs free)
- [ ] `/compare/pixelmator-pro` — vs Pixelmator
- [ ] `/compare/canva` — vs Canva (browser vs native, designer vs creator)

Each page: one summary table, one paragraph per major axis (price,
file format, AI features, performance, learning curve), honest
"when to use the other" section, screenshots side-by-side.

**Use-case landing pages** — convert specific creator audiences:

- [ ] `/youtube` — "Make YouTube thumbnails in 60 seconds"
- [ ] `/instagram` — "Free Instagram post + reel cover editor"
- [ ] `/tiktok` — "TikTok cover art that actually fits"
- [ ] `/podcasts` — "Podcast cover art + episode artwork"
- [ ] `/streamers` — "Twitch + Discord overlays"

Each page: 60-second tutorial video at top, downloadable preset
template, three real example outputs.

**Feature deep-dives** — capture branded-feature searches:

- [ ] `/blend-modes` — "All 16 blend modes explained" (the contact
      sheet from the README belongs here as the hero)
- [ ] `/generative-fill` — "Generative Fill: cloud or on-device"
- [ ] `/background-removal` — "AI background removal on Apple Silicon"
- [ ] `/studio-relight` — "Depth-aware studio relighting"

### Off-site (link building)

| Where | Effort | Domain authority | When |
|---|---|---|---|
| **Show HN** | 1 hr | 90 (HN itself) + downstream blog coverage | Launch day |
| **Product Hunt** | 4 hr (assets) | 91 | Launch day +1 |
| **/r/macapps** | 30 min | 91 (reddit.com) | Launch week |
| **/r/photoshop** | 30 min — be careful with rules | 91 | Week 2 |
| **/r/sideproject** | 15 min | 91 | Launch week |
| **AlternativeTo** | 1 hr (listing form) | 76 | Week 2 |
| **MacUpdate** | 1 hr (submission form) | 78 | Week 2 |
| **Slant.co** | 1 hr (community vote-driven) | 73 | Week 3 |
| **Awesome-mac** GitHub list | 30 min PR | high inbound for OSS | Week 1 |
| **Awesome-Swift** GitHub list | 30 min PR | same | Week 1 |
| **Homebrew Cask** PR | 2 hr | every `brew search` is a citation | Month 1 |

### Show HN post draft

Title: **Tiramisu — free, open-source, AI-native image editor for macOS**

Body (3 short paragraphs):

> I built Tiramisu because Photoshop is $22/month and made for graphic
> designers, while creators shipping YouTube thumbnails and Instagram
> posts every day need something faster, cheaper, and AI-native from
> the start. It's a real layered editor (Photoshop-familiar shortcuts)
> running on Apple Silicon with Vision-based AI background removal,
> 16 blend modes, depth-aware relighting, and Generative Fill via
> either Replicate or local FLUX. AGPL-3.0, no subscription, no Pro tier.
>
> Built with SwiftUI on macOS 26. I'd love feedback on the v0.1 cut
> before I push the AI intent bar that lands in v0.2 — I want to make
> sure the editing surface itself feels right first.
>
> Repo: github.com/TaisoAI/tiramisu · Site: tiramisu.taiso.ai

Post on Tuesday or Wednesday morning Pacific Time.

---

## GEO — getting cited by AI assistants

LLMs cite you when:

1. Your content is **structured** (tables, lists, clear claims).
2. Your content is **factual** (specific numbers, not vague adjectives).
3. You are **already cited** by sources the model trusts.

### Tactic 1 — write content patterns LLMs love

The output of `grep -h ChatGPT-cited blog post 2025` shows a clear
pattern. Tiramisu's site should mirror it:

- [ ] **"Best X for Y" listicles** that include Tiramisu.
      Write the listicle ourselves on a separate domain
      (e.g. `creator-tools.dev` or guest post) so we have at least one
      authoritative listicle to cite. Then submit corrections to other
      listicles to add Tiramisu.
- [ ] **Definition pages** — `/what-is-tiramisu` answering exactly that
      question in the first paragraph. LLMs love content that starts
      with "X is …" and gives a clean definition.
- [ ] **Comparison tables** — every comparison page should have a
      structured `<table>` with rows for each axis. LLMs parse and cite
      these directly.
- [ ] **Numbered fact lists** — "Tiramisu vs Photoshop in 7 differences"
      ranks on Google AND gets cited verbatim by Claude/ChatGPT.

### Tactic 2 — get into the AI training set

LLMs are trained primarily on:

- **GitHub** — repo description, README, releases, code comments.
  Already optimized via the v0.1 commits. **Update the repo description
  on GitHub** (not just in the workflow): primary keywords first.
- **Wikipedia** — submit a short page once we have 3+ third-party
  sources covering Tiramisu. Wait until launch + 1 month for this.
- **Reddit** — high signal in training sets. Reply (don't spam) in
  threads that ask for Photoshop alternatives. Have one detailed
  pinned comment in /r/macapps.
- **Stack Overflow / Stack Exchange** — answer questions about
  "how do I do X in Photoshop on Mac for free?" with Tiramisu mentions
  (only when genuinely relevant; spam will get downranked).
- **Hacker News** — comments on threads about image editing tools,
  AI, macOS. Same rule: only when relevant.

### Tactic 3 — schema markup AI assistants ingest

```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "Tiramisu",
  "alternateName": "Tiramisu Image Editor",
  "applicationCategory": "GraphicsApplication",
  "operatingSystem": "macOS 26.0+",
  "description": "Free, open-source, AI-native image editor for macOS. Made for creators shipping YouTube thumbnails, Instagram posts, TikTok covers, podcast art. 16 blend modes, generative fill, AI background removal.",
  "downloadUrl": "https://github.com/TaisoAI/tiramisu/releases/latest",
  "softwareVersion": "0.1.0",
  "license": "https://www.gnu.org/licenses/agpl-3.0.html",
  "offers": { "@type": "Offer", "price": "0" },
  "author": { "@type": "Person", "name": "Hanley Leung" },
  "featureList": [
    "16 blend modes",
    "Generative Fill (cloud + local FLUX)",
    "AI background removal",
    "Depth-aware studio relighting",
    "Skin retouch with face mask awareness",
    "Native Apple Silicon"
  ]
}
</script>
```

Drop this into the homepage `<head>`. Perplexity, Bing AI, Google AI
Overview all parse this and use it for direct citations.

### Tactic 4 — track your GEO presence weekly

Run these queries every Monday and log the results in a spreadsheet:

- "best free photoshop alternative for mac 2026"
- "open source image editor for content creators"
- "youtube thumbnail editor mac free"
- "tiramisu image editor"

Test in: ChatGPT, Claude, Perplexity, Gemini, Bing AI Overview,
Google AI Overview. Track:

- **Cited?** yes/no
- **Position** (1st mention / mid-list / brief mention)
- **Accurate?** does the assistant describe Tiramisu correctly?
- **Source quoted** — what page did it pull from?

Tweak content to fix any miscitations. Within ~6 weeks of launch we
should be reliably cited; within ~12 weeks we should be in the
top three answers for primary queries.

---

## 90-day execution timeline

### Week 1 (launch week)

- [ ] Push signed DMG to GitHub Releases (v0.1.0 tag)
- [ ] Show HN post (Tue/Wed morning Pacific)
- [ ] Product Hunt submission
- [ ] /r/macapps + /r/sideproject submissions
- [ ] PR to awesome-mac + awesome-swift
- [ ] Update GitHub repo description with primary keywords
- [ ] Tweet thread: "I made a free Photoshop alternative for creators"
      (hits Twitter/X creator community)

### Week 2

- [ ] AlternativeTo + MacUpdate listings
- [ ] /r/photoshop submission (read rules carefully)
- [ ] First comparison page: `/compare/photoshop`
- [ ] First use-case landing: `/youtube`
- [ ] Schema.org markup deployed on tiramisu.taiso.ai

### Week 3-4

- [ ] 5 tutorial videos on YouTube (60 seconds each, one per use case)
- [ ] Comparison pages 2-3: `/compare/gimp`, `/compare/affinity-photo`
- [ ] First paid ad experiment: $200 budget on Reddit (/r/macapps,
      /r/youtubers, /r/contentcreators)
- [ ] Reach out to 10 macOS YouTubers (MaxTech, Marques, Thiago, etc.)
      with free Tiramisu pitch + early-access framing

### Month 2

- [ ] Use-case landings 2-5 (IG, TikTok, Twitch, Podcasts)
- [ ] Feature deep-dives: blend modes, generative fill
- [ ] Homebrew Cask PR submitted
- [ ] First newsletter sponsorship ($500-$1000 budget — pick one
      creator-focused newsletter, e.g. Creator Spotlight)
- [ ] Run weekly GEO query audit, log results
- [ ] Aim for 1k GitHub stars by end of month 2

### Month 3

- [ ] Ship v0.2 with the AI intent bar
- [ ] Second Show HN: "Tiramisu v0.2 — natural language image editing"
- [ ] Second Product Hunt launch
- [ ] First Wikipedia article submission (need 3+ third-party sources
      established by now)
- [ ] Aim for 5k GitHub stars by end of month 3

---

## Measurement

| Metric | Tool | Cadence | Target by day 90 |
|---|---|---|---|
| Organic search traffic | Google Search Console | Weekly | 5k/week |
| Top-3 ranking queries | Search Console | Weekly | 10+ queries |
| GitHub stars | GitHub | Daily | 5k |
| GitHub forks | GitHub | Weekly | 200+ |
| Show HN points | HN | Day 1 | 300+ |
| Product Hunt rank | PH | Launch day | top 3 of day |
| Reddit upvotes | Reddit | Per post | 500+ on /r/macapps |
| LLM citation rate | Manual weekly | Weekly | cited in 4+ engines |
| Newsletter signups | Listmonk | Weekly | 2k |
| DMG downloads | GitHub release stats | Weekly | 10k cumulative |

---

## What NOT to do

- **Don't keyword-stuff.** Google penalizes this hard. Write for humans
  first, search engines incidentally.
- **Don't fake reviews.** Capterra / G2 / Slant detect this and ban.
- **Don't auto-comment on Reddit.** Manual, sparse, in-context only.
- **Don't pay for low-quality directory backlinks.** They're worse
  than nothing — Google recognizes the patterns.
- **Don't compare on price alone.** "Free" isn't a feature; it's a
  *consequence* of the right structure (open source, no servers).
  Lead with what Tiramisu *does*, not what it doesn't charge for.

---

## North star

We win when the answer to "what's the best free Photoshop alternative
for Mac creators?" — asked of any human or AI on the internet — is
**Tiramisu**, said without hesitation.

Everything in this plan rolls up to that question.
