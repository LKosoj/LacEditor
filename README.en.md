# LacEditor

[中文](README.md) · English · [Русский](README.ru.md)

A quiet, fast text and code editor that feels at home on macOS.

LacEditor is made for everyday text, Markdown, JSON, and code editing: open it and start writing, switch tabs easily, and show the preview only when you need it. Advanced features live in native menus and shortcuts. It requires no account for local editing. Optional AI and Jina features send the requested content only when you enable and use them.

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

The current branch adds native light/dark colors, outline depth, a local emoji catalog, and recent/pinned folders. Quick Open (⌘⇧O) uses the existing search and appears as a floating panel above the editor without forcing the sidebar open. Formatted copying writes verified plain text and HTML; RTF is added when fidelity checks pass. Yams handles YAML and SwiftSoup handles HTML5. The editor remains native, without CSS themes. Full Typora parity remains in progress; builds, XCTest, and macOS behavior have not been verified.

## Why LacEditor?

- **Ready to write**: No account, workspace wizard, or unnecessary project configuration; start directly in the editor.
- **Focused but capable**: Tabs, find and replace, syntax highlighting, Markdown preview, and JSON tools are close at hand in a restrained interface.
- **Natural on macOS**: Native windows, menus, file pickers, shortcuts, dark mode, and drag-and-drop follow system conventions.
- **Works with large files**: Visible-area layout, background tasks, and graduated safeguards for long code and log files prioritize smooth typing and scrolling.
- **Work with text locally**: Editing, preview, and recovery need no login or network connection. During export, Pandoc may fetch resources referenced by the document.

## Core experience

### Writing assistant

The current source branch provides commands in the AI Writing Assistant menu and its side panel. Settings → Artificial Intelligence has a separate switch for every feature; all start disabled, with another switch for background processing. Spelling and grammar use macOS system checking, with independent settings and no AI-model requests or automatic spelling replacement. Available languages and quality depend on macOS; grammar checking with spelling disabled still needs verification on a Mac.

Implemented in source: clarity, rephrasing, shortening, expansion, translation, terminology, tone, structure, summaries, contradictions, action items, decisions, tables, and audience review. Compare the original and proposed change before accepting; accepted changes use normal undo. Edits invalidate old results. Terminology and contradiction reports link to both passages; summaries have an explicit insert button. Gray completion accepts Tab and dismisses with Esc or typing; it is disabled for large documents. Metadata suggestions can update after saving and can be edited; they live only in the current document object. Local provenance tracks events after enabling, does not guess unknown origins, and is not retained after restarting.

Illustrations require an explicit request and are previewed before saving or inserting after the selection as an embedded Markdown image. Image descriptions receive the selected image bytes and require a text model with image input. Decision questions and extracting decisions from notes are separate features.

Text, Decisions, and images have independent addresses, models, and protocols; keys are stored in the system Keychain. OpenAI uses `https://api.openai.com/v1`; compatible custom servers are configured manually. Source search and reading result pages use Jina, with separate switches, full endpoint URLs, and keys: defaults are `https://s.jina.ai/search` and `https://r.jina.ai/`. With Reader disabled, only unverified candidate links are shown; when enabled, quotes are checked against fetched content. This does not guarantee semantic correctness. Generated image binaries are downloaded normally; Jina reads web pages.

Builds, XCTest, input, system checks, and interface behavior require verification on a Mac. Live model and Jina requests have not been tested here, nor has model quality across the three languages. [Plan and limitations](docs/plans/2026-10-28-ai-editor-design.md).

Seven additional manual tools are implemented in source: review with selected documents (including unsaved tabs in other windows), exact comparison of two versions with an explanation, saved custom checks, image/PDF recognition, voice drafts, Mermaid generation, and explanation of a selection. Enable each tool separately and select it in the existing assistant panel. Context results provide verified quotations and source navigation; the app does not scan folders automatically. Each custom rule also has its own switch.

Recognition and audio have independent profiles. Gateway PDF uses `/v1/pdf/convert` with `output=docx`, followed by bundled Pandoc; compatible vision models can instead use Responses or Chat Completions. Audio uses `/v1/audio/transcriptions`. Enter your endpoint and an available model; examples from the neighboring gateway configuration are `llmgateway/pdf-converter` and `llmgateway/whisper-large-v3`. The editor does not install or reconfigure the gateway.

Record audio explicitly or choose an existing file; a separate command starts transcription, and microphone denial leaves file import available. Recognition, transcripts, and Mermaid blocks are inserted only on request with undo support; comparisons and explanations do not modify source files. Recognition and voice insertion also work in an empty document. Live models, recording, PDFKit, builds, and XCTest require verification on a Mac. [Seven-feature plan](docs/plans/2026-10-28-selected-ai-tools.md).


### Edit text and code

