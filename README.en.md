# LacEditor

[中文](README.md) · English · [Русский](README.ru.md)

A quiet, fast text and code editor that feels at home on macOS.

LacEditor is made for everyday text, Markdown, JSON, and code editing: open it and start writing, switch tabs easily, and show the preview only when you need it. Advanced features live in native menus and shortcuts. It requires no account for local editing. Optional AI and Jina features send the requested content only when you enable and use them.

<p>
  <a href="https://github.com/LKosoj/LacEditor/releases/latest">Download the latest release</a>
  ·
  <a href="CHANGELOG.md">View the change log</a>
  ·
  <a href="https://github.com/LKosoj/LacEditor/issues">Report an issue</a>
</p>

> macOS 26+ · Apple Silicon

## Why LacEditor?

- **Ready to write**: No account, workspace wizard, or unnecessary project configuration; start directly in the editor.
- **Focused but capable**: Tabs, find and replace, syntax highlighting, Markdown preview, and JSON tools are close at hand in a restrained interface.
- **Natural on macOS**: Native windows, menus, file pickers, shortcuts, dark mode, and drag-and-drop follow system conventions.
- **Works with large files**: Visible-area layout, background tasks, and graduated safeguards for long code and log files prioritize smooth typing and scrolling.
- **Work with text locally**: Editing, preview, and recovery need no login or network connection. During export, Pandoc may fetch resources referenced by the document.

## Core experience

### Writing assistant

Commands are in the AI Writing Assistant menu and its side panel. Settings → Artificial Intelligence has a separate switch for every feature; all start disabled. Spelling and grammar use macOS system checking, with independent settings and no AI-model requests or automatic spelling replacement. Available languages and quality depend on macOS.

Available: clarity, rewrite (rephrase, shorten, expand, adjust tone), translation, consistency check (terms and contradictions), reader’s view (tone and unclear passages), structure, summaries, tasks and decisions, tables, and “Ask About Documents” (answers only from the current document or selection, the open documents of the current window, or chosen files, with verifiable, clickable citations; the conversation lives only in window memory; with Jina Search enabled, “Search the web” lets the model search up to 3 times per answer through function calling (the server must support it), only the first 16,000 characters of each result page are given to the model, citations are checked against the text the model received when Reader is on, and web sources are listed separately and opened only on click; later questions carry the web sources of earlier answers (title, address and verified quotations), and a link in an answer is clickable only if it comes from those sources; “Explain Selection” is its menu command). Every feature has a “Needs / Result” description in menu tooltips, the AI panel, and settings; the image context menu has “Describe Image with AI”. Compare the original and proposed change before accepting; accepted changes use normal undo. Editing the text does not clear the result in the panel: suggestions are accepted one by one (the location is checked before applying), and Reset Result clears it. Menu items only open the panel; only Explain Selection sends a request immediately. The consistency report has terms and contradictions sections that link to both passages; summaries have an explicit insert button. Gray completion accepts Tab and dismisses with Esc or typing; it is disabled for large documents. Metadata suggestions are shown in the panel, can be edited, and can update after saving; they live only in the current document object.

Translate selected text by choosing one of 13 languages or entering another language. Review the result before accepting it, with normal undo. AI settings allow a separate model for every AI feature, including translation, and every custom check. A blank field inherits the default model; the endpoint, key and protocol come from the corresponding connection type.

Illustrations require an explicit request, are previewed before insertion, and are saved to a chosen file or inserted after the selection as an embedded Markdown image. Image descriptions receive the selected image bytes and require a text model with image input.

Text, Decisions, and images have independent addresses, models, and protocols; keys are stored in the system Keychain. OpenAI uses `https://api.openai.com/v1`; compatible custom servers are configured manually. Source search and reading result pages use Jina, with separate switches, full endpoint URLs, and keys: defaults are `https://s.jina.ai/search` and `https://r.jina.ai/`. With Reader disabled, only unverified candidate links are shown; when enabled, quotes are checked against fetched content. This does not guarantee semantic correctness. Generated image binaries are downloaded normally; Jina reads web pages.

