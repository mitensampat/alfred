# rewire plan

branch: `claude/great-mayer-9tdjbs`. each phase lands as its own commits.

## phase 1, the to-do spine
- [x] `TodoStore`: one store for every to-do (sqlite at `~/.alfred/todos.db`)
- [x] ingest: commitments (you owe → suggested; first run imports the current desk as open), WhatsApp self-notes → suggested, Notion tasks (one-time import), + captures, front decisions
- [x] dedupe by normalised title + person; sources linked
- [x] suggested tray: extracted items wait for accept
- [x] two-way sync with a new Notion mirror database
- [x] `/api/v2/*` endpoints (now, todos, fronts, people, agenda, coach, status)
- [x] trust fixes: WhatsApp "connected" while not receiving, friday promise, keep → model says saved when refused, prototype page served without auth, stuck tab highlight

## phase 2, the new frame
- [x] `app.html`: four tabs, add, You menu, now with up next / pin / top 3, zen tokens
- [x] responsive: phone, tablet, desktop
- [x] old desk reachable from the You menu (`/` now opens the new app; `/home.html` is the old desk)

## phase 3, fronts and people
- [x] new front bar (own it, outcome + date, moved in 14 days, other people), proposals, cap 10
- [x] migration review: keep up to 10, rest become topics
- [x] front and person pages on real data

## phase 4, coaching and channels
- [x] coach triggers (5), 1 on screen, 2 a day, 7-day dismiss memory
- [ ] morning email = moment line + top 3; 15:00 email off; one Sunday weekly review
- [ ] push opens now; before-meeting push opens prep
- [ ] WhatsApp self-chat: `todo …`, `done …`, `now`
- [ ] macOS banners off by default (failures only)
