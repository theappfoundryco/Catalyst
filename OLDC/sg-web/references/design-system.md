# Design system — the aesthetic law

Brutalist-minimalist. Confident, grounded, mathematically precise, technically
flawless. The output must not look "AI-generated." Read all of this before
writing CSS.

## 1. Core philosophy
- **Anti-boilerplate**: never generic SaaS gradients, glowing orbs, floating 3D,
  bubbly rounded buttons, or arbitrary drop shadows.
- **Distinct, not default**: characterful type, unusual-but-precise primitives
  (numbered indices, spec tables, bordered hairline grids), restraint. If it
  looks like a component-library template, redo it.
- **Confidence through restraint**: if an element doesn't serve a structural or
  storytelling purpose, cut it.
- **Location-agnostic**: no cities/countries/regions in copy, footer, hero
  eyebrows, or schema unless explicitly requested.
- **Raw UI**: strip default browser styling. Interactive elements get
  `background: transparent`, deliberate hairline or none, explicit
  `color: var(--ink)`, and `-webkit-tap-highlight-color: transparent` on
  `a, button` so iOS doesn't paint blue.

## 2. Color & type
- **One accent, always.** Used only for primary CTAs, live/success states, index
  numbers, and subtle tracing. Hover/secondary states come from opacity or
  `color-mix()` on the tokens — don't invent new hex.
- **Personal-brand palette is LOCKED** (accent green, never orange; warm cream,
  never stark white; ink is green-black, never `#000`):

```css
--bg:        #fcfaf5;  /* warm cream paper */
--bg-inset:  #f2ede1;  /* deeper inset panels */
--paper:     #fffdf8;  /* barely-raised surface */
--ink:       #22301f;  /* green-black: text + structural borders */
--ink-2:     #56604f;  /* muted body */
--ink-3:     #8a917f;  /* faint meta */
--line:      #e7e1d3;  /* hairline */
--line-2:    #d8d1bf;  /* stronger hairline */
--accent:    #3f6b4f;  /* the one green signal */
--accent-deep:#2b4a37;
--accent-ink:#fcfaf5;  /* text on accent */
```
  For a starker product/studio look, a near-black + off-white + one accent is
  acceptable — but keep a single accent and warm neutrals over clinical grays.

- **Type stack (deliberately not the tired default trio):**
  - Display/headings: **Bricolage Grotesque** — tight tracking `-0.02em` to `-0.045em`.
  - Body/UI: **Instrument Sans**.
  - Meta/labels/indices/tags/nav: **JetBrains Mono**, uppercase, `0.12em–0.16em`.
  - Avoid Space Grotesk + Inter + Space Mono together — it's everywhere.
- **`.link` utility**: no global `<a>` underlines. A deliberate class paints a
  gradient underline animated via `background-size`. Card/image links must not
  double-underline on hover.

## 3. Layout & mobile mechanics
- **Jerk-free**: zero layout shift. Pre-allocate a `1px` transparent border if
  hover adds one. State changes never push neighbors.
- **Hairlines**: `1px solid var(--line)` for structure; sharp `0` edges (or ≤8px).
- **Fluid sizing**: `clamp()` for font, padding, gaps — perfect from 320px to 4K.
  Give hero headlines a safe floor so they never overflow small phones.
- **Tighten mobile**: step desktop gaps down aggressively in `@media` so the page
  reads as one cohesive column.
- **Safe areas**: `env(safe-area-inset-top)` on sticky top UI,
  `env(safe-area-inset-bottom)` on the footer.
- **Tap targets ≥44×44px**; expand with padding + negative margin.

## 4. Navigation
- Sticky main nav (`position: sticky; top: 0;`, high z-index). Sub-navs stack
  beneath (`top: 66px`) and degrade to `overflow-x: auto; white-space: nowrap;`
  before the hamburger breakpoint.
- Mobile toggle: swap raw SVG icons or a plain "Menu/Close" text button. Never
  animate hamburger lines into an X with transform math (device rounding
  misaligns them).

## 5. Legal & corporate (hub & spoke, for studios/products)
- Umbrella `/terms` + `/privacy` govern the site; each app gets its own
  exhaustive EULA/privacy (e.g. `/catalyst/terms`) covering exactly what it does
  to the local machine, destructive-command disclaimers, and data transmitted.
- Footers are static and predictable — always point to umbrella policies; never
  swap destinations by URL. Route to app policies via thick-accent callout boxes
  at the top of umbrella docs instead.
- Legal pages: `grid-template-columns: 240px 1fr` with a sticky `<aside>` TOC.
  On mobile, move intro text above the collapsed TOC.

## 6. Animation & SVG
- Grounded, not floaty: no fade-up-on-scroll stagger. If animating, crisp fast
  easing `cubic-bezier(0.2, 0, 0, 1)`. Honor `prefers-reduced-motion`.
- Lenis (if used): `lerp: 0.12`, `wheelMultiplier ~0.85–1.0`.
- Absolute SVG: `viewBox` must match container width/height; match viewBox height
  to max CSS height on mobile so `Y=0` locks to the top (avoids the centering bug).

## 7. Signature elements that land well
Numbered section indices (`01`–`0n` in mono accent) · a **spec / key-value
table** instead of a rounded "snapshot card" · **bordered hairline grids** for
work/skills/ventures · **grayscale→color** image reveal on card hover · mono
uppercase metadata everywhere · sharp `0`-radius edges · full-width thumb-
friendly buttons on mobile.

## 8. Voice
- Understated, confident, lightly playful. Section notes carry the wink
  ("weekends & too much coffee", "proof I sat through the courses").
- Modest role labels: **Pilot / Copilot**, not Founder/CEO.
- **Plain ASCII only** — "Resume", never "Résumé". Directional arrows (↗) are fine.
- Concise. Cut words that don't earn their place. No marketing fluff.
