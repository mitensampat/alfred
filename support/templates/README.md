# Support reply templates

Hand-written templates for onboarding and supporting early users.

**Today:** copy-paste these into email replies, fill the `{{first_name}}`
and any chip-profile personalization, send from your own inbox.

**Later (Paperclip, ~30+ users):** these become the canonical source an
agent uses verbatim for the 80% of replies that are routine. Keep them
in the voice you'd actually send — the agent inherits the voice from
the file, so the file *is* the brand.

| File | When to send |
|------|--------------|
| `install.md` | Inviting a Formspree request in — the main one |
| `ftue-stuck.md` | User reports being stuck in the setup wizard |
| `permission-help.md` | Blocked on macOS FDA / Contacts / Notifications |
| `not-mac.md` | Requester is on Windows/Linux — capture for later |
| `checkin-7day.md` | Proactive ~7 days post-install — surfaces silent churn |

## Rules

- Keep them short. Serif energy. Signed "— Miten".
- Personalize line one. A templated reply that *feels* templated
  breaks the "a coach for A players" promise.
- Every "it said something wrong" reply is a product bug — chase it.
- Update these files as you learn what actually works. The file is
  the source of truth, not your memory of what you usually say.
