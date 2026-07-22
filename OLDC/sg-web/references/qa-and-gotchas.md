# QA checklist, hard NOs, and solved gotchas

## Hard NOs — always avoid
- Generic SaaS gradients, glowing orbs, floating/3D, bubbly rounded buttons,
  arbitrary shadows, fade-up-on-scroll — anything "AI-esque" / template-looking.
- Orange/vermilion accent. The accent is green (personal brand).
- Stark pure `#fff` / `#000` for personal work — use warm cream + green-black.
- The Space Grotesk / Inter / Space Mono default trio when distinctiveness matters.
- Accented characters / fancy glyphs in copy (é, smart-quote clutter). ASCII words.
- Location references in copy or schema.
- Client-side JS frameworks or stray bundles; keep zero-JS static.
- Hand-rolled `sitemap.xml` when using Astro — use the integration.
- `@astrojs/sitemap` on Astro 4 (crashes — see gotchas).
- Repeating `Organization` schema on child pages.
- Faking a searchbox `SearchAction` with no backing endpoint.
- Layout shift on hover; un-pre-allocated borders.
- Tap targets < 44px; desktop-sized gaps on mobile; horizontal overflow.

## Pre-ship QA checklist
**Build & schema**
- [ ] `npm run build` clean; `sitemap-index.xml` + `sitemap-0.xml` generated.
- [ ] JSON-LD parses as one `@graph`; validate in Google Rich Results Test —
      Person/Org, WebSite, page type, SiteNavigationElement, FAQPage present.
- [ ] Exactly one `<h1>`; clean `H1→H2→H3`.
- [ ] Zero framework JS bundles in `dist/_astro/`.
- [ ] Canonical + `trailingSlash` consistent; `robots.txt`→`/sitemap-index.xml`;
      sitemap `lastmod` current.

**Content & identity**
- [ ] `rel="me"` on socials; reciprocal `sameAs`; Wikidata linked (if any).
- [ ] `llms.txt` present + accurate; honest `datePublished`/`dateModified`.
- [ ] No accented characters; no location references; modest role labels.
- [ ] Images: descriptive `alt`, explicit dimensions, lazy, `.webp`, compressed.

**Mobile (test 320 / 360 / 390 / 430px)**
- [ ] No horizontal scroll; hero headline never overflows (safe clamp floor).
- [ ] Menu toggle ≥44px; all interactive elements comfortably tappable.
- [ ] Multi-column blocks collapse to one column; gaps tightened.
- [ ] `env(safe-area-inset-*)` respected top + bottom.
- [ ] Primary buttons full-width / thumb-friendly on small screens.
- [ ] No iOS blue tap-highlight flash.

**Polish**
- [ ] Palette matches the locked tokens; single accent only.
- [ ] Distinct type loaded non-render-blocking with `<noscript>` fallback.
- [ ] No layout shift on any hover/focus; `prefers-reduced-motion` honored.

## Solved gotchas — do not re-derive
- **`@astrojs/sitemap` needs Astro 5.** v3.7+ reads the `astro:routes:resolved`
  hook absent in Astro 4 → build crashes `Cannot read properties of undefined
  (reading 'reduce')` at `astro:build:done`. Fix: Astro `^5.6.1`, then
  `npm install` to refresh the lockfile.
- **Don't combine `build.format:"file"` with the sitemap integration.** Use the
  default directory format; single-page output is identical (`dist/index.html`).
- **No sitelinks-searchbox without a real search endpoint** — fails validation.
  Use `SiteNavigationElement` for one-page sites.
- **Sitelinks + external backlinks are earned, not declared.** Set only the
  on-site signals; never claim you created them.
- **Recurring copy edits**: "Founder"→"Pilot"; "Résumé"→"Resume"; strip any
  city/country ("Bengaluru").
- **`inlineStylesheets:"auto"`** leaves a ~13KB stylesheet external (above the
  inline threshold) — expected and fine (cached, one small request).

## Build-in-a-sandbox notes
If a read-only mount makes `astro build` fail at finalize (EPERM unlinking temp
`dist/pages/*.mjs`) or `rm` says "Operation not permitted", build a copy under
ordinary `/tmp` where the finalize + integration hooks can complete. A clean
`npm install` there also restores rollup's native binary if a copied
`node_modules` lost it.
