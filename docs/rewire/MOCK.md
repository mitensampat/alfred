# the mock

1. **interactive mock (phone, iPad Pro 13 landscape, desktop web, side by side):** https://claude.ai/artifact/MrQPQmP35ifmUMZXhMrdU5
2. **spec doc (discussion copy):** https://claude.ai/artifact/H6XRon6eyFQmMK2PPFwkoc
3. the shipped implementation is `Sources/GUI/Resources/app.html`; when the mock and the code disagree, the code follows the mock unless DECISIONS.md says otherwise.

## screens

1. **now:** Alfred's "up next" card (or "pinned by you"), "top of your list" (3 raised cards: who · front, why now, the to-do, primary action, not now, pin, open), "N more today" (folded on phone, open on wide), one "Alfred noticed" coach line when a trigger fires.
2. **to-dos:** filter chips (all, a front, a person), suggested tray (dashed cards, accept / dismiss), today, upcoming, someday as compact cards with a round check.
3. **fronts:** "make this a front?" proposal card (dashed), front cards (badge, name, date, pulse, next line, footer: to-dos, people, last activity).
4. **people:** waiting on you, going quiet; person cards (initials, name, age, oldest owed item, footer: you owe N, waiting on M).
5. **details:** front (pulse, outcome and date, the one decision, next to-dos, who is in it, what happened) and person (you owe, waiting on them with nudge, fronts together, schedule).
6. **add:** one box; Alfred's tags (front, person, due); add to-do or ask Alfred.
7. **You menu:** status card when something is broken, weekly review, coach notes, conversations, model, You-Wiki, archive, connections, settings.

## layout

1. **phone (390 wide):** bottom tab bar, floating + button, bottom sheets.
2. **iPad Pro / desktop:** left rail (wordmark, tabs, Add, you), centre column, right column (today's agenda, fronts at a glance); front and person details open in the right column; add and You open as a centred dialog.

## visual tokens

paper `#F7F5F0`, ink `#1F1E1B`, quiet `#6B675F`, hairline `#E4DFD5`, card border `#E6E1D7`, warm dot `#C9823F`, warm text `#9A5A22`, accent sage `#4E6B5A`. type: Newsreader (headings, moment line), Inter (UI). cards: white, 18px radius, `0 1px 1px rgba(31,30,27,.04), 0 4px 14px rgba(31,30,27,.06)`.
