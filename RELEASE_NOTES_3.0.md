# Coach Alfred 3.0 — The Self-Model

Alfred stops being a to-do assistant and becomes a companion that builds a **durable model of how you operate** — and reflects it back across three surfaces: **Now**, **You**, and **Model**. This is the largest release since the project began: a new shape, a new visual identity, and a self-model that learns what you're working on, what you've decided, and what you've come to believe.

---

## Three surfaces

**Now — what you're actually working on.** Four workspaces you're most recently in, plus one that needs you, ranked by *your* engagement (opens, captures, snoozes decay over time) rather than raw recency. Quick-capture a note, task, or decision straight into a workspace; start a new one; jump to the full list.

**You — how you operate, as Alfred understands it.** Your workspaces, the beliefs you hold (with the trajectory of how each one moved, `was → now`), your declared values, the lenses you reason through, and the questions you're sitting with. Every item is tagged by provenance — `declared` (you said it), `observed` (inferred from behaviour), `emergent` (crystallised across your reflections) — so you always know how much Alfred is inferring.

**Model — walk your whole model.** A browsable, walkable graph of every theme, decision, and belief, with the edges between them as links you follow. Search it, filter it, and edit any artifact in place.

## A considered new identity

A full redesign with a **new white / blue / silver colour scheme** — calmer, more deliberate, and consistent across phone, tablet, and desktop.

## Workspaces as first-class objects

- Themes **earn** workspace status when they recur, you act in them, and they produce decisions or beliefs.
- A unified **⋮ menu** on every workspace card, identical across Now, You, and Model: **Rename**, **Merge into…**, make a **topic / workspace**, and **Mark done**.
- **Best-fit attribution** — a workspace only shows the shifts, decisions, and questions that genuinely belong to it, instead of everything from every meeting that merely touched the subject.
- **Theme convergence** — Alfred clusters fragmented themes back into their true workspace (seven "CCBP" angles become one CCBP workspace), so importance stops being diluted across fragments.

## Decisions and beliefs

- **Decisions** are a first-class node — dated records of judgement, extracted from your reflections.
- **Beliefs graduate** from the decisions that support them, and carry their full trajectory so you can see how your thinking evolved.
- An **edit-artifact loop** — remove, move, or give feedback on anything in the model; every edit teaches Alfred.

## A portable operating model

Export a **curated, abstracted "how I operate"** as Markdown that any AI can pick up and run with — values, beliefs with their evolution, how you decide, how to work with you. It ships as a package:

- `<You>_operating_model.md` — the durable manual
- `<You>_sounding_board.md` — a "What would you think?" persona + setup guide, so a colleague can load it into a Claude Project or custom GPT and pressure-test something before it reaches you
- `<You>_current.md` — a snapshot of active workspaces and open questions

…and it mirrors to a Notion page.

## Under the hood

- A durable `self_model.db` that materialises the model deterministically, with the concurrency fixes that keep the You/Model surfaces from stalling.
- Reflection ingestion by **participation** (how much you actually write in a thread), not a hand-kept favourites list.
- Settings cleaned up — a health line, collapsed cadence groups, and a single door to your model.

---

## Install

**Requires Apple Silicon (M1 or later).**

Download `Coach-Alfred-3.0.0.dmg`, drag Alfred to Applications, and launch. On first run, grant **Full Disk Access** (for iMessage) and **Contacts** in System Settings → Privacy & Security when prompted.

## Upgrading from 2.x

In-place upgrade — your configuration and data carry over. The self-model builds itself from your existing reflections on first launch; give it a few minutes to materialise.
