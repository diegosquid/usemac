# Security policy

UseMac lets AI agents control a Mac and its Chrome tabs, so security problems in it can reach everything the user
can reach. Please report them privately.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: open the repository's **Security** tab and click
**Report a vulnerability**, or go to <https://github.com/diegosquid/usemac/security/advisories/new>.

Don't open a public issue, a pull request or a discussion about it before a fix is released.

Include:

- the UseMac version (and the extension version, for browser problems), macOS version and Chrome version;
- what an attacker can do and what they need first (for example: a web page the user opens, another app running as
  the same user, an agent the user connected);
- steps to reproduce, or a proof of concept.

## What to expect

- An acknowledgement within 7 days.
- An assessment and a plan for a fix, shared with you in the advisory.
- Credit in the advisory and the changelog when the fix ships, unless you'd rather not be named.

## Supported versions

Fixes go into the latest stable release and the latest beta. Older versions don't get fixes; update with
**Check for Updates…** in UseMac's menu bar menu.

## Saved safety settings

UseMac saves the execution mode, the mode Resume goes back to, the Emergency stop and Debug capture in its
preferences (`app.usemac`), which any process running as you can edit. So UseMac seals them: an HMAC-SHA256 over
the four values, with a 32-byte key in your login Keychain (the item `app.usemac.safety-seal`). UseMac created the
item, so other apps, the `security` tool included, can't read the key unless you allow it in a macOS prompt. Every
change UseMac saves gets a new seal, and a count in the Keychain item goes up, so an older copy of the settings and
its seal doesn't match either.

At launch:

- **The seal matches:** UseMac uses the saved settings.
- **The settings were changed outside UseMac,** or the seal, the Keychain item or the marker that sealing is on is
  missing, or the Keychain can't be read: UseMac starts **Paused** with Debug capture off. The Emergency stop stays
  on if it was saved on. UseMac records it in History and says so in the menu bar menu and **Settings → Safety**.
  Only you resume, and Resume goes back to the saved mode, so check it first.
- **No seal and no Keychain item** (a new install, or the first launch of a version that seals): UseMac seals the
  saved settings, with Debug capture off.

Known limits:

- Deleting both the marker in the preferences and the Keychain item looks like a new install, so the saved mode and
  Emergency stop are used again (Debug capture still starts off). The Keychain stops other apps from reading the
  key, but may not stop them from deleting the item.
- Putting back older copies of both the preferences and the whole login keychain brings back the older settings.
- If macOS asks whether another app may use `app.usemac.safety-seal`, deny it unless you started that yourself.

## Scope

In scope, for example:

- getting past a limit UseMac sets, such as the execution mode, the Kill Switch, Ask approvals or app and site
  rules, including from an agent or another process running as the same user;
- an agent relaxing the execution mode or changing app and site rules without the user;
- another macOS user reaching the Unix socket;
- a web page, another extension or another process talking to the Chrome bridge without being paired;
- typed text, `eval` sources or secrets showing up unredacted in the audit log or its exports;
- anything that lets someone other than the maintainer ship an update to installed apps.

Out of scope:

- an agent the user connected doing what the user's execution mode allows;
- things an attacker running code as the user could already do without UseMac;
- problems in Chrome, macOS or an AI agent host that UseMac doesn't make worse.
