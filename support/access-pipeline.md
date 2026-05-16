# Access request pipeline

## Where things live

- **Landing form**: `landing/index.html` → posts to Formspree
  endpoint `https://formspree.io/f/mjglvnja` (email + role/problem/
  timing chips, single combined POST).
- **Tracking DB**: Notion "Access Requests"
  - Page: https://www.notion.so/4880e536a8484707a37e1d7e2316b037
  - Data source ID: `2a33f021-3656-4c62-a60f-0a25141dcd71`
  - Under: Coach Alfred → Alfred — First 50 Users Launch Plan

## Schema (one row per requester)

| Property | Type | Notes |
|---|---|---|
| Name | title | requester name, or email if unknown |
| Email | email | |
| State | select | Requested → DMG Sent → Installed → Active → Churned / Declined |
| Role | select | founder / operator / IC / investor / other (chip) |
| Problem | select | dropped commitments / scattered focus / too many meetings / thinking partner (chip) |
| Timing | select | today / this week / just curious (chip) |
| Platform | select | macOS / Windows / Linux / Unknown |
| Requested At | date | |
| DMG Sent At | date | set when you send the install template |
| Source | select | Formspree / Direct / Referral |
| Notes | text | freeform |
| Req ID | auto id | REQ-1, REQ-2, … |

## Wiring Formspree → Notion (3 options)

**Now (manual, fine for first ~20):** Formspree emails you each
submission. Create a Notion row by hand, State = Requested. ~30 sec.

**Soon (no-code):** Formspree (paid) supports webhooks. Point it at
a Zapier/Make scenario: "new Formspree submission → create Notion
page in data source `2a33f021-3656-4c62-a60f-0a25141dcd71`". Map
email→Email, chips→Role/Problem/Timing, State="Requested",
Source="Formspree", Requested At=now.

**Later (Paperclip):** the agent owns this loop end to end —
reads the Notion row, picks the right template from
`support/templates/`, sends the install email, flips State to
"DMG Sent" and stamps DMG Sent At. The structured DB + the
templates are exactly the substrate it needs.

## State transitions (who/when)

- **Requested** — row created (form submission)
- **DMG Sent** — you replied with `templates/install.md` + stamped DMG Sent At
- **Installed** — they confirmed install / sent a diagnostic report
- **Active** — using it past the 7-day check-in
- **Churned** — no reply to 7-day check-in + no usage signal
- **Declined** — not a fit, or not on macOS (`templates/not-mac.md`)
