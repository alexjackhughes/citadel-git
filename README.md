<p align="center">
  <img src="Assets/Citadel-lighthouse.png" alt="Citadel lighthouse icon" width="160">
</p>

# Citadel Git

**A free, open-source Git UI for macOS, licensed under MIT.**

Citadel is a native Mac app for browsing Git history, reviewing changes, staging files, and making commits. It uses SwiftUI, AppKit, and the Git installed on your Mac. No browser, hosted backend, database, account, subscription, or third-party package dependencies are required.

Originally built as a personal Git workbench, Citadel is now open source for anyone to use, improve, and share. The name is a nod to Tower; this is an independent project with its own implementation and artwork.

## What it does

- Add existing local repositories, initialize a new one, or clone HTTPS, SSH, and local sources using your existing Git authentication.
- Create stashes (optionally including untracked files), inspect their files and diffs, apply/pop them, and explicitly delete them. Conflicted applications preserve the stash.
- Browse a commit timeline with author details, messages, references, and changed files.
- Click a branch to browse its history without checking it out. Right-click to check out a branch, or create one from the current HEAD.
- Review working-copy changes in a compact file list with staging checkboxes and separate Staged / Unstaged diff views.
- Read unified diffs with line numbers, change counts, and red/green highlights.
- Stage or unstage individual files, a selection, or all changes; commit staged contents with a subject.
- Fetch, push, and pull with fast-forward-only behavior when a repository has remotes.
- Use native controls, keyboard shortcuts, resizable panes, and automatic light/dark appearance.

`main` stays at the top of the branch list. Other branches sort by creation time when Git retains their creation reflog entry, falling back to the tip commit date when that information is unavailable.

## Build and run

You need **macOS 14 or later**, an active Swift toolchain compatible with Swift 5.9 or later (Xcode or Command Line Tools), and `/usr/bin/git`. The build also uses macOS AppKit and `codesign`. Development has been tested on Apple Silicon; other configurations may need additional testing.

```sh
git clone https://github.com/alexjackhughes/citadel-git.git
cd citadel-git
./scripts/build-app.sh
open build/Citadel.app
```

The script builds the release executable, generates icon sizes from the source artwork, assembles `build/Citadel.app`, and applies a local ad-hoc signature. The resulting app is self-contained and can be moved to Applications. This source-build workflow does not produce a notarized installer.

You can also double-click `Launch Citadel.command`; it builds the app if the bundle does not exist yet. After changing source code, rerun the build script and reopen the app. Open `Package.swift` in Xcode for development.

## Everyday workflow

1. Press **⌘O** and choose an existing Git repository folder.
2. Choose **Working Copy** to see changes, or **History** to explore commits.
3. Select files and use their checkboxes or **Space** to stage changes.
4. Press **Tab** from the file list to focus the commit subject, type a subject, then press **Return**.

Only staged contents are committed. Selecting a file does not stage it. A partially staged file shows a minus checkbox; staging it includes its remaining changes. Git author configuration, hooks, and signing settings remain in effect.

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘O | Add a repository |
| ⌘1 / ⌘2 | Show History / Working Copy |
| ↑ / ↓ in the file list | Navigate files |
| ⌘A in the file list | Select all files |
| ⇧click / ⌘click | Select a range / toggle individual selections |
| Space in the file list | Stage selected files, or unstage them if fully staged |
| Tab from the file list | Focus the commit subject |
| Tab / ⇧Tab from the subject | Return to the file list |
| Return in the subject | Commit staged changes when a subject is present |
| ⌘Return | Commit staged changes |
| ⇧⌘A | Stage all changed files |
| ⇧⌘B | Create a branch |
| ⌘R | Refresh the repository |
| ⇧⌘R | Reveal the repository in Finder |

In text fields, **⌘A** selects text normally. Use the repository menu to switch repositories or remove one from the workspace; removal does not delete its folder.

## Local data and network behavior

Citadel does not include analytics, telemetry, a hosted service, or its own credential store. Repository paths and the last selected repository are saved in macOS UserDefaults under the original bundle identifier, `local.alex.Citadel`. Commit drafts are held in memory and survive repository switches during that app session, but not an app restart.

Local browsing, diffs, staging, and commits do not require a network connection. Fetch, Pull, and Push use your configured Git remotes and authentication. Git hooks, credential helpers, and other Git configuration can run external programs and may access the network. Interactive authentication or signing may require setup in a terminal first.

Build artifacts, local settings, credentials, and development screenshots are excluded from version control. Screenshots of real repositories can expose private code, paths, and author details; use a disposable demo repository for documentation images.

## Development guide for humans and AI assistants

The project is a small Swift package with no external package dependencies:

| Path | Responsibility |
| --- | --- |
| `Package.swift` | Package targets and minimum platform |
| `Sources/GitCore/GitRepository.swift` | Git process execution, status, history, diffs, branches, staging, and commits |
| `Sources/Citadel/AppModel.swift` | UI state, repository selection, asynchronous operations, and preview cancellation |
| `Sources/Citadel/ContentView.swift` | Repository sidebar, branch navigation, and toolbar |
| `Sources/Citadel/ChangesView.swift` | Working Copy, multiselection, commit input, and native diff rendering |
| `Sources/Citadel/HistoryView.swift` | Commit timeline and inspector |
| `Sources/Citadel/CitadelApp.swift` | App lifecycle, window, and menu commands |
| `tests/GitCoreTests/` | Integration tests using disposable repositories |
| `scripts/` | Native app packaging and icon generation |
| `Assets/` | Lighthouse source artwork and its generation provenance |

### Validate a change

```sh
swift test --disable-sandbox
./scripts/build-app.sh
```

Tests create temporary repositories and a local bare remote. They cover initial commits, partial staging, literal filenames, renames, branch browsing and ordering, merge diffs, local remote operations, and preview edge cases. They do not push to hosted remotes or modify your working repositories. UI behavior should also be checked manually in a disposable repository; there is no automated UI test suite yet.

When contributing, keep Git operations off the main UI thread, pass arguments as arrays rather than shell strings, and preserve path validation and stale-preview guards. Browsing a branch must remain separate from checking it out. Do not add credentials, personal repository data, screenshots of private code, or build artifacts. Explain what changed and how you validated it in your pull request.

## Current limits

Citadel is an early, focused Git client. It does not yet offer interactive rebase, hunk/line staging, or a merge conflict editor. Resolve conflicts in your editor before staging. Diffs use a file-backed paged viewer instead of a 500 KB cutoff. History appends pages of 300 commits pinned to a stable revision; search walks that full history. Long-running operations show progress and support cancellation instead of a fixed timeout.

Issues and pull requests are welcome in [the GitHub repository](https://github.com/alexjackhughes/citadel-git).

## License

Citadel is free and open source under the [MIT License](LICENSE). You may use, modify, and redistribute it, including commercially, subject to the license terms. The full license is included in this repository.

Copyright © 2026 Alex Jack Hughes. The lighthouse artwork was AI-generated; its prompt and provenance are recorded in `Assets/Icon-design.txt`.
