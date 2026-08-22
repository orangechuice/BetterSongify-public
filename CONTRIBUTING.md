# Contributing

## This repository is a mirror

Development happens in a private working repo that also holds material that is not
publishable. What you see here is an allowlisted export of the parts that make sense
to publish.

The practical consequences:

- **Pull requests are welcome**, but they are applied upstream by hand and arrive back
  here in the next sync. Your change will land; your commit SHA will not.
- **Direct pushes to this repo get overwritten** by the next export. If you have commit
  access, change the upstream, not the mirror.
- Anything referenced from the docs but missing from the tree was left behind on
  purpose, not by accident.

## Good contributions

**Repairs after a Spotify UI change** are the most valuable thing you can send, and
the most likely thing to be broken when you arrive. Spotify ships changes to its
client continuously and does not consider its DOM a public interface, so selectors
rot without warning.

Every selector this project depends on lives in one place — the `SELECTORS` object
near the top of `src/index.js`. If a feature has silently stopped working, that object
is almost always where the fix goes, and keeping new selectors there rather than
inline is the single most useful convention to follow. `install-macos.sh` additionally
assumes `xpui.spa` is a zip with `index.html` at its root; if that changes, the
installer fails loudly rather than silently.

**New settings-panel toggles** follow a fixed shape: add the default to `DEFAULTS`,
render the control in the panel, and gate the behaviour on the stored value so it
survives a reload. Copy an existing toggle — `hideRecommendations` is the smallest
complete example.

**Changes to the macOS companion** live in `tools/notifier-app/main.swift`. Read the
comments before changing the bundle identifier, the login-item registration, or the
menu-bar helper: each of those carries a note explaining what was already tried and
why the current approach is what survived. They are there to save you the dead ends.

The loopback protocol between the injected script and the companion is pinned by
`tools/test-notifier-transport.sh` — the CORS origin allowlist, the error responses,
split writes and stalled deadlines. Treat that test as the specification; if you are
changing the protocol, change the test first.

## Before opening a PR

```sh
npm run check           # syntax-check sources, build both targets, syntax-check output
npm run build:notifier  # macOS only, needs Xcode Command Line Tools
npm run verify:notifier # plist, resources, signature, bundle ID, frameworks
npm run test:notifier   # loopback parser, without Spotify or notifications
```

The first command runs anywhere. The last three need macOS; CI runs all of them, so
send the PR even if you can only run the first.

Match the surrounding style: comments explain *why* something is the way it is, not
what the line does. Where a comment records that an alternative was tried and failed,
keep it — that is the most expensive knowledge in the repo.
