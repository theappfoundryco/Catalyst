---
name: sg-web
description: >-
  Shivang Gulati's end-to-end system for designing and building websites in his
  signature "brutalist-minimalist / Neo42" style on a lightweight Astro stack.
  Use this skill WHENEVER the user wants to build, design, redesign, scaffold, or
  restyle ANY website — a portfolio or personal site, a product / marketing /
  landing page, a studio or company site, or a technical / docs site — even if
  they don't say "Neo42" or "brutalist". Also trigger when the user asks to add
  SEO / structured data / JSON-LD entity graph / sitemap / llms.txt / sitelinks
  to a site, wants an existing site to "match my style" or "look like
  shivanggulati.com / The App Foundry", or asks for a distinct, non-"AI-looking"
  web design. If the task is "make me a website" in any form, use this skill.
---

# sg-web — Shivang's website design & build system

This skill turns a brief ("build me a portfolio / product / marketing / docs
site with these details") into a finished, shipped-quality site that matches
Shivang's taste and stack: confident brutalist-minimalist design, a
characterful type system, one deliberate accent, a lightweight zero-JS Astro
build, and a rigorous SEO/AEO/GEO entity graph.

The design law and the concrete templates live in `references/`. Read the files
you need for the job (pointers below) rather than loading everything at once.

## The prime directive

Make it **not look AI-generated**. If the layout could have come from any
component library or SaaS template, it's wrong. Distinct from the font down to
the smallest element; confident through restraint; grounded, never floaty.

## Workflow

### 1. Gather the brief (ask before building)

Use the multiple-choice question tool to lock scope before writing code. Ask
about the things that actually change the output — don't interrogate. Cover:

- **Site type**: portfolio / personal · product or app · marketing or landing ·
  studio or company · technical or docs. (Drives architecture + schema + palette
  variant — see "Adapt by site type" below.)
- **Sections / pages** wanted, and the single primary call-to-action.
- **Identity**: brand or person name, one-line positioning, domain, logo/mark if
  any, and which accent direction (default to the locked green for personal work;
  see `references/design-system.md` §Palette).
- **Content source**: are they giving copy/projects/FAQs now, or should you draft
  placeholder-quality real copy in their voice?
- **Deploy target** (default Vercel) and whether they already have a repo.

If the user already handed over full details, skip straight to building and only
ask about genuine forks.

### 2. Read the relevant references

- `references/design-system.md` — the aesthetic law, locked palette + type,
  signature layout elements, voice. **Read this every time.**
- `references/astro-stack.md` — project scaffold, config, file structure, and
  copy-paste templates for `Base.astro`, `global.css` tokens, `consts.ts`, and
  section components. **Read this every time you're building/scaffolding.**
- `references/seo-playbook.md` — the JSON-LD `@graph`, SiteNavigationElement,
  FAQPage, `llms.txt`, sitemap wiring. Read when wiring SEO (almost always).
- `references/qa-and-gotchas.md` — the "never" list, the pre-ship QA checklist,
  and solved bugs (Astro-5-for-sitemap, no fake searchbox, etc.). Read before
  shipping, every time.

### 3. Build in this order

1. Scaffold the Astro project per `astro-stack.md` (config, tsconfig, package.json).
2. Lay the design tokens into `global.css` (palette variant + type stack + the
   base primitives: `.wrap`, `.section`, `.link`, buttons, hairlines).
3. Put all content/identity in `src/consts.ts` — single source of truth.
4. Build one component per section (`Nav`, `Hero`, …, `Footer`, shared
   `SectionHead`); `index.astro` just composes them. Head + schema live in `Base.astro`.
5. Wire the SEO/AEO/GEO graph from `consts.ts` per `seo-playbook.md`.
6. Build, then run the full QA checklist in `qa-and-gotchas.md` (schema validity,
   one H1, zero JS bundles, and the mobile pass at 320–430px).

### 4. Verify and hand off

Build the site (`npm run build`), confirm `sitemap-index.xml` generated and the
JSON-LD parses as one `@graph`. Present the built `index.html` so the user can
open and resize it. Note anything they must do on their side (e.g. `npm install`
after an Astro version bump). Never claim external backlinks or Google sitelinks
were "created" — you set the on-site signals that make them possible.

## Adapt by site type

The core law is constant; these vary:

- **Portfolio / personal** → single page with numbered sections; warm cream/green
  locked palette; `Person` + `ProfilePage` schema, `hasOccupation` for every
  facet; understated Pilot/Copilot voice.
- **Product / app** → hero + features + pricing + download; `SoftwareApplication`
  schema alongside the org; clear one CTA; can run starker monochrome + one accent.
- **Marketing / landing** → tighter funnel, one dominant CTA, social proof as
  bordered spec rows, FAQ for AEO.
- **Studio / company** → hub-and-spoke legal architecture (umbrella `/terms`,
  `/privacy` + per-app EULAs), `Organization` entity, multi-page.
- **Technical / docs** → two-column sticky TOC (`240px 1fr`), heavier monospace,
  code styling; on mobile move intro above the collapsed TOC.

See `references/design-system.md` §5 and `seo-playbook.md` for the specifics.

## Non-negotiables (full list in qa-and-gotchas.md)

Single deliberate accent · warm-cream-not-stark base for personal work · accent
is green, never orange · distinct type (avoid the Space Grotesk/Inter/Space Mono
default trio) · ASCII copy only (Resume, not Résumé) · location-agnostic · zero
client JS · hairlines + sharp edges, no gradients/orbs/floaty animation · pre-
allocated borders (no layout shift) · ≥44px tap targets · one `@graph`, declared
once. When in doubt, restraint.