Supports common formats including TXT, Markdown, JSON, HTML, JavaScript, TypeScript, CSS, Python, Swift, Shell, YAML, C/C++, and SQL. Includes line numbers, current-line highlighting, automatic indentation, Tab indentation, undo and redo, basic folding, and matching bracket highlighting.

The current branch also prepares text/code font-family selection, forwarding changed size and spacing to preview/PDF/PNG, and an initial embedded local audio player without autoplay. Formatted editing has initial plain/HTML/RTF copying and HTML/RTF paste conversion, plus explicit Copy Markdown, Copy HTML Code, and Paste as Source Text commands. Complex clipboard content and resources remain incomplete. All of this code still requires builds, Swift tests, and verification on a Mac.

The current branch also adds interface improvements: find and replace is now an inline find bar above the editor (match count, regular expressions, whole word, ⌘E to use the selection, Esc to close), plus Go to Line (⌘L) and a clickable cursor position in the status bar; the sidebar supports keyboard navigation, type-select, and VoiceOver; the title bar has a path menu (⌘-click) and uses the system accent color; line numbers are right-aligned and the ruler width follows the digit count; Settings gain a search field, a segmented AI page, and delete confirmations; the Markdown preview follows the editor scroll; menus are reorganized and the default toolbar is shorter (saved toolbar configurations are unchanged); the editor keeps a horizontal margin of at least 16 pt and the Markdown maximum width defaults to 760 pt (it can be set to no limit in Settings). Further interface polish: the Markdown Format menu gains ⌘K link, ⇧⌘K inline code, ⇧⌘X strikethrough and ⌥⌘1–6 heading shortcuts, image actions move to an “Images” submenu, and a Help menu is added; dropping a folder opens it; an empty document offers “Open Folder…” and recent files; Quick Open highlights matched characters; the preview shows a loading state and an error message with “Retry”, and printing and PDF always use the light theme; settings search scrolls to and highlights the match, and image settings get their own page; AI panels keep Run/Stop in one place, edited inputs only mark the result as outdated, and writing suggestions get word highlighting plus “Accept All” and “Reject All”. The current branch also prepares a Markdown width limit, local flow/sequence and math rendering, their images in HTML/DOCX/EPUB, PDF page options, and HTML additions. Folders received from Finder use the existing window path; a new file loads its parent when no working folder is selected. Full features and Mac verification remain in progress.

### Side-by-side Markdown preview

Edit and preview side by side, with live rendering of headings, paragraphs, lists, blockquotes, horizontal rules, links, inline code, code blocks, tables, and GFM extensions. Close the preview whenever you like; long documents do not force you into a note-taking workflow.

In the current source branch, Mermaid, flow, and sequence diagrams are prepared for the preview (`⌥⌘P`) and formatted editor. Engines are bundled locally; invalid syntax leaves the source and an error. The diagram context menu copies PNG and saves SVG, PNG, or JPG; SVG contains the vector output of the same render. Supported export profiles prepare temporary images for Pandoc while preserving the document Markdown. Swift tests and static checks are prepared; WebKit, system dialogs, and final output files still require verification on a Mac.

```mermaid
flowchart LR
    A[Start] --> B[End]
```

### Source and formatted Markdown

In the current source branch, View → Markdown Editing switches between Markdown Source and Formatted Text. Both edit the same document; switching does not convert its text. The formatted view supports headings, bold, italics, strikethrough, inline code, links, blockquotes, and code blocks. Confirmed inline markup is revealed for the selected element while neighboring formatting on the same line remains visible; formatted copying prepares plain text and HTML, with RTF when fidelity checks pass; an explicit command copies the Markdown source. Confirmed ordinary list markers have a native presentation and reveal their source on the edited line. GFM tables, including incomplete rows and tables nested in lists or blockquotes, have a prepared editable grid, Tab navigation, multiline cells, and row/column dragging. Local, data URI, and remote images have native presentation, including inline, nested, and table images. GIF animation and SVG rendering are prepared; their runtime behavior still requires a Mac. The choice belongs to the current tab; restoring a session opens the source view. This is the first stage of formatted editing, not full Typora feature parity. Builds, cursor behavior, undo, Chinese input, and performance still require verification on a Mac; this feature is not included in release 0.15.0.

### Formatting commands and outline

In the current source branch, Markdown Format adds and removes bold (`⌘B`), italics (`⌘I`), strikethrough, inline code, headings 1–6, and blockquotes in both editing views. With no selection, inline commands insert paired markers; headings and blockquotes affect the selected lines. Each command is a separate undo action. Unconfirmed or escaped markers are not removed. Multi-paragraph selections for inline formatting and block commands inside code leave the text unchanged.

Commands also create bulleted, numbered, and task lists, fenced code blocks, and horizontal rules from ordinary lines. Converting existing list markup remains a separate follow-up task. XCTest coverage was added for UTF-16, CRLF, code blocks, and undo; builds, tests, and interface behavior still require verification on a Mac.

