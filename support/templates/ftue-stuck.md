# Template: FTUE stuck

Sent when a user says they're stuck somewhere in the setup wizard.
Goal: get the diagnostic report, unblock them fast, stay warm.

---

Subject: re: stuck in setup

Hi {{first_name}},

Sorry — let's get you unstuck.

Quickest path: in alfred, open the menu bar icon → Help → "Send
Diagnostic Report". It shows you exactly what it'll send (logs +
which setup step you're on, secrets redacted), then you click to
email it to me. That tells me precisely where it broke.

If you can't get that far, just tell me:
1. Which step? (welcome / API keys / Notion / Google / profile /
   messaging / permissions)
2. What did you see — error text, a blank screen, a button that
   did nothing?
3. A screenshot if it's easy

I'll turn this around fast. This is exactly the kind of thing I
want to hear about while it's still early.

— Miten

---

Notes for me:
- Most common: permissions step. FDA requires fully quitting +
  reopening alfred after granting in System Settings.
- Google OAuth: redirect mismatch usually means clock skew or a
  stale browser session — incognito fixes it.
