# U7 — Остальные потребители (U7.1–U7.5): экспорт, ссылки и метаданные, изображения и HTML, front matter, остатки

Статус: план (код не менялся), 06.11.2026. Номера строк — по рабочей копии на 06.11.2026 (перед правкой перепроверить `rg`).
Опора: главный план (решения 1, 2, 4, 5, 9; этап 7; U8.2), U2.2, U2.3, U2.5, U4, U5, правила `docs/agents/{export-and-preview,notes,vault,markdown-html-media}.md`.
`MarkdownDocumentParser*.swift` и `MarkdownPresentationParser.swift` сейчас правят другие агенты — здесь они только читались.

## 0. Что делаем простыми словами

После этапов 2–6 есть «модель документа» (`MarkdownDocumentModel`): один разбор, из которого берут всё нужное. Но десяток сервисов всё ещё зовёт
старый разбор редактора (`MarkdownPresentationParser.parse`) или сам читает дерево cmark (это библиотека разбора Markdown). U7 переводит их на модель.
Сервисы делятся на группы (группы идут параллельно, файлы не пересекаются):

- **U7.1 экспорт:** Pandoc, Fountain (сценарный формат), рукопись; `CustomMarkdownExportService` кода менять не требует.
- **U7.2 ссылки и метаданные:** поиск `[[ссылок]]`, обратные ссылки, переименование, теги, AI-инструменты, эмодзи, переход по ссылке-якорю.
- **U7.3 изображения и HTML:** самый тяжёлый кусок. Код «подтверждения HTML по дереву cmark» (около 1500 строк) не переписывается, а переезжает в файлы ядра:
  так он перестаёт быть «чужим» cmark-кодом вне нового слоя, а поведение остаётся прежним.
- **U7.4 front matter** (YAML-шапка файла): код уже ходит через `MarkdownFrontMatter`; задача — проверить, убрать дубли и перенести тесты.
- **U7.5 остатки:** `CriticMarkupRender`, `MarkdownObsidianComment`, `MarkdownCalloutRender`, `MarkdownNoteEmbed`, `CriticMarkupPandoc` после U4.4.

**Условие старта** (иначе U7 нельзя начинать): U4.4/U4.5 (нет `MarkdownRenderer`, копирование на модели), U6.4 (сервисы редактора на модели), есть
`MarkdownPresentationBuilder` (U5.1). Проверка в начале: `rg "MarkdownPresentationParser\." LacEditor` вне самого `MarkdownPresentationParser.swift`
должен показывать только потребителей из этого плана; помощники из списка решения 5 (`htmlSourceMatches`, `containerHTMLPrefixes`, `inlineHTMLPairs`,
`underlines`, `recoverLooseLists`, `fencedCodeBlock`, `alert`, `headingText`) уже обязаны жить в новом слое (сейчас `MarkdownDocumentParser.swift:505` ещё зовёт
`MarkdownPresentationParser.fencedCodeBlock`; `MarkdownMathExtension.swift:183` зовёт `recoverLooseLists`). Если что-то осталось — шаг U7.3.0 (п. 2.3) его переносит.

## 1. Карта текущего кода

Вызывающие `MarkdownPresentationParser.parse` и что они берут из результата:

| Файл:строка | Флаги разбора | Поля результата |
| --- | --- | --- |
| `Services/PandocExportService.swift:136` (`markedExportSnapshot`) → `markedMathSnapshot` 214 | эмодзи, wiki (если есть `wiki`) | `emojiCandidates`, `emojiCompletionRanges`, `wikiLinks`, `formulas`, `inlineFormulas`, `tableOfContents`, `spans` (маркер `heading`), `looseIndents` |
| `Services/ManuscriptService.swift:182` | — | `footnotes`, `links`, `spans` (`.link`, `markerRanges[1]`) |
| `Services/MarkdownWikiLinkExtractor.swift:8` | wiki | `wikiLinks` |
| `Services/MarkdownBacklinkScanner.swift:31`, `MarkdownRenameLinkService.swift:87` | wiki | `wikiLinks`, `links`, `spans` (хвост `](`) |
| `Services/MarkdownTagReader.swift:104` | эмодзи, wiki | `emojiCompletionRanges`, `links`, `wikiLinks` |
| `Services/AIAgentTools.swift:846`, `:869` | — / wiki | `headings`; `wikiLinks` |
| `Services/EmojiShortcodeResolver.swift:99` | эмодзи | `emojiCandidates` |
| `App/AppState.swift:5540` (переход по ссылке-якорю) | — | `headings`, `namedAnchors` |
| `Services/CriticMarkupRender.swift:94`, `Preview/MarkdownObsidianComment.swift:88` | — | `elements.excludedRanges` |
| `Preview/MarkdownNoteEmbed.swift:238`, `MarkdownCalloutRender.swift:154` | — | `elements.excludedRanges` (обе функции исчезают в U4.4) |

Свой cmark вне ядра: `FountainExportService.swift` (372–760, 2 импорта cmark), `MarkdownImageUploadService.swift` (`textareaContents` 368, `mediaSources` 401, `images` 626–880,
`imageIdentity` 884/`destinations` 902 — разбор одного фрагмента), `MarkdownHTMLMediaService.swift` (`centeredMarkdownImage` 312, `htmlBlockTagOffsets` 1031, `proven*` и `renderMarkedHTML` 1106–2020),
`MarkdownMathExtension.swift` (сам разбор; `recoverLooseLists` из старого парсера, стр. 183), `MarkdownTextSourceCapture.swift` (захват текста внутри расширения; на старый парсер уже не ссылается),
`MarkdownEmojiCandidateExtractor.swift` (обход дерева; строки 132–134 зовут `MarkdownPresentationParser.underlines/inlineHTMLPairs`).

