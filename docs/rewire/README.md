# the UX rewire

start here before changing the user interface.

1. `SPEC.md` — what we are building and why.
2. `DECISIONS.md` — every decision made with Miten, newest first. add to it when a new one is made.
3. `MOCK.md` — links to the interactive mock and the spec doc, plus the visual tokens.
4. `ROADMAP.md` — phases and checklist; tick items as they land.

rules: no direction changes without Miten's approval; the interface is `Sources/GUI/Resources/app.html` (first-run setup: `setup.html`); the old desk `home.html` was retired on 2026-11-05.

verifying Swift changes without a Mac: `tools/linux-typecheck/` type-checks the whole package on Linux.
