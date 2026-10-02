# Merry

A small lamb that lives on your Mac's desktop and does real work for you:
finds, organizes and renames files, reads documents, runs your Mac's apps,
browses the web in its own window, and remembers what you tell it.

Native Swift, SwiftUI and AppKit. One process, about 35 MB at rest.

## Building

Needs an Apple silicon Mac on macOS 26 and Apple's Command Line Tools
(`xcode-select --install`). Xcode is not required.

    scripts/build-app.sh --install

builds `Merry.app`, copies it to Applications and opens it. Press ⌘⇧Space, or
click Merry's face in the menu bar.

Merry keeps its data in `~/Library/Application Support/merry` and its API keys
in the Keychain.

## How it works

- **A task loop**: understand the request, look at the Mac, propose a step,
  check it against what you allowed, run it, verify.
- **Tools** for files, search, documents, the command line (a strict
  allowlist; see `Sources/MerryCore/Tools/ShellTools.swift`), Mac apps, the
  desktop and the web.
- **A planning model** of your choice: the Anthropic API, or Claude Code,
  Codex or OpenCode if you have them installed. Common jobs run as fixed
  workflows with no model at all.
- **Undo** for everything it moves or renames.

## Tests

    scripts/test.sh

## Licence

MIT. Third-party notices are in `THIRD_PARTY_NOTICES`.