Front matter: все потребители уже зовут `MarkdownFrontMatter.frontMatter` (`StoryCard` 115, `StoryCardHeaderEditor` 44, `VaultFrontmatterEditor` 139, `MindMapDocumentParser` 28, `StyleProseMask` 218, `MarkdownPDFExportService` 13,
`MarkdownImageEditingService` 82, `MarkdownNoteEmbed` 151, `MarkdownTagReader` 94, `Pandoc` 193/711, `CustomMarkdownExportService` 233/339, `Fountain` 94/305, `Manuscript` 165). Своего разбора шапки нигде нет,
кроме `VaultOwnerZone.looksCorrupted` (105): это текстовая проверка флага в шапке, не разбор границ — не трогаем. Строки `AppState` в этой группе нет: `AppState.swift:5540` — поиск заголовка (идёт в U7.2).
`maskedFrontMatter` зовут: `MarkdownImageUploadService` 371/404/869/903, тесты; после U4 и U2.6 других нет.

Поля модели, которых достаточно (проверено по `Models/MarkdownDocumentModel.swift`): `emoji.candidates/completionRanges`, `looseIndents`, `footnotes`, `namedAnchors`, `elements`,
узлы `.wikiLink`, `.link(form: inline/reference/autolink/html)`, `.formula`, `.tableOfContents`, `.heading` (title, level, range, markerRanges), `.footnoteDefinition`, `.mathBlock`, `HTMLBlock.literal`, `Image.addressRange/url/title/sizing`.
Готовых «плоских списков» (все wiki-ссылки, все ссылки, все заголовки) у модели нет — их надо написать (U7.0).

## 2. Задачи

### U7.0. Общие запросы к модели (делается первым, ~200 строк + тест ~200)

Новый файл `Preview/MarkdownDocumentQueries.swift` (без AppKit/cmark), расширение `MarkdownDocumentModel`:
- `wikiLinks: [MarkdownWikiLink]` — обход блоков и строчных узлов в порядке документа (`range`, `displayRange`, `target`, `heading`, `alias`, `markerRanges` берутся из узла; `![[…]]` не включается);
- `linkEntries: [(link: MarkdownLink, markers: [NSRange], form: Link.Form)]` — все `.link`, включая `<a href>` (`form == .html`); `markers[1]` — хвост `](…)`, как раньше в `spans` (`.link`, 2 маркера);
- `headings: [MarkdownHeading]` — заголовки в порядке документа без заголовков в таблицах, картинках и определениях сносок (то же правило, что у `headingIDs`); `title`, `level`, `range`;
- `formulas`/`inlineFormulas: [MarkdownFormula]`, `tableOfContentsRanges: [NSRange]`, `headingMarkerRanges` (первый маркер заголовка ATX);
- `MarkdownDocumentParser.parseOrEmpty(_ text, syntax:, includes:, isCancelled:) -> MarkdownDocumentModel` — оболочка над `parse(_:options:isCancelled:)`: при `nil` (отмена или сбой) возвращает пустую модель, как прежний `MarkdownPresentationParser.parse` возвращал пустую презентацию; вызывающий, как и раньше, сам проверяет `isCancelled()` (см. `MarkdownTagReader.read`, 107). Параметры: `isVaultNote: false`, `detectsFrontMatter: true`.
- Обходы проверяют `isCancelled` в циклах (правило `text-state-and-background.md`).

Если `MarkdownPresentationBuilder` (U5.1) уже содержит такой обход заголовков/ссылок — builder вызывает эти запросы, а не наоборот (двух копий нет).

Тест `LacEditorTests/MarkdownDocumentQueriesTests.swift`: на корпусе (`Fixtures/RenderBaseline/Corpus`, `MarkdownBaseline`) каждое поле запросов равно соответствующему полю `MarkdownPresentationBuilder.build(model)`
(`wikiLinks`, `links`, `headings`, `formulas`, `inlineFormulas`, `tableOfContents`, `emojiCandidates`, `emojiCompletionRanges`); каждое расхождение разбирается (ошибка или записанная причина — например, отсев показа
`blockedHTML`/`overlapsMedia` в builder, которого в запросах нет). Плюс малые случаи: кириллица, CJK, эмодзи, `\r\n`, `[[Цель#Заголовок|текст]]` в таблице/коде/ссылке, `<a href>`.

**U7.0 сделано (06.11.2026):** `Preview/MarkdownDocumentQueries.swift` — `model.queries(_:isCancelled:)` (один обход, собирает только запрошенное; `nil` при отмене) и свойства
`wikiLinks`, `linkEntries` (ссылка + маркеры + форма), `headings`, `formulas`, `inlineFormulas`, `tableOfContentsRanges`, `headingMarkerRanges`, плюс `queries(.emoji)` (`emojiCandidates`, `emojiCompletionRanges`)
и `MarkdownDocumentParser.parseOrEmpty`. Отсев `blockedHTML` и `overlapsMedia` сделан в запросах. Тест `MarkdownDocumentQueriesTests`: корпус (spec, ext, документы, LF и CRLF, два набора настроек) против builder.
Расхождений с builder на корпусе нет; записанные различия по замыслу: `wikiLinks` builder содержит ещё `![[…]]` (в запросах их нет, `isEmbed`), `headingMarkerRanges` — первый маркер (`# ` с пробелом) только у ATX,
двухмаркерные `.link`-спаны builder сверяются только вперёд (ссылки в таблицах в спанах не бывают, в `links` и `linkEntries` есть). Корпус не содержит `<a href>` — он покрыт малым тестом.
Двойной обход убран частично: builder вызывает общий `MarkdownWikiLink(node:)`, сам его обход остаётся (он единый с остальным оформлением, второй проход на каждый ввод не нужен). Старый `MarkdownDocumentModel.wikiLinks`
из `MarkdownDocumentParser+Extras.swift` (обход без отсева, его никто кроме одного теста не звал) удалён — его заменяет новое свойство.

