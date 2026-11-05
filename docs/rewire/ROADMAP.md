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
- [ ] `app.html`: four tabs, add, You menu, now with up next / pin / top 3, zen tokens
- [ ] responsive: phone, tablet, desktop
- [ ] old desk reachable from the You menu

## phase 3, fronts and people
- [ ] new front bar (own it, outcome + date, moved in 14 days, other people), proposals, cap 10
- [ ] migration review: keep up to 10, rest become topics
- [ ] front and person pages on real data

## phase 4, coaching and channels
- [ ] coach triggers (5), 1 on screen, 2 a day, 7-day dismiss memory
- [ ] morning email = moment line + top 3; 15:00 email off; one Sunday weekly review
- [ ] push opens now; before-meeting push opens prep
- [ ] WhatsApp self-chat: `todo …`, `done …`, `now`
- [ ] macOS banners off by default (failures only)
