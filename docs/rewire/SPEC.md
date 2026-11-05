# Alfred — UX rewire spec

as of 2026-11-05. the discussion copy lives at https://claude.ai/artifact/H6XRon6eyFQmMK2PPFwkoc; this file is the build copy. decisions are logged in `DECISIONS.md`.

## goal and design rules

Alfred becomes the default screen for what matters most now: one to-do list that knows which front each item moves and which person is waiting on it. you open it and within five seconds you know the next thing to do.

1. **one question on open:** "what matters most now?" every other view is one tap away.
2. **at most three things lead.** each says why now, has one primary action and one way to say not now.
3. **the to-do is the unit.** fronts and people are ways of looking at to-dos.
4. **fronts are rare and heavy.** up to 10, each an outcome you own, with a date. Alfred proposes, you confirm.
5. **coaching speaks only when it is earned.** silence is the default.
6. **one way to add anything:** a to-do, a thought, a question or a schedule request.
7. **status only when something is wrong.**
8. **zen by default:** warm paper, one sage accent, plain words.
9. **every channel points home:** email, push and WhatsApp lead back to now.

## the model: three objects

| object | what it is | how many |
| --- | --- | --- |
| to-do | one thing to do, with an owner and an optional due date | unlimited |
| front | an outcome you own, with stakes and a date | up to 10 active |
| person | someone you work with, and everything open between you | everyone with something open |

1. to-dos you own are the main list.
2. to-dos others owe you ("waiting on") appear only inside their front or person.
3. topics are tags for themes below the front bar; no screen of their own.
4. the self-model (beliefs, patterns, You-Wiki) stays as the engine; reachable from the You menu.

## navigation

| tab | answers | opens on |
| --- | --- | --- |
| now | what matters most right now? | up next, then the top 3, then today |
| to-dos | what is on my list? | suggested, today, upcoming, someday |
| fronts | what am I running, and is it moving? | active fronts, stalled first |
| people | who do I owe, and who is going quiet? | waiting on you, longest first |

1. **add:** one + button (phone: floating; wide: "Add" in the rail).
2. **You menu:** your initial (phone: top left; wide: bottom of the rail). holds weekly review, coach notes, conversations, model, You-Wiki, archive, connections, settings, the full desk (until phase 4).
3. **status dot:** a warm dot on your initial only when a connection or sync needs you.
4. **wide layouts:** left rail, centre column, right column (today's agenda, fronts at a glance). details open in the right column.

## now tab

1. **up next card (Alfred's):** one sentence for this moment (morning: shape of the day; within 60 minutes of a meeting: prep; evening: what tomorrow needs tonight), signed by Alfred, one action.
2. **pinned by you:** pinning any to-do replaces the up next card until unpinned or done.
3. **top of your list:** three raised cards. ranking:

| signal | weight |
| --- | --- |
| you pinned it | always first (takes the up next slot) |
| meeting today with the person or front | high |
| it is the open decision on an active front | high |
| due today or overdue | high |
| someone has waited 7+ days | medium |
| it belongs to an active front | medium |
| you skipped it before | lowers it |

4. **N more today:** folded on phone.
5. **coach line:** at most one, only when a trigger fires.
6. **rules:** never more than 3; done shows a receipt with undo; no debt counts on this screen.

## to-dos and the to-do system

1. sections: suggested, today, upcoming, someday. filter: all, a front, a person.
2. sources: commitments you owe (from messages), WhatsApp to-do scan, Notion tasks and Alfred tasks (one-time import), + captures, the open decision on a front.
3. **extracted to-dos always wait in the suggested tray** until you accept them. accept, edit, dismiss; dismissals teach the extractor.
4. no duplicates: the same promise from several sources becomes one to-do with all sources linked.
5. auto-tagging of front and person; corrections are kept.
6. the 30-day rule stays.
7. **Notion sync:** a new mirror database (title, status, due, front, person, source, alfred id). Alfred → Notion on every change; Notion → Alfred every 5 minutes; most recent edit wins, the loser is kept in history; to-dos created in Notion appear in Alfred.

## fronts

1. **the bar:** you own it (or pinned it), it has an outcome and a **date** (or an explicit "no fixed date"), it moved in the last 14 days, it involves other people.
2. proposals arrive as one card on the fronts tab: make it a front, or keep as a topic.
3. **cap:** 10 active; an 11th asks which to close or pause.
4. **anatomy:** outcome and date, the one decision, next 3 to-dos, who is in it (you owe / waiting on), pulse (moving / stalled: no to-do done in 7 days or none exists), what happened.
5. **migration:** one review of today's fronts ranked by the new bar; keep up to 10, the rest become topics.

## people

1. sections: waiting on you, going quiet (silent 3+ weeks with something open). people with nothing open are not listed.
2. person page: you owe, waiting on them (nudge drafts a message), fronts together, next meeting with prep, schedule.
3. reliability shows only on the person page, and only with 5+ completed items.

## coaching

| trigger | action |
| --- | --- |
| a front is stalled and nothing on your list moves it | add the next step |
| small to-dos cleared while a front's decision ages | block an hour |
| tomorrow is heavy and something must happen tonight | do it now |
| someone important is going quiet while you owe them | draft a message |
| a self-model pattern repeats (weekly at most) | protect the slot |

rules: one line on now at a time, two a day, below the top 3, dismissals remembered for 7 days, every line cites its numbers. everything else rolls into one Sunday weekly review. skills, lenses and tenets stay in settings → advanced.

## visual language

paper background, white raised cards (post-style: header line, body, action row), one sage accent for primary actions, a warm dot for urgency (no red text), Newsreader for headings, Inter for UI, 44px tap targets, sentence case. tokens in `MOCK.md`.

## channels

| channel | new |
| --- | --- |
| morning email | moment line + top 3, links to now |
| 15:00 attention email | off |
| weekly emails | one Sunday weekly review |
| push: morning | "3 things today. first: …", opens now |
| push: before a meeting | 10 minutes before, opens prep |
| push: after a meeting | capture goes into the suggested tray |
| push: evening | kept, as a coach trigger |
| WhatsApp self-chat | adds `todo …`, `done …`, `now` |
| macOS banners | off by default; failures only |

## what moves or goes away

the desk's top cards and list → now and fronts; side column → people (going quiet), fronts (pulse), weekly review; coach tab → coach line + weekly review; model and You → one screen in the You menu; You-Wiki → linked from the You menu; ask bar and + palette → one add; header pills → the status dot; two ways to close a front → one, with undo; two chase buttons → one nudge; settings → basic and advanced; debug views → diagnostics page; orphaned screens and the unauthenticated prototype page → removed.

vocabulary: front (the ≤10), topic (the rest). no facet, durability, strays or cadence in the UI.