**Правило для потребителей U7.1–U7.2:** каждое свойство модели (`model.wikiLinks`, `model.headings` и т. д.) — отдельный полный обход. Нужно больше одного поля — один раз `model.queries([.links, .headings, …])` и брать поля результата. `LinkEntry.markers` непусты только у `[текст](адрес)` (`form == .inline`).
Правила отбора узлов (`LinkEntry(node:)`, `MarkdownFormula(node:/block:)`, `MarkdownHeading(block:)`, `isMediaFrame`, `MarkdownSortedRanges`) общие с builder и лежат в `MarkdownDocumentQueries.swift`.

### U7.1. Экспорт

**U7.1.a `PandocExportService.swift`** (1452 строки — читать только 130–270, 340–350, 440–460, 495–590):
- `markedExportSnapshot` (136): разбор → `MarkdownDocumentParser.parseOrEmpty(text, syntax:, includes: [.emoji, .editorContext] + (wiki != nil ? [.wikiLinks] : []))`; поля берутся из запросов U7.0 и модели (`emoji.candidates`, `emoji.completionRanges`, `wikiLinks`, `formulas`, `tableOfContentsRanges`, `headingMarkerRanges`, `looseIndents`). Цикл по `presentation.spans` (156–164) заменяется на `headingMarkerRanges` — условие «`#` без пробела после» остаётся тем же.
- `markedMathSnapshot(_:presentation:…)` (214): параметр `presentation: MarkdownPresentation` → `model: MarkdownDocumentModel` (внутренний API; единственный прямой вызов в тесте — `PandocExportTests.swift:26`, правится вместе). Вызывающие 186 и тест — в той же подзадаче.
- Строки 193/711 (`MarkdownFrontMatter`) и 983/1193 (`MarkdownObsidianComment.removed(_:syntax:)`) не меняются: сигнатура `removed` сохраняется (U7.5).
- Не на стенде `lac-writer-check` (Pandoc там не собирается): проверка только `swiftc -frontend -parse`; на Mac — `PandocExportTests`.
**U7.1.b `CustomMarkdownExportService.swift`:** кода не меняет (зовёт `markedExportSnapshot` с прежней сигнатурой, `MarkdownFrontMatter`, `MarkdownObsidianComment.removed`). Подзадача — только проверка `rg` и отметка в статусе.
**U7.1.c `FountainExportService.swift`** (889 строк; диапазон 372–760 + импорты; оглавление — `rg -n "func |case \""`):
- Обход cmark (`visitBlock`, `visitChildren`, `codeBlock`, `listLines`, `tableLines`, `inline`, `plain`, `flat`, `inlineChildren`, `typeName/literalOf`) переписывается на обход узлов модели. Соответствие: `heading`→`.heading` (+`inlines`), `paragraph`, `thematic_break`→`.thematicBreak`, `block_quote`→`.quote` (дети), `list/item`→`.list/.listItem` (`ListBlock.marker`, `ordinal`, `task` — вместо `cmark_gfm_extensions_get_tasklist_item_checked`; `state != 32`), `code_block`→`.codeBlock(literal)`, формула→`.mathBlock(source)`/`.formula(source)`, `html_block`→`.html(HTMLBlock.literal)` (литерал берётся для всех видов `Kind`), `table`→`.table` (`rows[].cells[].inlines`), `softbreak/linebreak/emph/strong/strikethrough/link/image/html_inline/footnote_reference` → одноимённые узлы (`Link.url`, `Image.url/alt`, `.rawHTML(String)`, `.footnoteReference(label)` + определение — блок `.footnoteDefinition(label)` по метке).
- Тонкости: `plain(node)` склеивает литералы `text/code/code_block` и пробелы между абзацами — на модели это обход `children/inlines`; `cmark_node_parent_footnote_def` заменяется поиском блока по метке (словарь метка → блок строится один раз на `pieces(from:)`).
- Параметры разбора сохраняются: сегодня **нет** `SMART` и `HARDBREAKS` (`TABLE_SPANS | FOOTNOTES`), а ядро включает `SMART`, если `syntax.smartPunctuation ?? true`. Чтобы не менять кавычки сценария, разбор идёт с копией `MarkdownSyntaxOptions` с `smartPunctuation: false` (все остальные поля скопировать через `init`). Тест на «прямые кавычки не превращаются в «ёлочки»» обязателен.
- `prepareCritic` (до разбора) и `CriticMarkupRender.items` остаются (U7.5); `includes: []` (ни wiki, ни critic, ни эмодзи: `[[…]]` остаются текстом, их обрабатывает `finalize`/`fixBrackets` Fountain).
- Резерв при `nil` модели: прежняя ветка `parsed == nil` (строки как абзацы).
- Удаляются `import cmark_gfm`, `cmark_gfm_extensions`, `mathExtension`, `inlineMath`.
- Стенд `lac-writer-check`: `FountainExportTests` (39 тестов) должны пройти без правки ожиданий.
**U7.1.c сделано (06.11.2026):** обход переписан на узлы `MarkdownDocumentModel`; разбор через `MarkdownDocumentParser.parse` (не `parseOrEmpty`: нужны `detectsFrontMatter: false` и ветка `nil`), `smartPunctuation: false`; в `FountainExportService.swift` нет `cmark`; `FountainExportTests` на стенде проходят (добавлен тест кавычек/CRLF/задач/сносок/формул/CJK-таблицы). Отличия от прежнего поведения (решение 1, оставлены): (1) выноска `> [!note] Заголовок\n> текст` даёт два абзаца (заголовок и текст) вместо одного, маркер `[!тип]` убран; (2) `ruby/media/iframe/svg` дают одно предупреждение html на группу вместо по одному на тег, текст внутри `<video>`/`<svg><text>` отбрасывается (у `ruby` остаются основа и чтение); (3) `$$…$$` в пункте списка больше не считается `.codeBlock` (теперь формула); (4) метку ссылки на сноску даёт ядро (`cmark_node_parent_footnote_def` → срез `[^…]` при надёжном диапазоне → литерал), Fountain ищет определение через `MarkdownHTMLRenderer.footnoteKey`; (5) `decoratedText` снимает `\\`-экранирование и сущности (только `&имя;`/`&#…;`, как cmark) у детей `==…==`/`^…^`, потому что они хранят сырой исходник. `.highlight`/`.superscriptText` достижимы и при `includes: []` (декорации не зависят от includes), ветки оставлены. Тесты добавлены в `FountainExportTests` (39 на стенде) и `MarkdownDocumentParserTests`.
**U7.1.d `ManuscriptService.swift`** (389): `prepare` (182) — `parseOrEmpty(includes: [])`; `presentation.footnotes` → `model.footnotes` (поле `definitionRange` то же); `presentation.links`+`spans` (222–245) → `linkEntries`; `parsedLinkStarts` — по `linkEntries.map(\.link.range.location)`. `MarkdownImageUploadService.images(in:)` (217) не меняется (сигнатура сохраняется, внутри U7.3).

