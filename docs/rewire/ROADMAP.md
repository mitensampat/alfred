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
- [x] `/` opens the new app

## phase 3, fronts and people
- [x] new front bar (own it, outcome + date, moved in 14 days, other people), proposals, cap 10
- [x] migration review: keep up to 10, rest become topics
- [x] front and person pages on real data

## phase 4, coaching and channels
- [x] coach triggers (5), 1 on screen, 2 a day, 7-day dismiss memory
- [x] morning email = day shape + pinned + top 3 + one coach line; 15:00 attention email off (it sent even with its flag off); Thursday digest email off, so the Sunday review is the one weekly email
- [x] morning push leads with the first to-do and opens now; new push 10 minutes before a meeting opens its prep; evening push opens now; the post-meeting capture push still opens the old desk, where capture lives
- [x] WhatsApp self-chat: `todo …`, `done …`, `now`
- [x] macOS banners off by default (failures only)

## still to do (needs the owner's go-ahead or a Mac)

- [ ] verify on the Mac: `swift build`, then use the new app for a week (this branch was type-checked on Linux, not built or run)
- [x] retire the old desk: settings (basic, with advanced and diagnostics folded away), your model, coach notes, archive, weekly review, conversations, live scheduling, closure confirmations and first-run setup moved into the new app; `home.html` removed
- [x] post-meeting capture: the capture sheet is in the new app; follow-ups are split by the model and land in the suggested tray
- [x] learn from dismissed suggestions and tag corrections (TodoLearning: front and person corrections, hiding what you keep dismissing, tray order, extractor corrections)
