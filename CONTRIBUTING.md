# Contributing to UseMac

Thanks for helping. This file covers how to propose a change and what a pull request needs. How decisions are made
and how changes are reviewed is in [GOVERNANCE.md](GOVERNANCE.md).

Found a security problem? Don't open an issue. Follow [SECURITY.md](SECURITY.md).

## Before you start

- **Small fixes** (a typo, a broken link, a bug with an obvious one-line fix): open a pull request directly.
- **Anything bigger**: open an issue first and wait for the maintainer to agree on the approach. A pull request
  without an accepted issue may be closed without a full review.
- **Check the assignee.** An issue with an assignee is taken, often by the maintainer's AI agents. Issues labeled
  `help wanted` or `good first issue` are open to you.

## Set up

You need macOS 15 or later on Apple Silicon, Xcode 26.2 (the version CI and releases use) and Node.js 22.

```bash
# Build all Swift targets
swift build

# Run Swift tests
swift test

# Run Chrome extension tests
node --test Tests/ExtensionTests/*.test.mjs

# Build and sign a local .app bundle under dist/
./scripts/bundle-app.sh
```

Running the app needs Accessibility and Screen Recording permission. To try extension changes, load `Extension/`
unpacked in `chrome://extensions`, preferably in a Chrome profile you use only for testing.

## Making a change

- Branch from `main` and keep each pull request to one change.
- Add or update tests. Swift tests live in `Tests/UseMacTests`, extension tests in `Tests/ExtensionTests`.
- If agents see the change (a method, a parameter, an error code, a CLI command), update `README.md`,
  `.agents/AGENTS.md` and `.agents/skills/usemac/SKILL.md` to match.
- If users or agents would notice the change, add a line under `[Unreleased]` in `CHANGELOG.md`, in the same style
  as the entries already there.
- Fill in the pull request template. CI must pass.

## Safety-critical changes

Some paths decide what every user's app downloads, what every user's agents are told, and which limits agents
can't cross. They are listed in [`.github/CODEOWNERS`](.github/CODEOWNERS), and the reasons are in
[GOVERNANCE.md](GOVERNANCE.md#how-changes-are-reviewed). If your pull request touches one:

- Expect a slower, line-by-line review.
- Say in the pull request which limit or check the change affects, and why it stays safe.
- Don't loosen a default or a limit as a side effect. For example, agents can only tighten the execution mode,
  and app and site rules can only be changed in the app. A change to that needs its own issue.

## AI-assisted contributions

Using AI tools is fine. You are responsible for what you submit.

- Say in the pull request which tools you used and for what.
- Read the whole diff yourself and run the tests before you open the pull request.
- Pull requests that look generated and unreviewed, or that don't match an accepted issue, may be closed without
  review.

## Sign-off and license

UseMac is released under the [MIT License](LICENSE), and contributions are accepted under the same license.

Sign off each commit to certify the [Developer Certificate of Origin](https://developercertificate.org/), which
says you wrote the change or have the right to submit it under the project's license:

```bash
git commit -s
```

This adds a `Signed-off-by: Your Name <you@example.com>` line to the commit message.

## Code of conduct

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