Порядок/параллельность U7.1: a ‖ c ‖ d — разные файлы; все ждут U7.0 (кроме c, которому запросы не нужны: он сразу идёт после старта). Размер: a ~120 строк правок, c ~350, d ~40. c — подзадача 300–800 строк, один исполнитель.

### U7.2. Ссылки и метаданные (все ждут U7.0; файлы разные — параллельно)

- `MarkdownWikiLinkExtractor.links(in:syntax:isCancelled:)` (6–9): `parseOrEmpty(includes: [.wikiLinks]).wikiLinks`. Вторая функция `links(textRanges:excluded:text:)` и `targetRange(of:in:)` остаются (их зовёт ядро, U2.3/U2.2) — физически это распознаватель ядра; в U8.2 разрешён. Прежние вызовы `VaultLinks.swift:33`, `MindMapController.swift:476` не меняются.
- `MarkdownBacklinkScanner.ranges` (31): `wikiLinks` и `linkEntries` (все формы, как раньше `presentation.links`).
- `MarkdownRenameLinkService.edits` (87): `wikiLinks`; словарь `tails` (`range → markers[1]`) строится из `linkEntries` для `form == .inline` с двумя маркерами (как раньше `spans` `.link` + 2 маркера).
- `MarkdownTagReader.read` (104): `includes: [.emoji, .wikiLinks]`; `textRanges: model.emoji?.completionRanges ?? []`, `excluding: linkEntries.map(\.link.range) + wikiLinks.map(\.range)`. Оболочку `withoutActuallyEscaping` оставить, как есть.
- `AIAgentTools.outline` (846): `headings` (`level`, `title`, `range.location`); `links` (869): `wikiLinks`.
- `EmojiShortcodeResolver.prepareMarkdown` (99): `includes: [.emoji]`, `emoji?.candidates`.
- `AppState.swift:5540`: `headings` + `namedAnchors` из модели (`MarkdownHeadingAnchors.target(for:in:)` берёт `[MarkdownHeading]` — подходит без изменений).
- `MarkdownEmojiCandidateExtractor`: остаётся обходом дерева внутри ядра (его зовёт `MarkdownDocumentParser`, U2.5); правится только 132–134 (`MarkdownPresentationParser.underlines/inlineHTMLPairs` → новое место, п. 0). Файл остаётся в `Services/`; в U8.2 он в списке ядра (п. 4). Перенос в `Preview/` — по желанию основного агента (спорное 4).
- Тесты: `MarkdownWikiLinkTests`, `MarkdownBacklinksTests`, `MarkdownRenameLinkTests`, `MarkdownTagReaderTests`, `MarkdownInlineTagTests`, `EmojiShortcodeResolverTests`, `AIAgentToolsTests`, `MarkdownEmojiCandidateExtractorTests` — ожидания не меняются; правятся только прямые вызовы `MarkdownPresentationParser.parse` (в 6 файлах; 3 точки в `MarkdownWikiLinkTests/Backlinks/Rename`).
- Стенд `lac-writer-check`: все перечисленные тесты уже в `test-files.txt`.

**U7.2 сделано (06.11.2026):** на модель переведены `MarkdownWikiLinkExtractor.links`, `MarkdownBacklinkScanner.ranges`, `MarkdownRenameLinkService.edits` (хвосты `tails` из `linkEntries` с `form == .inline` и двумя маркерами),
`MarkdownTagReader.read`, `AIAgentTools.outline/links`, `EmojiShortcodeResolver.prepareMarkdown`, `AppState` (переход по ссылке-якорю: `headings` + `namedAnchors` из модели). Где нужно больше одного поля — один `queries([...])`.
`MarkdownDocumentParser.underlines/underline` (подчёркивание `<u>`) перенесены в `MarkdownDocumentParser+HTML.swift`; `MarkdownEmojiCandidateExtractor` зовёт их. Из `MarkdownPresentationParser` удалены, его разбор зовёт `MarkdownDocumentParser.underlines`.
Тесты: ожидания не менялись; правка только в `MarkdownWikiLinkTests` (прямой вызов старого разбора). Тесты эмодзи-извлекателя проверяют слой оформления (`replacingTable`, таблицы) и остаются на `MarkdownPresentationParser` до U5/U8.1.

### U7.3. Изображения и HTML

