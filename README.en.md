# LacEditor

[中文](README.md) · English · [Русский](README.ru.md)

A quiet, fast text and code editor that feels at home on macOS.

LacEditor is made for everyday text, Markdown, JSON, and code editing: open it and start writing, switch tabs easily, and show the preview only when you need it. Advanced features live in native menus and shortcuts. It requires no account, does not connect to the cloud, and does not collect your document contents.

<p>
  <a href="https://github.com/kolmh/LacEditor/releases/latest">Download the latest release</a>
  ·
  <a href="https://github.com/kolmh/LacEditor/releases/tag/v0.15.0">View the release notes</a>
  ·
  <a href="https://github.com/kolmh/LacEditor/issues">Report an issue</a>
</p>

> Latest stable release: `0.15.0` · macOS 26+ · Apple Silicon

Current version: **0.15.0 (build 76)**. This release brings a more compact sidebar, undoable file organization, more reliable hover feedback, and File Associations settings. It also fixes a missing window when launching the app by double-clicking an associated file. Existing settings and workspaces are retained; there is no entry point to an experience document or automatic example.

Download `LacEditor-0.15.0-arm64.zip` from [GitHub Release](https://github.com/kolmh/LacEditor/releases/tag/v0.15.0). Quit the old version, unzip the archive, and drag `LacEditor.app` to Applications to replace it. Requires Apple Silicon and macOS 26 or later. See the [0.15.0 release record](AcceptanceReports/0.15.0-2026-10-21.md) for build and acceptance details.

## Why LacEditor?

- **Ready to write**: No account, workspace wizard, or unnecessary project configuration; start directly in the editor.
- **Focused but capable**: Tabs, find and replace, syntax highlighting, Markdown preview, and JSON tools are close at hand in a restrained interface.
- **Natural on macOS**: Native windows, menus, file pickers, shortcuts, dark mode, and drag-and-drop follow system conventions.
- **Works with large files**: Visible-area layout, background tasks, and graduated safeguards for long code and log files prioritize smooth typing and scrolling.
- **Your content stays on your Mac**: Local files, local preview, and local recovery; no login, network connection, or document upload.

## Core experience

### Edit text and code

Supports common formats including TXT, Markdown, JSON, HTML, JavaScript, TypeScript, CSS, Python, Swift, Shell, YAML, C/C++, and SQL. Includes line numbers, current-line highlighting, automatic indentation, Tab indentation, undo and redo, basic folding, and matching bracket highlighting.

### Side-by-side Markdown preview

Edit and preview side by side, with live rendering of headings, paragraphs, lists, blockquotes, horizontal rules, links, inline code, code blocks, tables, and GFM extensions. Close the preview whenever you like; long documents do not force you into a note-taking workflow.

### JSON tools that preserve content

Formatting and minification change only structural whitespace, preserving object field order, duplicate keys, numeric literals, and string escape forms. Invalid JSON reports the line and column when possible. All changes can be reverted in a single undo.

### Files and windows

Supports multiple windows and tabs, drag-to-reorder tabs, dragging a tab out into a window, recent files, favorites, and custom groups. The same disk file has only one editable instance across windows; external changes are not silently overwritten by default.

In Settings > File Associations, view the default app for common formats and set LacEditor as needed. Installation and startup do not change associations automatically.

### Continue after quitting

By default, the complete workspace is saved on exit and windows, tabs, text, unsaved state, selections, scroll positions, and interface state are restored on the next launch. Workspace snapshots and crash recovery are stored separately, and disk files are not automatically rewritten. Settings also offer the traditional save confirmation before quitting.

In the current source branch, quitting waits for file reads and saves and writes the session again if changes occur during the write. If the session cannot be safely restored at startup, the app reports the error and stops launching, preserving recovery data on disk. An unfinished or failed initial read cannot be saved over the source file or moved to another window before reading succeeds.

### Interface language

The current source branch supports System, Chinese, English, and Russian in Settings > Appearance > Language. Changes take effect after restarting the app; this feature is not included in the published 0.15.0 release.

## Download and use

Download the latest arm64 ZIP from [Releases](https://github.com/kolmh/LacEditor/releases), unzip it, and drag `LacEditor.app` into Applications.

When first opening a locally ad-hoc signed build, if macOS blocks it, allow it in System Settings > Privacy & Security.

## Build from source

The current branch uses SwiftUI + AppKit and does not require Flutter.
The `LacEditor` scheme uses a separate development identity and data for Debug; create the release package with `zsh Scripts/package-release.sh`.
The `LacEditor-UI-Experiment` scheme retains a separate experimental identity; see the [experimental version notes](docs/UI_EXPERIMENT_README.md).
The release package uses release data; data from the separate experimental package is not migrated automatically. Packaging and verification instructions for release candidates remain in the [release candidate documentation](docs/RELEASE_CANDIDATE.md).

Requirements:

- macOS 26+
- Apple Silicon Mac
- Xcode 26+

```bash
git clone https://github.com/kolmh/LacEditor.git
cd LacEditor
swift build
swift test
```

To run the full release acceptance checks:

```bash
./Scripts/run-acceptance.sh
```

Alternatively, open `LacEditor.xcodeproj` in Xcode, select the `LacEditor` scheme, and press `Command+R`.

## Technical direction

Since 0.14.0, LacEditor uses native macOS window tabs, supporting system drag, detach, and merge. Old workspaces are restored as native tab groups in their original order, retaining unsaved content, original file paths, and opening from Finder.

LacEditor uses SwiftUI for the interface, AppKit `NSTextView` for editing, TextKit for visible-area layout, and WebKit with `cmark-gfm` for local Markdown preview. File I/O, syntax scanning, find and replace, JSON, preview, and recovery remain separate. Background tasks check the document revision so stale results cannot overwrite newer edits.

## Roadmap

The full performance and architecture roadmap is in [docs/ROADMAP.md](docs/ROADMAP.md). The current plan has three stages:

- Stage 1: Reduce full-text copies in Markdown preview, improve search caching, and add regression tests for line numbers and trailing empty lines.
- Stage 2: Prune Tree-sitter work by changed ranges, split highlighting and folding tasks, and reduce main-thread work for long code files.
- Stage 3: Architecture assessment completed using external sources; retain TextKit 1 and the current document lifecycle. The TextKit 2 experiment is excluded, while a shared rendering layer and large-class refactoring are deferred.
The current working tree adds cancellable preview, statistics and folding tasks, sidebar keyboard selection and batch actions, and progressive workspace loading that prioritizes selected tabs. These changes are unreleased: Mac builds, XCTest, real UI checks and comparative measurements remain pending. See the [completion plan](docs/plans/roadmap-completion-plan.md) and [next optimization checklist](NEXT_OPTIMIZATIONS.md).

Git, a plugin system, cloud sync, and bidirectional links are not currently part of LacEditor's core roadmap.

## Contributing

Report problems or suggest improvements through [Issues](https://github.com/kolmh/LacEditor/issues). Before submitting a feature change, describe the user scenario and run `swift test` and `./Scripts/run-acceptance.sh`.

See [VERSIONING.md](VERSIONING.md) for versioning, commit, and release rules, and [CHANGELOG.md](CHANGELOG.md) for the full change history.
