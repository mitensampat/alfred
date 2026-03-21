# Alfred Imperial Design System

Version: 2.1.0
Origin: Inspired by Stitch design assets, adapted for Alfred's single-column coaching UI.

## Design Philosophy

**Restrained luxury.** Alfred's visual language is editorial, not app-like. Think broadsheet newspaper or private banking statement — sharp, clean, authoritative. Every element earns its space. Decoration is replaced by typography and whitespace.

## Core Principles

1. **Sharp edges everywhere** — `border-radius: 0` on all cards, buttons, chips, pills, action panels. No rounding. This is the single most defining trait of the Imperial style.
2. **Subtle shadows** — `box-shadow: 0 1px 4px rgba(0,0,0,0.06)` on cards, `0 1px 3px rgba(0,0,0,0.04)` on smaller elements (chips, buttons). Never heavy drop shadows.
3. **Left accent borders** — Cards use a 3px left border colored by type. This is how cards "pop subtly" without screaming.
4. **Generous spacing** — 16px gap between cards, 18-20px internal padding. Elements breathe.
5. **Gold as the accent** — `#AF9358` is the signature color. Used for method labels, active states, hover treatments, and the dark mode primary accent. Never overused.
6. **Typography hierarchy** — Serif (Newsreader) for display/titles, sans-serif (Public Sans) for body text. The contrast creates visual authority.

## Color Palette

### Light Mode

| Token | Hex | Usage |
|-------|-----|-------|
| `--canvas` | `#f8f9fb` | Page background |
| `--surface` | `#ffffff` | Card backgrounds |
| `--surface-sunken` | `#f0f2f5` | Recessed areas, hover states |
| `--ink` | `#24292f` | Primary text (charcoal, not black) |
| `--ink-secondary` | `#57606a` | Secondary text |
| `--ink-tertiary` | `#8b949e` | Tertiary text, timestamps |
| `--ink-faint` | `#b1bac4` | Disabled text, faint markers |
| `--line` | `#d8dee4` | Card borders |
| `--line-strong` | `#ced5dc` | Button/chip borders |
| `--coach` | `#24292f` | Coach identity (charcoal in light mode) |
| `--coach-light` | `#eef1f5` | Coach background tint |
| `--growth` | `#2d5a3d` | Growth/relationship observations |
| `--warning` | `#AF9358` | Warning accent (gold) |
| `--danger` | `#8b2332` | Attention/urgency (deep red) |
| `--info` | `#3d6888` | Info accent (steel blue) |
| `--method` | `#AF9358` | Method/framework labels (gold) |

### Dark Mode

| Token | Hex | Usage |
|-------|-----|-------|
| `--canvas` | `#08090a` | Page background (near-black) |
| `--surface` | `#141516` | Card backgrounds |
| `--ink` | `#f7f8f8` | Primary text |
| `--coach` | `#AF9358` | Coach identity flips to gold |
| `--growth` | `#26B5CE` | Growth (teal, higher contrast) |
| `--warning` | `#F0BF00` | Warning (bright gold) |
| `--danger` | `#EB5757` | Attention (brighter red) |
| `--info` | `#AF9358` | Info flips to gold |
| `--method` | `#c4a76e` | Method (lighter gold) |

**Key dark mode behavior:** The coach identity color inverts — charcoal in light mode, gold in dark mode. This makes the gold accent the dominant personality in dark mode.

## Typography

| Role | Font | Weight | Notes |
|------|------|--------|-------|
| Display / Titles | `Newsreader` (serif) | 400-600 | Card titles, weekly review headings, capability card titles |
| Body | `Public Sans` (sans-serif) | 400-500 | All body text, labels, buttons |
| Mono | `SF Mono` / `Menlo` | 400 | Code-like elements |

Fallbacks: `Georgia, serif` for display; `-apple-system, sans-serif` for body.

## Card System

All cards follow the same structural pattern:

