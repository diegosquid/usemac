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