Принцип: «подтверждение HTML по дереву» (`proven*`, `HTMLContext`, `images(root:)`) — это и есть логика ядра (его зовёт `MarkdownDocumentParser`). Поэтому код **переезжает** в файлы ядра без изменения поведения, а публичные функции сервисов остаются тонкими оболочками. Переписывание `images(in:)` на узлы модели не делаем: у `MarkdownImageUploadService.Image` больше полей (`rawAddress`, `InlineReference`, `htmlXML`, кавычка атрибута), 93 теста, высокий риск (спорное 1).
- **U7.3.0** (при необходимости): перенести недостающие помощники из `MarkdownPresentationParser.swift` в новый слой — `recoverLooseLists` (13–~260) в `MarkdownMathExtension.swift` (обращение 183 становится локальным), `htmlSourceMatches` (3430), `containerHTMLPrefixes` (264) — туда, куда их положил U2.3/U2.5; имена вызовов в трёх сервисах переименовываются в той же задаче.
- **U7.3.a `MarkdownHTMLMediaService.swift`** (2405 строк; читать диапазонами): функции с `OpaquePointer`/cmark — `htmlBlockTagOffsets` (1031), `provenTextStyles/…/provenImageIndices`, `renderMarkedHTML`, типы-помощники 1074–1101, 1391, 1631, 1704, 1857 — переезжают в новый `Preview/MarkdownHTMLProof.swift` (`enum MarkdownHTMLProof`, ~1000 строк, механический перенос; разумно отдать `code-generator`, но решения принимаются заранее: порядок и имена не меняются). Вызовы переименовываются: ядро, `MarkdownPresentationParser.swift` (9 мест 2671–2838 — пока файл жив), `MarkdownHTMLMediaServiceTests`. В сервисе остаются чисто строковые/SwiftSoup-части (`exportBlock`, `iframeHTML`, `audioSource`…). `centeredMarkdownImage` (312–342): вместо `withDocument` + `cmark_node_*` — `parseOrEmpty(inner, includes: [])`, единственный абзац с единственным `.image` (`url`, `alt`, `title`, `addressRange`); условие «вокруг только пробелы» по `range` узла. Тест `MarkdownHTMLMediaServiceTests` (центрированная картинка) — ожидания прежние.
- **U7.3.b `MarkdownImageUploadService.swift`** (1903): `textareaContents` (368–398), `mediaSources` (401–522), `images` (626–880: обход `visit` и `process`) переезжают в `Preview/MarkdownHTMLConfirmation.swift` (`enum MarkdownHTMLConfirmation`, ~450 строк); в сервисе остаются оболочки с прежними сигнатурами и параметрами (`images(in:selection:allowSharedReference:isCancelled:htmlForExport:…)`) — **параметры `confirmed*`, `root:`, `sourceMapping:` остаются** (их использует ядро, U2.3c; у приложения других потребителей после U4 нет). `HTMLContext`, `Image`, `htmlImages`, `resolveReferences` и прочие строковые функции остаются в сервисе: они не читают дерево. `imageIdentity` (884) и `destinations` (902) разбирают одну картинку: заменить на `parseOrEmpty` + первый абзац → `.image` (`url`, `title`); `maskedFrontMatter` в 4 местах уходит вместе с переездом (разбор `withDocument` внутри `MarkdownHTMLConfirmation` остаётся на `maskedFrontMatter` — единственный оставшийся вызов, п. U7.4).
- **U7.3.c `MarkdownTextSourceCapture.swift`:** только проверка — он зовёт `MarkdownSourcePositions` и cmark внутри расширения; правок нет, кроме возможных комментариев про старый парсер.
- **U7.3.d `MarkdownMathExtension.swift`:** `recoverLooseLists` (см. 0); больше ссылок на `MarkdownPresentationParser` нет.
Параллельность: a ‖ b ‖ d (файлы `MarkdownHTMLMediaService`+`MarkdownHTMLProof`, `MarkdownImageUploadService`+`MarkdownHTMLConfirmation`, `MarkdownMathExtension`); b использует `htmlSourceMatches`/`containerHTMLPrefixes` — после 0. Общие файлы (pbxproj, `Package.swift`, стенды) правит основной агент: новые файлы `MarkdownHTMLProof.swift`, `MarkdownHTMLConfirmation.swift`, `MarkdownDocumentQueries.swift`.
Стенд: `keep-/drop-MarkdownImageUploadService.swift.txt`, `drop-MarkdownHTMLMediaService.swift.txt` фильтруют эти сервисы (`gen_trim.py`); после переезда списки правит основной агент: добавить новые файлы в `lib-files.txt`, перенести имена функций из drop-списков в новые файлы (иначе стенд не соберётся).

**Уточнение U7.3 (06.11.2026, по текущему коду).** `MarkdownHTMLMediaService.swift` лежит в `Services/` (2468 строк). `htmlSourceMatches`/`containerHTMLPrefixes` уже в `MarkdownDocumentParser+HTML.swift`, копий `proven*` в ядре нет. Решения:
- Всё с cmark переезжает как есть, без перевода на модель: `proven*`, кандидаты, `htmlBlockTagOffsets(_ node:)`, `renderMarkedHTML`, `renderedInlineMediaHTML` и cmark-часть `centeredMarkdownImage` → `MarkdownHTMLProof`; `textareaContents`, `mediaSources`, сборщик `images` (630–870), `imageIdentity`, `destinations` → `MarkdownHTMLConfirmation`. Перевод на модель менял бы поведение (alt с разметкой, обход таблиц и сносок) и добавлял полные разборы на каждую замену.
- `htmlBlockTagOffsets(literal:)` и строковые функции остаются в сервисе.
- Параметры `images(in:)` (`confirmed*`, `root:`, `sourceMapping:`) не меняются.
- `fencePrefixes` и `confirmedNamedAnchors` остаются в `MarkdownPresentationParser.swift` до U8.1 (их перенос — часть удаления файла).
- Деление: A = `MarkdownHTMLMediaService` + `MarkdownHTMLProof` + `recoverLooseLists` (U7.3.0/d) + переименования в `MarkdownDocumentParser+HTML.swift`, `MarkdownPresentationParser.swift`, `MarkdownClipboardProjector+Inlines.swift` и тестах; B = `MarkdownImageUploadService` + `MarkdownHTMLConfirmation`. A ‖ B.
- Списки `keep-/drop-*.txt` и `gen_trim.py` стенда устарели; стенд берёт сервисы через `extract_specs.py`/`gen_extract.py`.