```css
.card {
    background: var(--surface);
    border: 1px solid var(--line);
    border-left: 3px solid <type-color>;  /* accent border */
    border-radius: 0;                      /* always sharp */
    box-shadow: 0 1px 4px rgba(0,0,0,0.06);
    padding: 18px 20px;
    margin: 16px 0;
}
```

### Card Type Colors (left border)

| Card Type | Color Token | Purpose |
|-----------|------------|---------|
| Attention | `--danger` | Urgent items needing action |
| Avoidance | `--warning` | Patterns of avoidance (gold) |
| Leverage | `--coach` | Leverage opportunities |
| Relationship | `--growth` | Relationship observations |
| Deep Work | `--method` | Deep work / Cal Newport insights |
| Energy Audit | `--info` | Energy management |
| Follow Through | `--info` | Follow-up reminders |
| Weekly Review | `--method` | Weekly summary (gold) |

### Focus Card (Hero Treatment)

The pinned focus card uses an inverted dark background to stand out as the primary action item:
- Light mode: `background: #24292f` (charcoal), white text
- Dark mode: Gold-tinted border with surface background

## Interactive Elements

### Buttons (`.btn`)

```css
.btn {
    border-radius: 0;
    border: 1px solid var(--line-strong);
    background: transparent;
    box-shadow: 0 1px 3px rgba(0,0,0,0.04);
}
.btn:hover {
    border-color: var(--method);  /* gold hover */
    color: var(--method);
}
```

### Chips (`.chip`) — action shortcuts like Calendar, Overdue, Nudge, Focus

```css
.chip {
    border-radius: 0;
    border: 1px solid var(--line-strong);
    box-shadow: 0 1px 3px rgba(0,0,0,0.04);
}
```

### Capability Pills (`.cap-pill`) — slash command option selectors

```css
.cap-pill {
    border-radius: 0;
    border: 1px solid var(--line-strong);
    box-shadow: 0 1px 3px rgba(0,0,0,0.04);
}
```

### Navigation Pills (`.pill`) — filter toggles

Same sharp treatment as chips and cap-pills.

**Rule: if it's clickable and rectangular, it has sharp corners, a 1px border, and a subtle shadow.**

## Spacing Guidelines

| Context | Value |
|---------|-------|
| Card padding | `18px 20px` |
| Card gap (between cards) | `16px` |
| Card header margin-bottom | `10px` |
| Section gap (time markers) | `28px` |
| Chip/pill padding | `7px 14px` |
| Chip/pill gap | `8px` |

## Shadows

| Level | Value | Usage |
|-------|-------|-------|
| Card | `0 1px 4px rgba(0,0,0,0.06)` | All cards |
| Card hover | `0 2px 10px rgba(0,0,0,0.08)` | Card hover state |
| Small element | `0 1px 3px rgba(0,0,0,0.04)` | Buttons, chips, pills |

## Time Markers

The gold gradient line connecting time markers:
```css
border-left: 2px solid transparent;
border-image: linear-gradient(to bottom, var(--method), transparent) 1;
```

## Input Field

The chat input uses a gold focus ring:
```css
input:focus {
    border-color: var(--method);
    box-shadow: 0 0 0 2px var(--method-light);
}
```

## Anti-Patterns (Don'ts)

- **No rounded corners** on any card, button, chip, or panel
- **No heavy shadows** — keep everything under `0.08` opacity
- **No bright/saturated colors** in light mode — the palette is muted and editorial
- **No filled buttons** for secondary actions — use outlined/transparent
- **No generic grey left borders** — every card should have a type-specific accent color
- **No decoration for decoration's sake** — if it doesn't communicate status or type, remove it

## File Reference

| File | Purpose |
|------|---------|
| `Sources/GUI/Resources/home.html` | Production source (single-file app) |
| `~/.config/alfred/web/home.html` | Hot-reload served file |
| `prototypes/08_imperial_refined.html` | Current approved prototype |
| `prototypes/06_imperial_reskin.html` | Base reskin (tokens only, no card enhancements) |
| `prototypes/07_imperial_cards.html` | Intermediate (card accents, before sharp edges) |
