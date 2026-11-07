# People tracking — proposal

Revised with your answers: pin is purely a pin, "waiting on them" is a filter inside People, and
any person gets a *rescan last 3 days* action.

---

## What puts a person on the People tab today

`TodoService.people()` — `Sources/Services/TodoService.swift:362`. The short answer: **a person
only exists as a by-product of a to-do.** There is no person record anywhere in Alfred. A "person"
is a distinct string in the `person` column of an open to-do.

1. Alfred takes every open to-do of yours (`openMine()`) and everything you're waiting on
   (`waiting()`), and groups both by the to-do's free-text `person` field.
2. The candidate set is exactly the union of those two groups.
3. Each candidate falls into one of two sections: **going quiet** (silent ≥ 21 days and something
   open), or **waiting on you** (you owe them ≥ 1 thing).

Four consequences:

- **You cannot add anyone deliberately.** There is no `POST` under `/api/v2/people` — only the two
  GETs. Fronts have `/new` and `/activate`; people have nothing.
- **A person with nothing open vanishes**, precisely when things go quiet with them.
- **A hole that silently drops people.** Someone who only owes *you* something and has been in
  touch within 21 days matches neither branch: `silent >= 21` is false, `you_owe > 0` is false.
  Their row is built and thrown away. Your "waiting on them" filter is the fix for this.
- **Identity is the raw string.** "Alex Carter" and "Alex" are two different people here.

---

## 1. Pinning — a pin, and nothing else

You were right to split this from favourites. `FavoritesService` looks like the obvious host for a
star, but that list *is* scan scope — `AlfredService.scanCommitments` resolves `scanMode:
"favorites"` straight into `getFavorites()`. Reusing it would have made pinning someone silently
widen what Alfred scans, which is what you said you didn't want.

So pins get their own file: **`~/.alfred/pinned_people.json`**, an array of names and nothing more.
About thirty lines, loaded like `FavoritesService` is, no schema, no tags, no overlap with scan
scope. I'd rather have the second small file than a `pins` key inside `favorites.json`, because the
whole point is that the next person reading the code can't mistake one for the other.

- A pin toggle on each person card and on the person sheet
- A **Pinned** section at the top of People, always rendered, including people with nothing open
- Settings' "People and groups Alfred watches closely" stays exactly as it is — it means scan
  scope, and now it only means that

## 2. Rescan last 3 days — per person

The capability already exists: `AlfredService.scanCommitments(contactName:lookbackDays:scanMode:)`
with `scanMode: "contact"` scans exactly one person. Results land in `CommitmentScanTracker`, and
`TodoService.reconcileCommitments()` — which `people()` already calls on every load — pulls them
into the to-do list. So the button is mostly wiring:

- *Rescan last 3 days* on the person sheet, available for anyone, pinned or not
- New route `POST /api/v2/people/rescan { name, days: 3 }`
- It reports what it found ("2 new suggestions") rather than succeeding silently, and the new items
  arrive in the suggestion tray like any other extraction — nothing is added behind your back

**One thing to fix on the way.** `scanCommitments` opens with
`guard orchestrator.notionServicePublic.tasksDatabaseId != nil else { throw
notionDatabaseNotConfigured }` — a v5 leftover from when commitments were written straight to
Notion. In 6.0.0 the scan writes locally and Notion is a mirror, so as it stands this button would
fail for anyone running without Notion, which is supposed to be a supported setup. The v2 path
should skip that guard.

## 3. Waiting on them — a filter, inside People

Instead of a fourth section, People gets a chip row, filtering one flat list:

**All · Waiting on you · Waiting on them · Going quiet**

This is also why the dropped-people bug disappears: the payload stops pre-sorting rows into two
buckets and discarding the leftovers. `people()` returns every candidate once, each with
`you_owe`, `they_owe`, `silent_days` and `pinned`, and the app decides what to show. Pinned stays
its own section above the chips, so pins are never filtered away.

## 4. Adding a person — it pins them

You were indifferent, so: **adding pins.** If you add someone by hand from the People tab they have
no to-dos yet, so without a pin they'd be filed under a filter you aren't looking at and the tab
would appear not to have changed. Adding them and having them show up is the honest behaviour. The
pin toggle is right there on the card if you want them unpinned.

- *Add person* next to the People heading — name plus optional alias, the same two fields Settings
  already uses
- `POST /api/v2/people/track`, which writes the pin
- The person sheet also gets *Add a to-do*, opening the existing add sheet with the person
  pre-filled. UI only — `POST /api/v2/todos` already takes `person`.

---

## The build

**Server**
1. `PinnedPeopleStore` — `~/.alfred/pinned_people.json`, load/add/remove/contains
2. `TodoService.people()` returns one flat list: every candidate once, union'd with the pins, each
   row carrying `you_owe`, `they_owe`, `silent_days`, `pinned`
3. Routes: `POST /api/v2/people/track`, `/api/v2/people/pin`, `/api/v2/people/unpin`,
   `/api/v2/people/rescan`
4. Drop the Notion guard from the v2 rescan path

**App** (`app.html`)
5. *Add person* in the People header
6. Pin toggle on `personCard()` and in `sheetPerson()`
7. Chip row — All / Waiting on you / Waiting on them / Going quiet — filtering client-side
8. Pinned section above the chips, with an empty state: "Pin someone to keep them here."
9. *Rescan last 3 days* and *Add a to-do* on the person sheet

**Not in scope**
- Merging "Alex" and "Alex Carter" into one identity. It's real — it's why the tab can show the
  same human twice — but it needs an identity decision of its own and shouldn't ride along.
- Per-person cadences or scan rules. Pinning stays a pin.

Rough size: 1–4 is around 100 lines across `TodoService`, the new store and the routes; 5–9 is
`app.html`. One sitting, plus the Golden Path deploy and the mobile check at 393×852 and
1024×1366.