**U7.3.a/d сделано (06.11.2026).**
- `Preview/MarkdownHTMLProof.swift` (`enum MarkdownHTMLProof`, 691 строка): из `Services/MarkdownHTMLMediaService.swift` (2468 → 1783 строки) перенесены без изменения тел и порядка `HTMLBlockCandidate`, `htmlBlockTagOffsets(_ node:)`, `ImageProofCandidate`, `TextProofCandidate`, `TextContainerCandidate`, `TextStyleCandidate`, `provenTextStyles`, `provenTextAndContainers`, `MediaProofCandidate`, `provenStandaloneMedia`, `provenMediaIndices`, `renderMarkedHTML`, `renderedInlineMediaHTML`, `SVGProofCandidate`, `provenSVG`, `RubyProofCandidate`, `provenRuby`, `provenDetails`, `TwitterProofCandidate`, `provenHTMLBlocks`, `provenTwitter`, `provenPageBreaks`, `provenImageIndices` и `centeredMarkdownImage` целиком (её звали только изнутри сервиса — оболочка не нужна; вызов в `exportBlock` идёт через `MarkdownHTMLProof.`). Старое место удалено, `import cmark_gfm` из сервиса убран.
- Изменены только квалификаторы и доступ: типы без указателей (`ProvenText`, `ProvenMedia`, `StandaloneMedia`, `TwitterWidget`, `ImageAncestor`) и строковые функции (`provenText`, `standaloneMedia`, `insertingMarkers`, `plainDetails`, `twitterWidget`, `confirmedImageMarkers`, `htmlBlockTagOffsets(literal:)`) остались в сервисе и в `MarkdownHTMLProof` вызываются как `MarkdownHTMLMediaService.X`; `mediaElementMatches` и `isPageBreakStyle` в сервисе из `private` стали internal; `renderMarkedHTML` в `MarkdownHTMLProof` остаётся `private`, `centeredMarkdownImage` — internal.
- U7.3.d: `recoverLooseLists` (148 строк) из `MarkdownPresentationParser.swift` (2140 → 1991) перенесён в `MarkdownMathExtension.swift` как `private static`, вызов без префикса. `fencePrefixes` и `confirmedNamedAnchors` остались.
- Вызовы переименованы в `MarkdownDocumentParser+HTML.swift`, `MarkdownPresentationParser.swift`, `MarkdownClipboardProjector+Inlines.swift`, `MarkdownHTMLMediaServiceTests.swift`, `MarkdownClipboardProjectionInlinesTests.swift`.
- Стенды: `lac-writer-check` — `Preview/MarkdownHTMLProof.swift` в `lib-files.txt`, мёртвый патч `withDocument(inner…)` убран из `extract_specs.py`; `MarkdownHTMLMediaServiceTests` в стенд не добавлен (AppKit: `exportFragments`, `videoInsertion`, `NSApplication`). `lac-check` — ссылка на `MarkdownHTMLProof.swift`, копия сервиса пересоздана `gen_trim.py`, патч в `gen_trim.py` убран.

**U7.3.b сделано (06.11.2026).**
- `Preview/MarkdownHTMLConfirmation.swift` (`enum MarkdownHTMLConfirmation`, 453 строки): из `Services/MarkdownImageUploadService.swift` (минус ~408 строк) перенесены без изменения тел `textareaContents`, `mediaSources`, сборщик `images` (разбор `lines`, `visit`, `process` и их состояние; возвращает `(found, references)`), `imageIdentity`, `destinations`.
- В сервисе остались оболочки с прежними сигнатурами (у `images(in:)` — все параметры и значения по умолчанию, проверка нуля и `selection`, `resolveReferences`, сортировка) и строковые функции. `htmlImages`, `htmlImage`, `referenceLabel`, `normalizeHTMLReferences`, `decodeHTMLReferences` стали internal (их зовёт новый файл). Импорт cmark в сервисе остаётся для `decodeHTMLReferences` (`cmark_strbuf`, не дерево).
- Внешние вызывающие не менялись. Стенд: `Preview/MarkdownHTMLConfirmation.swift` в `lib-files.txt`.

### U7.4. Front matter (без полного разбора)

1. `rg "MarkdownFrontMatter\.|maskedFrontMatter|hasPrefix\(\"---"` — составить финальный список вызывающих (п. 1); новых собственных разборов нет; результат — в статус задачи.
2. Убедиться, что `MarkdownSourceMask` (52, 418) и `MarkdownDocumentModel.frontMatter` берут границы из `MarkdownFrontMatter.frontMatter` (одна функция границ).
3. `maskedFrontMatter` (маскировка пробелами по байтам) нужна только `MarkdownHTMLConfirmation` (U7.3.b) и тесту `MarkdownReadableTextTests:28`; если после U8 вызывающих нет — удалить (спорное 3).
4. Перенести тесты границ шапки (`MarkdownPresentationParserTests.swift` 1528–1566: граничные случаи `---`/`...`, BOM, `---\n---`, закрытие, маскировка) в новый `LacEditorTests/MarkdownFrontMatterTests.swift` (иначе они пропадут при U8.1); добавить по одному тесту потребителей на `\r\n`, BOM и кириллицу: `StoryCard`, `StoryCardHeaderEditor`, `VaultFrontmatterEditor`, `MindMapDocumentParser`, `StyleProseMask` — если такого теста нет (по `rg`).
5. Код потребителей менять не нужно; единственная правка — комментарий `VaultFrontmatterEditor.swift:71`, если ссылка на разбор устарела.

### U7.5. Остатки