There are also five manual tools: review with selected documents (including unsaved tabs in other windows), exact comparison of two versions with an explanation, saved custom checks, image/PDF recognition, and Mermaid generation. Enable each tool separately and select it in the same assistant panel. Context results provide verified quotations and source navigation; these tools read only the sources you select and never walk folders on their own. Each custom rule also has its own switch.

Recognition and audio have independent profiles. Gateway PDF uses `/v1/pdf/convert` with `output=docx`, followed by bundled Pandoc; compatible vision models can instead use Responses or Chat Completions. Audio uses `/v1/audio/transcriptions`. Enter your endpoint and an available model; examples from the neighboring gateway configuration are `llmgateway/pdf-converter` and `llmgateway/whisper-large-v3`.

The toolbar microphone button provides dictation: once Dictation is enabled and a speech transcription model is set, click to start recording and click again to stop; only then is the audio sent for transcription, after which the text model removes filler words and tidies the text, and the result is inserted at the caret (the selection is not replaced; one undo step). If the text model is off or cleanup fails, the raw transcript is inserted; a recognition failure offers Retry or Delete recording; if the document was closed or cannot take the text, it is copied to the clipboard. Recognized text and Mermaid blocks are inserted only on request with undo support; comparisons do not modify source files. Recognition also works in an empty document.

A request waits up to 10 minutes. Network errors distinguish timeout, no connection, server not found and secure-connection failure, with a manual Retry button (nothing is retried automatically). The model reply may be wrapped in a ```json fence; items that cannot be verified are skipped and their count is shown. A manual send above 50 KB (UTF-8 bytes after embedded media is removed) is not sent at once: the panel shows the source and size and sends only after you choose Send anyway. After sending, the panel shows the source and size. Images, OCR and audio are not limited. A model reply cut off by the length limit is reported as an error and never shown as a complete answer; the AI agent is not subject to the 50 KB limit and has its own limits and counters.

The AI agent is a separate feature of the AI panel; it is disabled by default and enabled on its own in Settings → Artificial Intelligence. Describe a task and press Run: the model searches and reads the open documents of the current window (including unsaved text) and the files of the working folder, keeps a plan with notes, and answers; you can ask follow-up questions in the same conversation, and New Conversation starts over. The agent works only after you press Run, never in the background, and Stop works at any time during a run. The activity log lists every search and every file read with the size sent; the panel shows bytes sent, context size, number of rounds and the token usage the server reports. File access is limited to the working folder: symbolic links, hidden files and hidden folders are not read, and the encoding of a non-UTF-8 file is not guessed; with no folder open only the open documents can be read. Web search is off by default and needs Jina Search; before every search the query is shown and you choose Allow, Allow for this run or Reject. The model reads only pages from the search results and cannot choose addresses itself, and a link in an answer is clickable only if it comes from a real source. On long tasks old tool results are cleared and, when needed, the conversation is condensed into a summary while the plan and notes stay in place; the server must support function calling (tools). The Scenario menu only fills the task field with a ready text (fact-check, translate a long text, consistency across documents, edit files in the folder, draft from notes); it does not start the agent or turn on web search.

The agent never changes anything by itself. Its edits are proposals shown as the original next to the replacement: for open documents choose Accept or Reject (or Accept All / Reject All), and one Undo reverts an accepted change; new external addresses in a replacement are highlighted. Proposals for files that are not open (only inside the working folder, at most 10 files, plain UTF-8 without BOM) are written only after you press the separate Apply to Files (N) button and confirm: each file is read again and checked before writing and is skipped if it changed on disk, and a file version is saved before and after writing and can be restored from the version history; Undo does not revert this write. A failure on one file does not stop the others, and a report lists the result for each file. Proposals you have not accepted are discarded by New Conversation.

### Edit text and code

Supports common formats including TXT, Markdown, JSON, HTML, JavaScript, TypeScript, CSS, Python, Swift, Shell, YAML, C/C++, and SQL. Includes line numbers, current-line highlighting, automatic indentation, Tab indentation, undo and redo, basic folding, and matching bracket highlighting.

Choose font families for text and code; changed size and spacing are forwarded to preview, PDF, and PNG. Local audio plays in the embedded player without autoplay. The formatted editor copies plain text, HTML, and RTF and converts HTML/RTF on paste; explicit Copy Markdown, Copy HTML Code, and Paste as Source Text commands are also available.

Find and replace is an inline bar above the editor: match count, regular expressions, whole word, `⌘E` searches the selection, `Esc` closes. `⌘L` and the cursor position in the status bar open Go to Line. Line numbers are right-aligned and the ruler width follows the digit count. The editor keeps a horizontal margin of at least 16 pt and the Markdown maximum width defaults to 760 pt (it can be set to no limit in Settings).

### Side-by-side Markdown preview

Edit and preview side by side, with live rendering of headings, paragraphs, lists, blockquotes, horizontal rules, links, inline code, code blocks, tables, and GFM extensions. Close the preview whenever you like; long documents do not force you into a note-taking workflow.

Mermaid, flow, and sequence diagrams render in the preview (`⌥⌘P`) and formatted editor. Engines are bundled locally; invalid syntax leaves the source and an error. The diagram context menu copies PNG and saves SVG, PNG, or JPG; SVG contains the vector output of the same render. Supported export profiles prepare temporary images for Pandoc while preserving the document Markdown.

```mermaid
flowchart LR
    A[Start] --> B[End]
