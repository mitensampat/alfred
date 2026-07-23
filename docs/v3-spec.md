# Alfred v3 — Build Spec

Elegant rebuild of the three surfaces, integrated, on a Ralph Lauren white/blue/silver palette.
Prototype: v3 artifact. Now & You jobs settled by debate; Model made walkable.

## The four jobs (frozen)

- **Now** — the 4 workspaces you're in + 1 that needs you. A work companion, not a feed.
- **You** — recent belief/lens/workspace updates + the door to the model. **Kept as-is; reskinned only.**
- **Model** — find anything across everything, then walk the graph.
- **Settings** — confirm it's running, get out.

## Palette — Ralph Lauren white / blue / silver

Central token swap in `home.html` `:root` blocks. Navy replaces bronze everywhere (`--sm-accent`).

| token | light | dark |
|---|---|---|
| paper | `#f6f8fb` | `#0b1219` |
| surface | `#ffffff` | `#111a24` |
| surface-sunken | `#eef2f6` | `#0e1720` |
| ink | `#14243a` | `#eaf1f8` |
| ink-tertiary | `#8a99ab` | `#6d7f92` |
| line | `#d8e0e8` | `#202c3a` |
| accent (navy) | `#1c3d6e` | `#6f9fd8` |
| accent-soft | `#e8eef6` | `#14202e` |
| accent-line | `#c6d5e8` | `#26384d` |
| hot (flag red, urgent only) | `#9c2b39` | `#d98a92` |
| green (grounded) | `#35544a` | `#6fae9e` |

Silver is the neutral family (lines, ink-tertiary, sunken). Red is used *only* for genuine urgency
(the RL flag motif), never decoration. Fonts unchanged: Newsreader / Public Sans / SF Mono.

## Now — the 4 + 1

**Ranking.** Workspace = theme facet. Recency of *your* interaction ≈ `max(reflection.created_at)`
among reflections tagged to that theme (reflections come from your threads/notes/calendar, so this
is your activity, not Alfred's sync). Owed items count as a recency signal (option 3).

- Slots 1–4: workspaces by recency desc.
- Slot 5: **attention** — highest urgency among workspaces NOT already in 1–4. Urgency borrows
  Commit's `RankToday`: overdue/owed (+), going cold + high-significance (+), stated deadline (+).
  Score floor: if nothing clears the bar, slot 5 drops (4 cards, no padding). If the top urgency
  item is already in 1–4, promote the next.

**Per card (live state).** what moved (recent reflections), what's owed (open commitments on the
theme's contacts), the open question (theme's open_questions), live threads. A **reason string**
("you messaged them 20m ago", "no activity in 8 days").

**Coaching.** Anchored: one coaching line on the workspace it's about, shown when the card is
expanded. Standing: one cross-cutting coaching card below Needs You. Reads do → confront → reflect.

**CRUD.** Card verbs (snooze/not-now). Quick-capture (note/task/decision) into the open workspace.
Quiet `+ new workspace` (manual-tagged, secondary to Explore).

**Endpoint.** `GET /api/now/workspaces?passcode=` → `{ recent: [4], attention: {…}|null,
standing_coaching: {…}|null }`, each workspace `{ id, theme, reason, temperature, moved[], owed[],
question, threads[], coaching }`.

**Honesty caveats (scope carefully):**
- "decision waiting" state may not exist per-workspace yet — derive from open_questions/decisions or omit.
- Now actions that reach WhatsApp ("Reply") — if read-only, label "Open in WhatsApp".

## Model — walkable

Mostly frontend on existing `/api/self-model/browse` + a new detail endpoint.

- **Browse (default, no query):** four entry counts (256/1142/48/566), the 45-review CTA, recently changed.
- **Search:** unified across types; filter chips carry match counts; results grouped + badged with a
  **connection count** per row (aspirations read "nothing backs this yet").
- **Detail (walkable):** open any item → statement + edges as clickable links. Belief → crystallised-from
  theme(s), grounded-in decisions/lenses. Decision → decided-in workspace, from source, grounds beliefs.
  Workspace → decisions/beliefs produced. Source → decisions from it. Every edge navigates.
- **New endpoint.** `GET /api/self-model/facet?id=` → `{ facet, edges: { from[], grounds_by[], in,
  src, grounds[], produced[], beliefs[], from_decisions[] } }` resolved to `{id,kind,statement}`.
- **CRUD in detail:** rename / dismiss-or-delete by origin; aspiration → Find evidence (graduation).

## You — reskin only

Keep every register and behaviour. Apply palette. Wire "all N →" and Explore to open Model
filtered to that kind (the handoff the separate surfaces lacked).

## Settings — health + collapse

Health line up top (`13 running · 0 failing · last sync 4m · Run all now`). Cadences grouped by
frequency (Daily/Weekly/Recurring) and collapsed, each with next-run; Run buttons inside. Data &
capture folded. Memory tab → pointer into You.

## Build order (each: golden-path deploy + verify before next)

1. **Palette** — token swap, visual verify light+dark, mobile.  ← lowest risk, transforms everything
2. **Now** — backend ranking endpoint, then cards. Verify ranking against real reflection timestamps.
3. **Model** — detail endpoint + walkable UI. Verify a real graph walk (belief→decision→source).
4. **You reskin + Model handoff + Settings** — mostly frontend.

Flag-gated behind `features.self_model` throughout; app stays shippable at every step.
