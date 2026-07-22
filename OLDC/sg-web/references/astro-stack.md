# Astro stack — scaffold, config, templates

Lightweight, static, **zero client JS**. If a bundle appears in
`dist/_astro/*.js`, justify or remove it. Tiny `is:inline` scripts (year stamp,
menu toggle) are fine.

## Project structure
```
site/
├── astro.config.mjs
├── tsconfig.json
├── package.json
├── public/            (favicons, og.png, robots.txt, llms.txt, site.webmanifest, /assets, /images)
└── src/
    ├── consts.ts      (SINGLE source of truth: content, identity, nav, socials, FAQs)
    ├── styles/global.css
    ├── layouts/Base.astro          (head, fonts, JSON-LD graph, skip link)
    ├── components/
    │   ├── SectionHead.astro
    │   ├── Nav.astro  Hero.astro  About.astro  ...  Contact.astro  Footer.astro
    └── pages/index.astro           (just composes components)
```

## package.json (Astro 5 required — see qa-and-gotchas.md)
```json
{
  "name": "site", "type": "module", "version": "1.0.0", "private": true,
  "scripts": { "dev": "astro dev", "start": "astro dev", "build": "astro build",
    "preview": "astro preview", "astro": "astro" },
  "dependencies": { "@astrojs/sitemap": "^3.3.0", "astro": "^5.6.1" }
}
```

## astro.config.mjs
```js
import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
export const SITE_URL = "https://example.com";
export default defineConfig({
  site: SITE_URL,
  trailingSlash: "never",
  integrations: [sitemap()],           // -> sitemap-index.xml + sitemap-0.xml
  build: { inlineStylesheets: "auto" },// do NOT set build.format:"file" with sitemap
  compressHTML: true,
});
```

## tsconfig.json
```json
{ "extends": "astro/tsconfigs/strict", "include": [".astro/types.d.ts", "**/*"], "exclude": ["dist"] }
```

## global.css — token + primitive skeleton
Put the palette tokens (design-system.md §2) in `:root`, then these primitives:
```css
* { box-sizing: border-box; margin: 0; padding: 0; }
html { -webkit-text-size-adjust: 100%; scroll-behavior: smooth; scroll-padding-top: 84px; }
body { font-family: var(--f-text); background: var(--bg); color: var(--ink);
  line-height: 1.55; font-size: 17px; -webkit-font-smoothing: antialiased; }
a, button { -webkit-tap-highlight-color: transparent; }
a { color: inherit; text-decoration: none; }
img, svg { display: block; max-width: 100%; }
::selection { background: var(--accent); color: var(--accent-ink); }
.wrap { max-width: 1140px; margin: 0 auto; padding-inline: clamp(18px,4vw,40px); }
.section { padding-block: clamp(48px,7vw,92px); border-top: 1px solid var(--edge); }
/* .link gradient underline */
.link { background-image: linear-gradient(var(--accent),var(--accent));
  background-position: 0 100%; background-repeat: no-repeat; background-size: 0% 1.5px;
  transition: background-size .28s cubic-bezier(0.2,0,0,1); }
.link:hover,.link:focus-visible { background-size: 100% 1.5px; }
/* buttons: raw, sharp, PRE-ALLOCATED border (jerk-free) */
.btn { display:inline-flex; align-items:center; gap:8px; font-family:var(--f-mono);
  font-size:12px; letter-spacing:.1em; text-transform:uppercase; padding:12px 18px;
  background:transparent; color:var(--ink); border:1px solid var(--edge); cursor:pointer;
  transition:background .18s,color .18s; }
.btn-primary { background:var(--accent); color:var(--accent-ink); border-color:var(--accent); }
.btn-ghost:hover { background:var(--ink); color:var(--bg); }
```
Define `--f-display / --f-text / --f-mono` and `--edge: var(--ink)` in `:root`.
Add three responsive `@media` blocks (≈900 / 560 / 380px): collapse multi-column
grids to one column, tighten section/card/gap padding, ≥44px menu button, hero
headline floor, full-width primary buttons, safe-area insets. Close with a
`@media (prefers-reduced-motion: reduce)` that kills transitions.

## Base.astro (head essentials)
- `<meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1" />`
- canonical, `theme-color` + `color-scheme` matching the palette, favicon set, manifest.
- Fonts non-render-blocking: `preconnect` + `preload as="style"` + stylesheet swapped
  on load (`media="print" onload="this.media='all'"`) + `<noscript>` fallback.
  Google Fonts URL for the locked stack:
  `https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,500;12..96,600;12..96,700&family=Instrument+Sans:wght@400;500;600&family=JetBrains+Mono:wght@400;500;600;700&display=swap`
- OG (`og:image` 1200×630 + alt) + Twitter `summary_large_image`.
- `<link rel="sitemap" href="/sitemap-index.xml" />`
- One `<script type="application/ld+json">` with the `@graph` (see seo-playbook.md).
- Body: an a11y skip link, then `<slot />`.

## consts.ts pattern
Export `SITE`, `SITE_URL`, the entity (`PERSON` or `ORG`), `NAV`, and every
content array (projects, ventures, skills, certs, FAQs, socials). Components and
the schema graph both read from here so nothing drifts.

## Deploy (Vercel)
`cleanUrls: true`, `trailingSlash: false`, immutable `Cache-Control` on
`/assets`, `/images`, static binaries; correct content-types for `robots.txt` +
sitemap. Images: `.webp`, compressed, explicit `width`/`height` (no CLS),
`loading="lazy"` below the fold, descriptive `alt`.
