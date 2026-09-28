# Handoff: Aurelhaven — Isekai Walled-Capital Lore Codex (6 variants)

## Overview
A worldbuilding wiki / lore codex for a fictional isekai world whose Western-European capital, **Aurelhaven**, is a circular city with four concentric walls. Each wall belongs to one era (inspired by Age of Empires / Civilization era progression). The tone is warm, slice-of-life (markets, taverns), with a surreal level of about 6/10. The design centres on a three.js scene: a dawn flyover, walls rising ring by ring, houses floating down like stones, a district map, and a night mode with lanterns and an aurora.

## About the Design Files
The files here are **design references built in HTML**. They are prototypes that show the intended look and behaviour. They are not production code to copy directly. Recreate them in the target codebase using its own patterns. If no codebase exists yet, a good fit is **Next.js/React + react-three-fiber (or vanilla three.js) + GSAP ScrollTrigger or Lenis**.

- `*.dc.html` files are "Design Components". Each has a markup template with `{{ }}` holes and a `class Component extends DCLogic` logic block (React-class-like: `state`, `setState`, `renderVals()` returns the template's values). `support.js` is the runtime that lets them open in a browser. You don't need it in production.
- `city-scene.js` is a plain ES module with the whole three.js scene. It can be ported almost as-is.
- To preview: serve the folder over HTTP (for example `npx serve`) and open any `.dc.html`. three.js loads from unpkg (`three@0.160.0`).

## Fidelity
**Mid-to-high fidelity.** Layout, type, colour, copy and motion concepts are final-intent. The 3D is **procedural placeholder geometry**: cylinders and cones for walls and towers, instanced boxes and pyramids for houses. Swap in authored GLB assets (modular medieval kit, cathedral, keep), PBR materials, and post-processing (bloom, depth of field, SSAO, god-rays) for the "Netflix-grade" finish.

## Shared 3D scene — `city-scene.js`
`mount(canvas, options)` returns `{ setScroll(s), setEra(e), setNight(n), highlight(districtIndex|-1), dispose() }`.

**World layout (units ≈ metres ×10)**
- Wall ring radii: `[5.5, 11, 17, 24]`. Wall height is `1.2 + k*0.5`. There are `6 + k*4` towers per ring, each with a red cone roof `#a8472b`. Stone is `#cdbb9a`.
- Keep: 5 towers at the centre with blue-slate roofs `#2f4d7a` (metalness 0.4). A gold torus "Summoning Font" `#ffd27a` spins at y = 11.5.
- Houses: about 1,300 instances across 4 rings (counts 40/260/420/620). They avoid the river band. Roof colours cycle through the `roofs` option.
- River: a tube along `z = sin(x*0.13)*3.5 + 2`, flattened (scale y 0.08). Colour `#3f7f9c`, emissive `#1b4d6b`.
- Floating islands: inverted-cone rocks with a grass top and a hut. They orbit at radius 32+ and height 16+, bobbing.
- Motes: 1,400 additive points rising. Gold `#ffd98a` by day, cyan `#9fe8ff` at night.
- Night: 2,000 stars and two aurora planes (a custom shader, green `#33ff99` → violet `#9966ff`, additive, waving). House emissive is `#ffb14a`, ramping 0 → 1.1.
- District highlight: a pulsing gold `#ffcf6b` ring-sector on the ground (opacity about 0.45 ±25%).
- Lighting: hemisphere light `#ffe9cf`/`#5a4a36`, 0.9 → 0.3 at night. Sun `#ffc78f`, intensity 2.4 → 0.5 at night, colour lerps to `#7f95ff`. Soft shadows at 2048. ACES tone mapping. Fog runs from 40 to 140 and matches the background.

**Motion rules**
- `e` (era, 0–4): ring k's walls scale up in Y with easeOutCubic over `e ∈ [k, k+1]`. Houses in ring k start 10–22 units up, spin, bob, and land with a staggered delay. The keep rises at `e*1.3`.
- `n` (night, 0–1): lerps the background, fog, lights, emissive, stars and aurora.
- Camera: keyframes `{s, r, y, a}` on an orbit around the origin, smoothstep between frames. Scroll is low-pass filtered (`sCur += (S - sCur)*0.06`). There is also an idle drift of `+0.015 rad/s`.
- Default mapping (V1): `e = clamp(s - 0.4, 0, 4)` and `n = smoothstep(6.7, 7.5, s)`, where `s = scrollY / innerHeight`.

**Options:** `day`, `night`, `ground`, `roofs[]`, `islands`, `hex` (adds a hex-tile terrain ring from r27 to r75, six terrain colours), `era` / `nightFixed` (hold era or night at a fixed value), `kf` (camera keyframes), `lookY`.

## Screens / Variants

### V1 — Aurelhaven Codex (scroll story)
- A fixed full-screen canvas, with a vignette on top: `radial-gradient(transparent 55%, rgba(20,10,5,.45))`.
- **Header** (fixed, padding 18/32): the wordmark "AURELHAVEN" in Cormorant 600 26px, letter-spacing .06em, followed by "THE RINGED CODEX" in JetBrains Mono 10px, .2em. Nav links are Mono 11px, .14em, with the active one at opacity 1 and the rest at .55.
- **Hero** (100vh, bottom-aligned, padding 0 6vw 16vh): an eyebrow in Mono 12px, .3em, "YEAR 412 OF THE OTHERWORLD RECKONING". The H1 "Aurelhaven" is Cormorant 500, `clamp(64px,11vw,176px)`, line-height .88. Body text is Spectral 19px/1.55, max-width 520.
- **Era sections ×4** (100vh each): a parchment card, 420px max, background `rgba(247,236,216,.94)`, padding 36, radius 2, shadow `0 30px 80px rgba(40,20,5,.35)`. It shows the era number and years (Mono 11px, `#8a5a3a`), an H2 in Cormorant 600 44px, a body in Spectral 17/1.6 `#3b2a1e`, and a stats footer (WALL, SOULS).
- **District map** (210vh, sticky inner): the camera goes top-down.
  - Left, 300px: a list of 6 district buttons. Idle: `rgba(20,12,6,.55)` background with `#f7ecd8` text. Active or hover: `rgba(247,236,216,.98)` background with `#2a1d14` text. Hovering or clicking highlights that sector in 3D.
  - Right, 360px: a codex card showing CODEX · number · RING, the name (Cormorant 38px), an italic motto in `#8f3b25`, the body text, and FOUNDED / KNOWN FOR.
- **Night** (130vh, centred): an eyebrow "THE LANTERN HOURS" in `#a9f0d0` and an H2 "When the walls light up" with a cyan glow.
- **Timeline pill** (fixed bottom centre): `rgba(20,12,6,.55)` with a 10px backdrop blur and 7 stops. Each dot is 10px with a `#d9a441` border, filled once passed. Clicking a stop smooth-scrolls to its section.

### V2 — Cartographer's Table (scale zoom)
- Grid: sidebar `minmax(300px,380px)` and map `1fr`. Parchment `#f1e6cc` on `#e9dcc0`. Type is IM Fell English.
- 4 levels: Continent (1:2,000,000) → Capital (1:40,000) → Guild Quarter (1:4,000) → Street (1:200). Scroll is 500vh and `s` maps to the camera keyframes (from altitude 150 down to street level 3).
- The map frame has a double rule (2px border plus a 1px outline at offset 6) and a sepia filter on the canvas. It also has a compass rose (64px circle, "N") and a scale bar that shows the current ratio.
- Era is locked at 4, night at 0, with hex terrain on.

### V3 — Lantern Hours (night, era slider)
- Night is locked at 1. There are 8 islands.
- Centred title "The Lantern Hours" in Cormorant italic `clamp(56px,9vw,140px)` with a cyan glow.
- An era slider pill (560px max, `rgba(10,14,40,.6)` with blur, border `rgba(169,240,208,.25)`) drives `setEra` live. It shows the souls count.
- 4 hour cards in an `auto-fit minmax(200px,1fr)` grid: `rgba(14,18,48,.72)` with a gold border at 22% alpha. On hover the border becomes `#ffd27a`.

### V4 — Illuminated Manuscript (book spread)
- A 2-column page, max 1320, parchment `#f3e8cf` with a gold inset rule `#b08a4a`.
- Left: 5 chapters, each at least 100vh. Each has "CAPITULUM N" and a drop cap in UnifrakturMaguntia 84px `#8f3b25` on `#e7d3a6`. Body text is EB Garamond 20/1.65.
- Right: a sticky arched window (`border-radius: 50% 50% 4px 4px / 28% 28% 4px 4px`) holding the canvas, with the caption "Plate N. The city as it stood in its …".
- Page scroll progress (0–1) maps to `s` from 0 to 7.6, so the city builds and then turns to night.

### V5 — Dreamfall (surreal)
- A pastel scene: day `#e8b9d0`, night `#2a1b4a`, roofs teal, violet, rose and amber. 14 islands.
- The camera starts at ground level (y 1.5) looking up at the falling houses, then pulls out to y 34.
- A giant "Aurelhaven" in Italiana `clamp(120px,22vw,380px)`, `mix-blend-mode: overlay`, parallaxes at −60px per viewport.
- 5 story beats, each positioned in a different corner of the screen.

### V6 — Hex Realm (Civilization-style, click-driven, no scroll)
- A top resource bar (ERA / SOULS / GOLD / MANA) in Cinzel and Mono, background `#1b140e`, border `#6b5230`.
- Left, the "ERA TREE": 4 buttons, each with a hex badge made with clip-path. The badge is gold `#e0b560` once unlocked.
- Bottom right: a current-era card and a CTA in `#8f3b25` (hover `#a8472b`), "ADVANCE TO ERA N". It tweens `setEra` over 2,200ms with easeOutCubic.
- Hex terrain is on and the camera is fixed isometric (r 46, y 44).

## State
- V1: `s` (scroll in viewports), `sel` (district index), `hover` (−1 or index).
- V2: `s`, which gives the level index.
- V3: `era` (float 0–4).
- V4: `s`, which gives the chapter/plate index.
- V5: `s`.
- V6: `target` era (1–4) plus a tweened `cur`.

There is no data fetching. All copy is in constants (`ERAS`, `DIST`, `LV`, `CARDS`, `CH`, `BEATS`) inside each file's logic block. These could move into a CMS or MDX for a real wiki.

## Design Tokens
**Colours**
- Parchment: `#f7ecd8`, `#f1e6cc`, `#f3e8cf`
- Ink: `#2a1d14`, `#3b2a1e`, `#5b4230`
- Sepia label: `#8a5a3a` / `#7a5536`
- Terracotta: `#8f3b25`, `#a8472b`
- Gold: `#d9a441`, `#e0b560`, `#ffd27a`
- Night navy: `#0d1230`
- Mint aurora: `#a9f0d0`
- Stone: `#cdbb9a`
- Grass: `#8d9a5b`
- Dawn sky: `#f2b98c`

**Type**
- Cormorant 500/600 for display
- Spectral 400 for body
- JetBrains Mono 500 for labels, uppercase, letter-spacing .1–.3em
- Per variant: IM Fell English (V2), EB Garamond + UnifrakturMaguntia (V4), Italiana (V5), Cinzel (V6)

**Other values**
- Radius 2–3px on cards, 999px on pills
- Card shadow `0 30px 80px rgba(40,20,5,.35)`
- Spacing is mostly 12 / 14 / 18 / 22 / 28 / 36 px, with page gutters of 4–7vw

## Assets
None. Everything is procedural or comes from Google Fonts. Suggested upgrades:
- A GLB medieval city kit
- Key art or illustrations for each codex entry
- An ambient audio bed (market murmur, bells)
- An HDRI for dawn and one for night

## Suggested Claude Code next steps
1. Scaffold Vite or Next with react-three-fiber and port `city-scene.js` into components (`<Walls/>`, `<Houses instanced/>`, `<Sky/>`, `<Aurora/>`).
2. Add `@react-three/postprocessing` (Bloom, DepthOfField, Vignette, N8AO) and replace the placeholder geometry with GLB models.
3. Drive the timeline with GSAP ScrollTrigger and Lenis smooth scroll.
4. Add raycast picking on the 3D districts so they can be clicked directly, not only through the list.

## Files
- `V1 Aurelhaven Codex.dc.html`
- `V2 Cartographer's Table.dc.html`
- `V3 Lantern Hours.dc.html`
- `V4 Illuminated Manuscript.dc.html`
- `V5 Dreamfall.dc.html`
- `V6 Hex Realm.dc.html`
- `city-scene.js` (shared three.js scene)
- `support.js` (preview runtime only)
