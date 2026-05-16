# Template: Permission help (FDA / Contacts / Notifications)

Sent when a user is blocked on the macOS permission prompts.

---

Subject: re: permissions

Hi {{first_name}},

This trips everyone up once — macOS makes it deliberately fiddly.

Full Disk Access (the important one — it's how alfred reads your
Messages, all locally):
1. System Settings → Privacy & Security → Full Disk Access
2. Toggle Alfred ON (if it's not listed, click + and add
   /Applications/Alfred.app)
3. CRITICAL: fully quit alfred (menu bar icon → Quit) and reopen
   it. macOS only applies the grant on a fresh launch.

Contacts & Notifications: alfred will prompt for these on first
use — just click Allow. If you missed the prompt, same path in
System Settings → Privacy & Security → Contacts / Notifications.

Nothing leaves your Mac because of these grants — they only let
alfred read locally. There's a short "on privacy" note on the
site if you want the full picture.

Still stuck after the quit-and-reopen? Send a diagnostic report
(menu bar → Help) and I'll look.

— Miten
