# Coach Alfred 3.0.1

A focused follow-up to 3.0. Your workspaces now understand **importance**, and they stop fragmenting as new activity comes in.

## Frequency → importance

How often a subject comes up is a direct signal of how much it matters. Alfred now measures each workspace's **recency-weighted recurrence** (recent conversations weigh more) across **distinct sources** (so one busy thread can't fake importance), and uses it to:

- **Rank the You register** by importance — the workspaces you keep returning to lead the list.
- **Earn the Now attention slot** — a workspace you engage with often surfaces when it goes quiet, even before it has produced many decisions.
- **Promote** a subject to a workspace once it genuinely recurs, not only once it has produced a set number of decisions.

Each workspace now shows a **"⚆ N conversations"** signal in the Model browser, so you can see why something ranks where it does.

## Workspaces stop re-fragmenting

Previously a new metric, week, or angle of an existing subject could spawn a near-duplicate workspace. Now, when Alfred reads new activity, it's told which workspaces are already established and instructed to **attach an update to the existing workspace** rather than mint a variant — so a subject stays one workspace as it evolves.

## Install

**Requires Apple Silicon (M1 or later).**

Download `Coach-Alfred-3.0.1.dmg`, drag Alfred to Applications, and launch. On first run, grant **Full Disk Access** (for iMessage) and **Contacts** in System Settings → Privacy & Security when prompted.

## Upgrading from 3.0.0

In-place upgrade — configuration and data carry over. The new importance ranking applies on the next model refresh.
