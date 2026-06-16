# Limpet hero image candidates

AI-generated hero/banner candidates for the README. Generated with **Nano Banana Pro**
(`gemini-3-pro-image`, Gemini image API), 1376×768 (16:9). Brand palette: cobalt blue
`#0A42D3`, hotspot/online green `#1D9E6A`.

**Metaphor (must hold):** at home and at the office the internet comes from a **Wi-Fi router
(blue)**; on the go it comes from the **phone hotspot (green)**; the laptop stays online at
every stop.

> **Status:** the README intentionally uses the hand-built vector `../concept.svg` as its
> visual. These AI heroes are kept for possible future use (social/OG preview card, a project
> site, docs). Preferred candidate: `hero-framed-flow-a.png`.

| File | Concept | Status |
|---|---|---|
| `hero-framed.png` | **Chosen direction.** Three framed scenes in a row — home (blue router → laptop), on-the-go (cyclist + train + stroller, green phone hotspot → laptop), office (blue router → laptop). | Lead candidate; exploring "flow between cards" edits. |
| `hero-panorama.png` | Three clearly-separated areas with a warmer editorial feel; same metaphor. | Backup. |
| `hero-isometric.png` | Single isometric "on the go" rider — laptop in backpack, green phone hotspot arc. | Saved as a standalone banner accent. |
| `hero-framed-flow-a.png` | Edit of `hero-framed`: keeps the three cards, adds dotted arrows linking them (home → on the go → office). | **Preferred AI candidate (chosen).** |
| `hero-framed-flow-b.png` | Edit of `hero-framed`: merged into one continuous panoramic journey, with empty bands top/bottom for a title overlay. | Alternative. |

## Prompts (for regeneration)

**hero-framed** — `A wide 16:9 flat editorial illustration on a light background, three SEPARATE
rounded-rectangle framed scenes in a neat evenly-spaced row: LEFT 'at home' a cozy living room
with a Wi-Fi router glowing blue beside an open laptop; MIDDLE 'on the go' an outdoor commute
with a person cycling, a train passing behind, and someone walking with a baby stroller, a
smartphone sending a green hotspot to a laptop; RIGHT 'at the office' a glass office with a
Wi-Fi router glowing blue beside a laptop. Polished, balanced, premium flat illustration.`
\+ metaphor rule (router blue home/office, phone green on the go; no single connecting thread;
cobalt #0A42D3 / green #1D9E6A; laptop online everywhere; no text).

**hero-panorama** — `A wide 16:9 flat editorial illustration, light background, three clearly
separated areas left to right: LEFT a home interior with a Wi-Fi router glowing blue beside a
laptop; MIDDLE an outdoor commute (cyclist, train, baby stroller) where a smartphone sends a
green hotspot link to a laptop; RIGHT a glass office with a Wi-Fi router glowing blue beside a
laptop.` \+ same metaphor rule.

**hero-isometric** — `A clean flat isometric vector illustration for a README hero banner, wide
16:9. A person rides a bicycle with an open backpack; inside, a glowing MacBook is online; their
smartphone emits a vivid green Wi-Fi hotspot arc connecting to the laptop. Modern, minimal,
geometric, soft long shadows. Cobalt blue (#0A42D3), green (#1D9E6A) signal, light off-white
background, generous negative space. No text.`

## Notes
- Untracked / not committed. Full exploration set (rejected directions) lives in `../ai-hero/`.
- For README use, export/screenshot at 2× or keep as-is (1376px is plenty for a 900px hero).
