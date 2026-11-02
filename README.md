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
- Plan linear interactive rebases with reorder, pick, reword, squash, fixup, drop and edit; recover paused work with Continue, Skip, Abort and Amend. Original tips are retained under local backup refs.
- Review working-copy changes in a compact file list with staging checkboxes and separate Staged / Unstaged diff views.
- Read unified diffs with line numbers, change counts, and red/green highlights.
- Resolve conflicts with base/current/incoming versions and an editable result. Save separately from staging, choose individual conflict sides, or use whole-file choices for binary and deletion conflicts.
- Stage or unstage individual files, complete hunks, selected changed lines, or all changes; commit staged contents with a subject. Partial staging validates the source before applying and never edits the working file.
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

Local browsing, diffs, staging, and commits do not require a network connection. Clone, Fetch, Pull, and Push use the selected source or configured Git remotes and authentication. Git hooks, credential helpers, and other Git configuration can run external programs and may access the network. Interactive authentication or signing may require setup in a terminal first.

Build artifacts, local settings, credentials, and development screenshots are excluded from version control. Screenshots of real repositories can expose private code, paths, and author details; use a disposable demo repository for documentation images.

## Development guide for humans and AI assistants

The project is a Swift package with no external package dependencies. The app bundles two small native helpers: `CitadelGitWorker` owns a cancellable Git process group, and `CitadelGitEditor` supplies reviewed rebase instructions and messages. Always use the build script to package both helpers:

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

Tests create temporary repositories and a local bare remote. They cover initial commits, partial staging, literal filenames, renames, branch browsing and ordering, merge diffs, local remote operations, cloning, stashes, conflict resolution, rebase actions/recovery, cancellation, large diffs and histories above 10,000 commits. They do not push to hosted remotes or modify your working repositories. UI behavior should also be checked manually in a disposable repository; there is no automated UI test suite yet.

When contributing, keep Git operations off the main UI thread, pass arguments as arrays rather than shell strings, and preserve path validation and stale-preview guards. Browsing a branch must remain separate from checking it out. Do not add credentials, personal repository data, screenshots of private code, or build artifacts. Explain what changed and how you validated it in your pull request.

## Advanced workflows

**Clone or initialize:** use File → Clone Repository or New Repository. Cloning requires a new destination and uses your existing Git credentials or SSH agent. Embedded credentials are rejected. Interrupted destinations are preserved; reveal the folder and choose a new name to retry. Initialization keeps existing files and creates no automatic commit.

**Stashes:** choose Stashes in the sidebar (⌘3). Create a stash with an optional message and opt in to untracked files. Apply keeps the stash; Pop drops it only after successful application. Conflicts keep the stash and open Working Copy for resolution. Delete requires confirmation.

**Partial staging:** select changed rows in the diff with click, ⌘click, ⇧click or keyboard navigation. Stage/Unstage Selected Lines affects only the index. Select any row of a complete hunk to use Stage/Unstage Hunk. Incomplete hunks and stale file/index snapshots cannot be applied; load more or refresh first. Binary files, links, renames, submodules and conflicts use whole-file actions.

**Conflicts:** select a conflicted file to inspect Base, Current and Incoming versions. Edit Result directly or choose a side for each conflict. Previous/Next selects and scrolls to the conflict. Save Result writes the file; Mark Resolved stages it separately and rejects remaining conflict markers. Reload can preserve your in-memory draft. Binary, unsupported-encoding and deletion conflicts have explicit whole-file choices. Submodules must be resolved in their own repository before staging.

**Interactive rebase:** use Repository → Interactive Rebase, or a history commit's context menu. The upstream is excluded from the rewrite; blank upstream includes the root. The checked-out branch must have a clean working tree and a linear selected range. Reorder the plan, choose actions, and edit reword/squash messages before confirming. Known remote-tracking references are displayed; there is no automatic push. Edit stops allow an explicit amend followed by Continue. Conflicts open the same conflict editor. Skip and Abort require confirmation. Cancel stops the running process; it does not mean Abort.

Original rebase tips are preserved under `refs/citadel/backups/`. List them with `git for-each-ref refs/citadel/backups/` and create a recovery branch from a chosen reference if needed. Paused rebase metadata is stored in the repository's Git directory under `citadel/`, alongside Git's own operation state. No global Git editor settings are changed.

## Loading and current limits

Diffs use a file-backed paged viewer instead of a 500 KB cutoff. History appends pages of 300 commits pinned to a stable revision; search walks the full pinned history. Long-running operations show progress and support cancellation instead of a fixed timeout. Diff rows are virtualized; very long individual lines show a shortened display while complete bytes remain available to patch operations.

Merge-topology rebases, arbitrary rebase `exec` commands, built-in provider login, and automatic force-push are intentionally unsupported. The conflict text editor supports UTF-8 (including CRLF); other encodings use whole-file resolution. Unsaved conflict drafts remain in memory and do not survive closing the editor or restarting the app. Git hooks, signing, SSH trust and credentials can require terminal setup. Large operations remain limited by available disk space and memory.

Issues and pull requests are welcome in [the GitHub repository](https://github.com/alexjackhughes/citadel-git).

## License

Citadel is free and open source under the [MIT License](LICENSE). You may use, modify, and redistribute it, including commercially, subject to the license terms. The full license is included in this repository.

Copyright © 2026 Alex Jack Hughes. The lighthouse artwork was AI-generated; its prompt and provenance are recorded in `Assets/Icon-design.txt`.