The sidebar Outline section shows headings in the current Markdown document. Clicking moves the caret to a heading and expands folded content. After an edit the list updates in the background; stale entries cannot be used for navigation. Outline works in source and formatted views, sharing the existing parse in the latter. The section starts collapsed and does not retain its expansion between launches. Builds and interface behavior for these features still require verification on a Mac.

### Document import and export

The current branch also prepares clickable task checkboxes, list continuation and indentation, row/column commands for ordinary GFM tables, an inline-link dialog, and footnotes with tooltips and Cmd-navigation. Bracket/quote pairs and Markdown marker pairs can be enabled separately in settings; both start disabled. Paragraph focus and typewriter modes are available. Markdown word counts use readable content; character and line counts use source text or its selection. The status-bar statistic and reading speed are configurable. Unsupported HTML currently leaves statistics unavailable. A working folder provides an expandable tree and opens files through existing tabs; creation, duplication, move, rename, and Trash with undo of the latest action are prepared. Per-tab folder state, four sort orders, tree/list views, and change monitoring for expanded directories are prepared. File-name, content, and YAML tag search share this sidebar, include unsaved open-document text, and validate results before navigation. Swift tests have been added, but builds, XCTest, and Mac behavior have not been verified; the full Typora plan remains in progress. CSS themes are excluded.

In the current source branch, File → Export converts Markdown to HTML, Word (DOCX), ODT, RTF, EPUB, FB2, LaTeX, plain text, PDF, MediaWiki, RST, Textile, and OPML. Pandoc 3.13 is bundled with the app: no separate installation or startup download is needed. PDF now uses WebKit and system printing without external LaTeX; pagination, images, cancellation, and output still require verification on a Mac. Export uses the current text, including unsaved edits and new documents without a path, and does not change the source document. A new document must have Markdown selected as its language. Pandoc converts GFM; formatting may differ from the preview. Export may fetch remote resources referenced by the document. HTML embeds images; relative LaTeX paths refer to the source file's folder. The four new formats and their XCTest coverage still require verification with the bundled Pandoc on a Mac.

File → Import… accepts DOCX, ODT, RTF, EPUB, FB2, HTML, and LaTeX and creates a new unsaved Markdown tab. The source file stays unchanged. Recognized embedded and local images are included in the document text; remote image references remain links, and are not fetched by the import filter. Complex formatting and image dimensions may not be preserved; complex LaTeX commands may also lose images. Embedded HTML pages are neither fetched nor displayed in the preview; relative file links remain relative. PDF input is unsupported; TXT and Markdown use the regular Open command. These features are not included in the published 0.15.0 release and still require build and interface verification on a Mac.

### JSON tools that preserve content

Formatting and minification change only structural whitespace, preserving object field order, duplicate keys, numeric literals, and string escape forms. Invalid JSON reports the line and column when possible. All changes can be reverted in a single undo.

### Files and windows

Supports multiple windows and tabs, drag-to-reorder tabs, dragging a tab out into a window, recent files, favorites, and custom groups. The same disk file has only one editable instance across windows; external changes are not silently overwritten by default.

In the current source branch, show or hide the left sidebar through View, its toolbar button, or `⌃⌘B`. View → Enter Distraction-Free Mode (`⇧⌘J`) fills the window working area with the editor, hiding the sidebar, preview, line numbers, status bar, and toolbar. Repeat the command to restore their previous state without changing shared preferences. `⌃⌘B` also exits the mode and shows the sidebar. Native tabs and window buttons remain available; this does not enter system full screen. The mode belongs to the current window and is not restored after restarting. Builds and interface behavior still require verification on a Mac.

In Settings > File Associations, view the default app for common formats and set LacEditor as needed. Installation and startup do not change associations automatically.

### Continue after quitting

By default, the complete workspace is saved on exit and windows, tabs, text, unsaved state, selections, scroll positions, and interface state are restored on the next launch. Workspace snapshots and crash recovery are stored separately, and disk files are not automatically rewritten. Settings also offer the traditional save confirmation before quitting.

This includes new documents that have never been saved to a file. After a crash, the last completed recovery snapshot is restored: writing is delayed by 2 seconds, or 5 seconds for large documents, so the latest edits may not be recovered. Explicitly discarding changes when closing a document removes its recovery data.

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
sh Scripts/prepare-pandoc.sh
swift build
swift test
```

Preparation extracts the verified official archive from `Vendor/Pandoc` without downloading anything. Xcode runs this step automatically. The extracted Pandoc adds approximately 186 MiB to the app; its repository archive is about 41 MiB. Version, licensing, and source distribution details: [Vendor/Pandoc/README.md](Vendor/Pandoc/README.md).

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

Translate selected text by choosing one of 13 languages or entering another language. Review the result before accepting it, with normal undo. AI settings allow a separate model for every AI feature, including translation, and every custom check. A blank field inherits the default model; the endpoint, key and protocol come from the corresponding connection type. Local provenance and system grammar do not use a model.
