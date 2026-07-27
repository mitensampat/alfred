# Coach Alfred 3.1.0 — Signal, without Full Disk Access

The headline: **Signal is now a message source that needs no Full Disk Access.**

Alfred learns the most from your conversations, but reading them has meant granting Full Disk Access — a heavy, all-or-nothing macOS permission. Signal is different. Its database lives outside the protected system locations, so Alfred can read it with **just a one-time Keychain grant instead of Full Disk Access**.

## How it works

Signal's database is encrypted (SQLCipher), with its key protected by your macOS Keychain. Alfred derives that key locally, decrypts a temporary copy on your Mac, reads it, and cleans up — all on-device, nothing leaves your machine. The decryption runs in a small, isolated, notarized helper so the rest of Alfred stays exactly as it was.

During setup, connecting Signal shows a single Keychain prompt (**"Always Allow"**); after that, Alfred reads Signal silently, including its nightly pass.

## What this means for you

- **Privacy-first, permission-light.** For a Signal user, Alfred can build its full picture of what you're working on without ever asking for Full Disk Access.
- **WhatsApp is still supported** (it needs Full Disk Access, as before) — Signal is the lighter-touch alternative.

## Install

**Requires Apple Silicon (M1 or later).**

Download `Coach-Alfred-3.1.0.dmg`, drag Alfred to Applications, and launch. In setup, toggle on **Signal Desktop** and click **Grant access & verify** — you'll get one Keychain prompt to Always Allow.

## Upgrading from 3.0.x

In-place upgrade — configuration and data carry over.