После U4.4 (удалены `CriticMarkupRender.prepare/finalize`, `MarkdownObsidianComment.hidden`, `MarkdownNoteEmbed.prepare/finalize`, `separatingTitles/transform`) остаются вызовы старого разбора только в трёх функциях:
- `CriticMarkupRender.items(in:syntax:)` (94) и `MarkdownObsidianComment.commentRanges(in:syntax:)` (88): `parseOrEmpty(includes: [.elementIndex])` → `model.elements` → `excludedRanges(intersecting:)` → `CriticMarkupService.items(in:excluded:)` / `ranges(in:excluded:)`. Сигнатуры не меняются, поэтому `CriticMarkupPandoc`, `FountainExportService`, `PandocExportService` (983/1193), `CustomMarkdownExportService` (199) кода не меняют. Условие `index.textLength == length` сохраняется.
- Проверить, что `parseOrEmpty` здесь **не** включает `.criticMarkup` и не ставит `isVaultNote` (иначе маска зациклит распознавание на себя).
- Подчистить остатки после U4.4 по `rg`: приватные помощники (`Markers`, `Kind`, `freeBase`, `lineBreaks`, `Prepared`), мёртвые константы, `MarkdownNoteEmbed.Prepared`. Остаётся: типы режимов и стилей, `mayContain*`, `items`, `resolved`, `commentLabel` (если зовёт HTML-адаптер), `removed`, `marker`/`MarkdownCalloutKind`, провайдеры, `fileReplacement` (если нужен адаптеру), `afterPrefix/isBlankLine/isInsideParagraph` (зовёт маска).
- `rg` на вторую копию распознавателей в `MarkdownSourceMask.swift` (должна быть вызовом, не копией).
Размер: ~40 строк правок + чистка.

## 3. Тесты

| Что | Действие |
| --- | --- |
| `MarkdownDocumentQueriesTests` (новый) | запросы U7.0 = поля builder на корпусе + малые случаи (кириллица/CJK/эмодзи/`\r\n`) |
| `FountainExportTests` (39) | ожидания не меняются; добавить: прямые кавычки, `\r\n`, сноска с кириллицей, задача `[x]`, формула, таблица с CJK |
| `PandocExportTests` | правка вызова `markedMathSnapshot` (26); новые тесты не нужны — эмодзи/wiki/формулы/TOC/loose уже покрыты (`MarkdownMathExtensionTests`, `MarkdownWikiLinkRewriterTests` вызывают `markedExportSnapshot`) |
| `MarkdownWikiLinkTests`, `MarkdownBacklinksTests`, `MarkdownRenameLinkTests`, `MarkdownTagReaderTests`, `MarkdownInlineTagTests`, `EmojiShortcodeResolverTests`, `AIAgentToolsTests`, `ManuscriptServiceTests` | без изменения ожиданий; переводятся прямые вызовы старого разбора |
| `MarkdownImageUploadTests` (93), `MarkdownHTMLMediaServiceTests`, `MarkdownInlineHTMLTests`, `MarkdownMathExtensionTests` | ожидания не меняются; правятся имена `MarkdownHTMLProof.proven*`/`MarkdownHTMLConfirmation` |
| `MarkdownFrontMatterTests` (новый) | перенос тестов шапки из `MarkdownPresentationParserTests`; потребители на BOM/`\r\n`/кириллице |
| `CriticMarkup*Tests`, `MarkdownObsidianCommentTests`, `MarkdownNoteEmbed*Tests`, `MarkdownCallout*Tests` | переводятся в U4.4; в U7.5 добавить один тест на `items(in:syntax:)`/`commentRanges` с кодовым блоком и таблицей (`{++ ++}` и `%%` внутри не находятся) |

Тест-данные везде минимальные, но настоящие; позиции в UTF-16. Новые тесты — в `LacEditorTests/`, дописать в `test-files.txt`; в `docs/TEST_STATUS.md` отметить «на Mac не запускались» (делает основной агент).

## 4. Проверки

1. Каждый изменённый `.swift`: `swiftc -frontend -parse`. `PandocExportService`, `AIAgentTools`, `AppState`: только `-parse` (AppKit/Yams нет на Linux).
2. `lac-writer-check/run-tests.sh`: Fountain, Manuscript, WikiLink/Backlinks/Rename/TagReader/Emoji/AIAgentTools, `MarkdownDocumentQueriesTests`, `MarkdownFrontMatterTests`, `MarkdownImageUploadTests`/`MarkdownHTMLMediaServiceTests` (в части, которая собирается на стенде; фильтры `keep/drop` обновить).
3. `lac-check` — не затрагивается (сдвиг оформления).
4. Критерий «готово»: `rg -l "import cmark_gfm" LacEditor` даёт только список ядра: `Preview/MarkdownDocumentParser*.swift`, `MarkdownMathExtension`, `MarkdownSourcePositions`, `MarkdownTextSourceCapture`, `MarkdownEmojiCandidateExtractor`, `MarkdownHTMLProof`, `MarkdownHTMLConfirmation`, `MarkdownDocumentExtras`; `rg "MarkdownPresentationParser" LacEditor` — только сам старый файл (его удаляет U8.1); `git diff --check`.
5. На Linux не проверить: Pandoc с настоящим pandoc, сетевая загрузка/PicGo, WebKit; на Mac — `PandocExportTests`, `MarkdownImageUploadTests`, `FountainExportTests`, экспорт рукописи через интерфейс.

## 5. Риски

- **Отсев показа.** Старые `emojiCandidates`/`wikiLinks`/`formulas` были отфильтрованы редакторским `blockedHTML`/`overlapsMedia`; плоские запросы модели — нет. Влияет на редкие случаи (эмодзи/ссылка внутри неподтверждённого HTML или медиа). Тест U7.0 покажет, каждое расхождение — решение.
- **Fountain.** Разные настройки cmark (`SMART` выключен), текстовые узлы и сноски; ловит `FountainExportTests` на стенде.
- **Размер U7.3.** Перенос ~1500 строк: ошибки в копировании; смягчение — механический перенос без правок, сравнение `git diff --stat`/построчная сверка, прогон 93+ тестов. Старый парсер и ядро одновременно переименовывают вызовы — конфликт с параллельными агентами; делать после того, как они закончили.
- **Стенд.** `gen_trim.py` и списки `keep/drop` привязаны к именам функций в сервисах: после переезда стенд не соберётся, пока основной агент не обновит списки.
- **Pandoc/ImageUpload не собираются на Linux полностью** — риск ошибок типов остаётся до Mac.
- **Нет второго разбора на тот же текст:** Pandoc разбирает дважды (critic-исходник → снимок) — как сейчас; объединять не предлагается.