```

Math formulas and their images in HTML, DOCX, and EPUB, PDF page options, and HTML additions are also supported. Light and dark colors are configurable, the outline can be limited to a heading depth, and emoji come from a local catalog.

The preview follows the editor scroll and shows a loading state and an error message with “Retry”. Alerts are colored by type, code blocks are highlighted by language (also in PDF and printing), and quote bars, checkboxes and selection use the system accent color. Printing and PDF always use the light theme.

### Source and formatted Markdown

View → Markdown Editing switches between Markdown Source and Formatted Text. Both edit the same document; switching does not convert its text. The formatted view supports headings, bold, italics, strikethrough, inline code, links, blockquotes, and code blocks. Confirmed inline markup is revealed for the selected element while neighboring formatting on the same line remains visible. Copying produces plain text and HTML, with RTF when fidelity checks pass; an explicit command copies the Markdown source. Confirmed ordinary list markers have a native presentation and reveal their source on the edited line. GFM tables, including incomplete rows and tables nested in lists or blockquotes, have an editable grid, cell editing, Tab navigation, multiline cells, and row/column dragging. Local, remote, and data URI images are shown in the editor, including inline, nested, and table images, as well as animated GIF and SVG. The choice belongs to the current tab; restoring a session opens the source view.

### Formatting commands and outline

Markdown Format adds and removes bold (`⌘B`), italics (`⌘I`), strikethrough, inline code, headings 1–6, and blockquotes in both editing views; shortcuts include `⌘K` (link), `⇧⌘K` (inline code), `⇧⌘X` (strikethrough), and `⌥⌘1–6` (headings), and image actions are in the “Images” submenu. With no selection, inline commands insert paired markers; headings and blockquotes affect the selected lines. Each command is a separate undo action. Unconfirmed or escaped markers are not removed. Multi-paragraph selections for inline formatting and block commands inside code leave the text unchanged.

Commands also create bulleted, numbered, and task lists, fenced code blocks, and horizontal rules from ordinary lines.

The sidebar Outline section shows headings in the current Markdown document. Clicking moves the caret to a heading and expands folded content. After an edit the list updates in the background; stale entries cannot be used for navigation. Outline works in source and formatted views, sharing the same parse in the latter. The section starts collapsed and does not retain its expansion between launches.

Task checkboxes are clickable, and lists continue and change indentation automatically. Ordinary GFM tables have row/column commands, inline links have a dialog, and footnotes have tooltips and Cmd-navigation. Bracket/quote pairs and Markdown marker pairs can be enabled separately in settings; both start disabled. Paragraph focus and typewriter modes are available. Markdown word counts use readable content; character and line counts use source text or its selection. The status-bar statistic and reading speed are configurable.

### Document import and export

File → Export converts Markdown to HTML, Word (DOCX), ODT, RTF, EPUB, FB2, LaTeX, plain text, PDF, MediaWiki, RST, Textile, and OPML. Pandoc 3.13 is bundled with the app: no separate installation or startup download is needed. PDF uses WebKit and system printing without external LaTeX. Export uses the current text, including unsaved edits and new documents without a path, and does not change the source document. A new document must have Markdown selected as its language. Pandoc converts GFM; formatting may differ from the preview. Export may fetch remote resources referenced by the document. HTML embeds images; relative LaTeX paths refer to the source file's folder.

File → Import… accepts DOCX, ODT, RTF, EPUB, FB2, HTML, LaTeX, and PDF with a text layer and creates a new unsaved Markdown tab. The source file stays unchanged. Recognized embedded and local images are included in the document text; remote image references remain links, and are not fetched by the import filter. Local images are read only within the source file's folder; paths escaping it and symlinks leading outside are not read. Absolute image paths and `file:` URIs are not embedded, even when they point inside that folder. RST and LaTeX include directives are not expanded during import, including references to files inside the source folder. Complex formatting and image dimensions may not be preserved; complex LaTeX commands may also lose images. Embedded HTML pages are neither fetched nor displayed in the preview; relative file links remain relative. Scanned PDFs without a text layer are not imported; TXT and Markdown use the regular Open command.

### JSON tools that preserve content

Formatting and minification change only structural whitespace, preserving object field order, duplicate keys, numeric literals, and string escape forms. Invalid JSON reports the line and column when possible. All changes can be reverted in a single undo.

### Files and windows

Supports multiple windows and tabs, drag-to-reorder tabs, dragging a tab out into a window, recent files, favorites, and custom groups. The same disk file has only one editable instance across windows; external changes are not silently overwritten by default.

Quick Open (`⌘⇧O`) appears as a floating panel above the editor, searches the current folder and pinned and recent folders, and highlights matched characters. A folder received from Finder or dropped into the window opens in the same window; a new file loads its parent folder when no working folder is selected. An empty document offers “Open Folder…” and recent files. The title bar has a path menu (⌘-click).

A working folder shows a tree or list and opens files in tabs. Creation, duplication, move, rename, and Trash with undo of the latest action, four sort orders, and change monitoring for expanded directories are available; folder state is kept per tab. File-name, content, and YAML tag search share this sidebar, include unsaved open-document text, and validate results before navigation. The sidebar supports keyboard navigation, type-select, and VoiceOver; the context menu of favorites and groups has Move Up and Move Down.

Show or hide the left sidebar through View, its toolbar button, or `⌃⌘B`. View → Enter Distraction-Free Mode (`⇧⌘J`) fills the window working area with the editor, hiding the sidebar, preview, line numbers, status bar, and toolbar. Repeat the command to restore their previous state without changing shared preferences. `⌃⌘B` also exits the mode and shows the sidebar. Native tabs and window buttons remain available; this does not enter system full screen. The mode belongs to the current window and is not restored after restarting.

Settings have a search field that scrolls to and highlights the match. The toolbar is customizable with macOS tools, and the system accent color is used.

In Settings > File Associations, view the default app for common formats and set LacEditor as needed. Installation and startup do not change associations automatically.

### Notes and editing enhancements

- **Command palette** (`⇧⌘A`, View → Command Palette…): a floating panel above the editor listing every available main-menu command. Search by name and menu path, shortcuts are shown, `Return` runs and `Esc` closes. Unavailable, hidden, and system items (Services, Window) are not listed; the palette and Quick Open never show together. `⇧⌘P` is not used because it belongs to Page Setup….
- **Line operations and comments**: Edit → Lines offers Duplicate Line (`⇧⌘D`), Move Up/Down (`⌃⌘↑`/`⌃⌘↓`), Delete Line (`⌃⇧K`), Join Lines (`⌃⌘J`), and Sort Ascending/Descending (natural order, stable; with a single line selected the whole document is sorted). Toggle Comment (`⌘/`) supports Swift, JS/TS, C, Python, Shell, YAML, SQL (line comments) and HTML, Markdown, CSS (block comments applied per line); JSON and plain text are not supported. Each command is one undo step.
- **Version history and comparison with disk**: every successful save records a macOS file version (a failure does not affect saving). File → Browse Versions… compares the selected version with the current text line by line; Restore This Version is one undoable replacement and leaves the document unsaved. Compare with File on Disk… compares the disk file using the document's encoding. Unavailable for documents without a path; versions are managed by the system and there is no delete interface.
- **Line endings and encoding**: the status bar shows LF, CRLF, CR, or Mixed; its menu shows counts and converts the document to LF/CRLF/CR (also in Edit → Line Endings). Conversion is one replacement and one undo; U+2028/U+2029 are not line breaks. File → Save with Encoding… changes only the write encoding (the document becomes unsaved; characters that cannot be represented reject the save). Reopen with Encoding… rereads the disk file in the chosen encoding (confirmation first if there are unsaved edits; undo history is reset).
- **Wiki links**: Markdown supports `[[name]]`, `[[name#Heading]]`, and `[[name|text]]`. The file is found by name in the open folder (or next to the document without a folder); with several same-named files nothing is guessed, write the path. In the formatted view the brackets are hidden and unresolved links are dimmed; `⌘`-click follows the link (offers to create a missing file); typing `[[` suggests file names; the preview and export replace them with plain links. Wiki links are not recognized inside tables and headings, and embedding `![[…]]` is not supported.
- **Backlinks**: with a folder open, the sidebar "Backlinks" section lists ordinary and wiki links in other Markdown files that point to the current file, with a line snippet; click to jump. Unsaved edits of open documents are included. The section is not stored in the session.
- **Tags**: folder tag search matches both YAML front matter tags and inline `#tags` in the text (also in headings, lists, quotes, and tables), as whole tags, case-insensitively (`#a` matches `a` and `a/b`, not `ab`). Numbers, `C#`, headings, code, links, wiki links, HTML, formulas, and `\#` are not tags. The sidebar "Tags" section shows tags with file counts, loaded on expand, folder change, or "Refresh Tags"; clicking a tag starts the search. Inline tags get their own color in the formatted view. The list is flat (no `a/b` hierarchy) and updates on expand, folder change, and on command; tags inside tables are not colored.
- **Templates and daily note**: File → New Note from Template… picks a Markdown template from the templates folder and a name, creates the file in the current directory (otherwise the workspace root) without overwriting, and opens it; `{{title}}`, `{{date}}` (yyyy-MM-dd), and `{{time}}` (HH:mm) are replaced. File → Daily Note opens or creates today's note (from `daily.md` in the templates folder, otherwise empty). Settings → Files & Recovery → Templates and daily notes sets the templates folder, the daily notes folder, and the date format. A missing daily notes folder is not created; without a workspace folder the commands offer to open one.
- **Replace in folder**: folder content search has case-sensitive, regular expression, and whole-word toggles plus a Replace mode: a "before → after" preview, per-match checkboxes (all selected by default), "Replace Selected", and a confirmation with match and file counts. Files that are not open are written directly as UTF-8 atomically and Undo cannot restore them; files changed after the search, files that are not plain UTF-8 (for example with a BOM), and symbolic links are skipped and explained in the result. Open documents receive one editor replacement (one undo) and are not saved. Name and tag searches have no replace.
- **Reading mode** (`⌥⌘R`, View → Reading Mode): blocks editing while keeping selection, copying, search, and link navigation. Markdown is shown formatted, and the previous view returns on exit. The mode applies to the current tab, is not kept between launches, and has an indicator in the status bar. It can also be turned on with a toolbar button; clicking the status bar indicator exits it, and the Markdown view button exits and shows the source.
- **Current element in the status bar**: shows the path of Markdown elements under the caret, such as “Heading 2 › Bold” or “Quote › List Item › Link”. It is hidden for plain text, selections, large files, other languages, and windows narrower than about 700 pt.
- **Clear save status**: the status bar distinguishes saved, unsaved (with a confirmed recovery copy or not yet), a failed recovery copy, and a new document with no file; the tooltip shows the last save time.
- **Writing goal**: the “Daily word goal” setting (0 turns it off) shows written / goal in the status bar. It counts the net word increase per document for the calendar day; closed documents keep their contribution until the day ends. There are no notifications.
- **Moving sections in the outline**: a top-level heading can be dragged or moved with Move Section Up and Move Section Down in the context menu, or `⌥↑`/`⌥↓`. The section moves with its subsections in a single undo step; the heading level does not change.
- **Pinned and recent commands**: with an empty query the palette is grouped as Pinned, Recent (up to 5), and All Commands; the pin button on a row or `⌥↩` pins or unpins a command. A command is identified by its menu title path, so after changing the interface language older entries are hidden, not deleted.
- **Sentence focus**: View → Focus Current Sentence keeps only the current sentence bright. Tables, block images, and vertical writing use the paragraph area.
- **Assemble a manuscript**: with a folder open, File → Assemble Manuscript… merges the selected `.md`/`.markdown` files into a new unsaved tab; order is set by dragging or with buttons. Unsaved edits of open files are included, and closed files are read as UTF-8 (others are skipped with a message). Front matter stays with the first file, and relative image and link addresses become absolute, so the result does not move to another computer. `[a][ref]` forms, HTML links, and media are not converted and are counted in the summary; matching footnote labels produce a warning and need a manual fix. An unclosed code block at the end of a file swallows the next file. Source files do not change.
- **Updating links on rename**: when a Markdown file is renamed or moved inside the open folder, the app finds wiki links and ordinary links to it and asks for confirmation; by default links stay as they are. Open documents are updated with one undoable edit, closed files (UTF-8 without BOM only) are written to disk, and undoing the rename does not restore links. Folders, `file:` addresses, reference links, ambiguous names, names containing `# | [ ]`, and the moved file's own relative links are not updated.
- **CriticMarkup suggestions**: `{++ ++}`, `{-- --}`, `{~~ ~> ~~}`, `{>> <<}`, and `{== ==}` are highlighted in source and formatted views; Markdown → Suggestions proposes insertions, deletions, and comments, accepts or rejects the current or all suggestions, and moves to the next or previous one. Suggestions in tables, code, and HTML are not recognized, and preview and export show the markup as plain text.

### Continue after quitting

By default, the complete workspace is saved on exit and windows, tabs, text, unsaved state, selections, scroll positions, and interface state are restored on the next launch. Workspace snapshots and crash recovery are stored separately, and disk files are not automatically rewritten. Settings also offer the traditional save confirmation before quitting.

This includes new documents that have never been saved to a file. After a crash, the last completed recovery snapshot is restored: writing is delayed by 2 seconds, or 5 seconds for large documents, so the latest edits may not be recovered. Explicitly discarding changes when closing a document removes its recovery data.

Quitting waits for file reads and saves and writes the session again if changes occur during the write. If the session cannot be safely restored at startup, the app reports the error and stops launching, preserving recovery data on disk. An unfinished or failed initial read cannot be saved over the source file or moved to another window before reading succeeds.

### Interface language

Choose System, Chinese, English, or Russian in Settings > Appearance > Language. Changes take effect after restarting the app.

## Download and install

Download the latest arm64 ZIP from the [Releases](https://github.com/LKosoj/LacEditor/releases) page, quit the old version, unzip the archive, and drag `LacEditor.app` into Applications to replace it. Requires Apple Silicon and macOS 26 or later. Settings and workspaces are retained. The contents of each release are described in [CHANGELOG.md](CHANGELOG.md); this README describes the current repository code.

When first opening a locally ad-hoc signed build, if macOS blocks it, allow it in System Settings > Privacy & Security.

## Build from source

The `LacEditor` scheme uses a separate development identity and data for Debug; create the release package with `zsh Scripts/package-release.sh`.
The `LacEditor-UI-Experiment` scheme retains a separate experimental identity.
The release package uses release data; data from the separate experimental package is not migrated automatically.

Requirements:

- macOS 26+
- Apple Silicon Mac
- Xcode 26+

```bash
git clone https://github.com/LKosoj/LacEditor.git
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

### Scripts

The scripts are in the `Scripts` folder and run on macOS. They use only repository files: source code, Pandoc, and versions are taken locally, and nothing is downloaded from or sent to Git. Swift dependencies are fetched by Swift Package Manager from the addresses in `Package.swift`.

| Script | What it does |
| --- | --- |
| `prepare-pandoc.sh` | Verifies the checksum of the archive in `Vendor/Pandoc`, extracts Pandoc to `LacEditor/Resources/Pandoc`, and allows it to run. Needed before building with Swift Package Manager; Xcode runs this step itself. |
| `verify-release.sh` | Pre-release check: consistent version numbers, Debug and Release builds, XCTest, separate core checks, and an Xcode Release build. |
| `run-acceptance.sh` | Full acceptance: everything in `verify-release.sh`, Xcode code analysis, checks with 1, 10, 20, 50, and 100 MB files, architecture, and the acceptance app. Afterwards removes the registration of build copies as file handlers. |
| `verify-bundled-pandoc.sh` | Checks Pandoc inside a built `.app`: presence, arm64 architecture, version 3.13, license files, the import filter, and the signature. The app path is passed as an argument. |
| `package-candidate.sh` | Builds a release candidate; with `--release`, the official package: Release build, signing, ZIP archive, and verification of the archive and the unpacked copy. Installs nothing, publishes nothing, and does not write to Git. |
| `package-release.sh` | Calls `package-candidate.sh --release`. |
| `build-production.sh` | Builds a release-ready version: runs `verify-release.sh`, then `package-release.sh`, and places the `LacEditor-<version>-arm64.zip` archive and its `.sha256` checksum file in `dist`. At the end it prints the command that uploads both files to a GitHub Release. It takes the version from `VERSION` and does not change it; set a new version with `prepare-release.sh` first. |
| `package-experiment.sh` | Builds a separate experimental version, “LacEditor 实验版.app”, that does not replace the official one. |
| `prepare-release.sh` | Takes a new version such as `1.2.3`, requires an entry in `CHANGELOG.md`, checks that no such tag exists, changes `VERSION` and the version and build number in the project, and runs `verify-release.sh`. It does not create a commit or tag, but prints the commands for them. |
| `clean-build-artifacts.sh` | Shows the size of `.build`, `.swiftpm`, `build`, and `DerivedData`. Deletes them only with the `--confirm` argument and the exact project path. |
| `file-associations.sh` | Without arguments, lists the app copies registered as file handlers. `--unregister-build <path>` removes the registration of one build copy, `--clean` of all copies except the one installed in Applications. Default apps are not changed. |

## Technical direction

Since 0.14.0, LacEditor uses native macOS window tabs, supporting system drag, detach, and merge. Old workspaces are restored as native tab groups in their original order, retaining unsaved content, original file paths, and opening from Finder.

LacEditor uses SwiftUI for the interface, AppKit `NSTextView` for editing, TextKit for visible-area layout, and WebKit with `cmark-gfm` for local Markdown preview. File I/O, syntax scanning, find and replace, JSON, preview, and recovery remain separate components. Background tasks check the document revision so stale results cannot overwrite newer edits. The editor remains built on TextKit 1.

Directions for further optimization are listed in [NEXT_OPTIMIZATIONS.md](NEXT_OPTIMIZATIONS.md). Git, a plugin system, and cloud sync are not part of LacEditor's core plans.

## Contributing

Report problems or suggest improvements through [Issues](https://github.com/LKosoj/LacEditor/issues). Before submitting a feature change, describe the user scenario and run `swift test` and `./Scripts/run-acceptance.sh`.

See [VERSIONING.md](VERSIONING.md) for versioning, commit, and release rules, and [CHANGELOG.md](CHANGELOG.md) for the full change history.