## 6. Спорные решения (для утверждения)

1. **U7.3: перенести или переписать.** Рекомендация — перенести код обхода cmark (`proven*`, `images(root:)`, `textareaContents`, `mediaSources`) в файлы ядра без изменения поведения; публичные функции сервисов остаются оболочками. Альтернатива — переписать на узлы модели (чище, но 93 теста, больше полей у `Image`, риск расхождений в HTML-контексте). Согласны ли считать перенос выполнением «свой cmark удаляется»?
2. **Плоские запросы к модели (U7.0) против `MarkdownPresentationBuilder`.** Рекомендация — запросы (дёшево для сканирования папок, без построения spans/таблиц), сверка с builder тестом. Альтернатива — зовать builder и читать поля `MarkdownPresentation` как раньше (меньше правок, нулевой дрейф поведения, но дороже и тянет «слой редактора» в сервисы).
3. **`maskedFrontMatter`.** Оставить, пока им пользуется `MarkdownHTMLConfirmation`, или заменить маску ядра (`MarkdownSourceMask`) и удалить? Рекомендация — оставить как единственный вызов, закрыть в U8.
4. **Расположение файлов ядра:** `MarkdownEmojiCandidateExtractor` оставить в `Services/` (с занесением в список ядра U8.2) или перенести в `Preview/` (нужны правки pbxproj/стенда — основной агент). Рекомендация — оставить.
5. **U7.5: исключаемые зоны** для `CriticMarkupRender.items`/`commentRanges` — брать из `elements` модели (поведение прежнее; полный разбор на вызов) или из лёгкого прохода `MarkdownSourceMask` (без cmark, быстрее, но зависит от точности оценки зон, риск 1 в U2.2). Рекомендация — `elements` модели.
6. **Fountain: `smartPunctuation: false`** — сохраняем прямые кавычки сценария (текущее поведение) вопреки умолчанию ядра. Подтвердить.
7. **`parseOrEmpty`** (пустая модель при отмене/сбое) вместо опционального результата — единый контракт для сервисов; вызывающий сам проверяет отмену, как сегодня.
8. **Порядок:** U7.3.a/b (перенос) делать после U8-совместимых переименований параллельных агентов или до? Рекомендация — после окончания работы над `MarkdownDocumentParser*.swift` и `MarkdownPresentationParser.swift`, чтобы не получить конфликт.

## Решения основного агента

1. U7.3: код подтверждения HTML переезжает в файлы ядра и выполняется внутри единственного разбора ядра (решение 7); свой `cmark_parser_*` в сервисах удаляется. Если код совпадает с перенесённым в U2.3c (`MarkdownDocumentParser+HTML.swift`) — используется он, второй копии нет. Переписывание `MarkdownImageUploadTests` — только там, где меняется API.
2. U7.0: плоские запросы к модели + тест сверки с builder. Отсев `blockedHTML` и `overlapsMedia` делается в запросах там, где его делали старые поля редактора (сверка это проверяет).
3. `maskedFrontMatter` остаётся единственным вызовом и закрывается в U8.
4. `MarkdownEmojiCandidateExtractor` остаётся в `Services/`.
5. U7.5: зоны исключения — из `elements` модели.
6. Fountain разбирается с `smartPunctuation: false` (поведение сценария не меняется).
7. `parseOrEmpty` — единый контракт для потребителей без отмены.
8. U7.3.a/b начинаются после завершения U2.3–U2.6 (файлы ядра свободны).

**U7.1.a/b/d сделано (06.11.2026):** `PandocExportService.markedExportSnapshot` — `parseOrEmpty(includes: [.emoji, .editorContext] (+ .wikiLinks))` и один `model.queries()`; `headingMarkerRanges` вместо цикла по spans, `model.looseIndents`. `markedMathSnapshot` принимает `queries: MarkdownDocumentQueries` (а не `model`: так обход не повторяется; тест `PandocExportTests:26` правлен). `CustomMarkdownExportService` — проверен, кода не меняет. `ManuscriptService.prepare` — `parseOrEmpty(includes: [])`, `model.footnotes`, один `queries(.links)`; хвосты `](…)` — из `linkEntries` с `form == .inline`, `<a href>` (`form == .html`) пропускается, как раньше с хвостом `</a>`.

**Отличия U7.1.d (ревью, решение 1 — верен cmark):** (1) `model.footnotes` больше не фильтруется по `blockedHTML` (старый `MarkdownPresentationParser.swift:3417`): на входе `<span style="bad">\n\n[^1]: заметка` метка `1` теперь участвует в переименовании сносок рукописи. (2) Ссылка с пустым текстом `[](images/a.md)` теперь переписывается (раньше считалась «не удалось», `unconvertedAddresses`); тест `ManuscriptServiceTests.testEmptyTextLinkAddressIsConverted`.

## Статус U7.4 и U7.5

U7.4 и U7.5 сделано (06.11.2026): границы шапки берут `MarkdownSourceMask` и модель из `MarkdownFrontMatter.frontMatter` (одна функция); тесты границ перенесены в `LacEditorTests/MarkdownFrontMatterTests.swift`; `CriticMarkupRender.items(in:syntax:)` и `MarkdownObsidianComment.commentRanges(in:syntax:)` берут зоны из `parseOrEmpty(includes: [.elementIndex]).elements` (без `.criticMarkup` и `isVaultNote`). Остатков после U4.4 в `CriticMarkupRender`, `MarkdownObsidianComment`, `MarkdownNoteEmbed` не найдено; `MarkdownSourceMask` вызывает `CriticMarkupService`/`MarkdownObsidianComment.ranges`, второй копии распознавателей нет. На Mac не запускалось.
