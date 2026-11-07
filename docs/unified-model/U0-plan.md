# План задач U0.1, U0.2, U0.3 (этап 0: эталоны и сверка со спецификацией)

Составлен 2026-11-05 по чтению кода. Код приложения не менялся. Родительский план: `docs/markdown-unified-model-plan.md`.

## 0. Расхождения с главным планом (решить до начала)

1. **Корпус.** В плане «716 примеров GFM». Фактически `spec.txt` = 672 примера, `extensions.txt` = 30 (из них 2 `example disabled`), всего 702. Число 716 нигде в коде не подтверждается; в тестах и документах использовать 672 + 30.
2. **Режимы CriticMarkup** в коде называются `.show`, `.result`, `.original` (`LacEditor/Services/CriticMarkupRender.swift:4-8`), а не `show/accept/reject`.
3. **Нужен третий список в U0.3.** Главный план знает «ошибку» (чинится на этапе 3) и «намеренное расширение», но тест на стенде должен проходить уже сейчас. Поэтому в тесте два списка: `intentionalExtensions` (навсегда, с причиной и правилом из `docs/agents/`) и `knownDefects` (временный, с пометкой `fixIn: "U3.1"`; на этапе 3 пустеет). Согласовать с основным агентом.
4. **`GFMSpecCorpus`** (разбор spec.txt) сейчас лежит в `LacEditorTests/MarkdownSemanticComparison.swift:120-150` и удаляется на этапе 2. Он не хранит ожидаемый HTML и тег расширения. Новые тесты не должны от него зависеть: в U0.3 создаётся свой читатель `GFMSpecReader` (другое имя типа, чтобы не конфликтовать со старым до его удаления).
5. **Клипборд.** `MarkdownClipboardCopyService` не вызывает `renderPage` (только свой cmark, `project(...)`, строка ~401). Набора настроек «копирование» в эталоне HTML нет; он относится к этапу 7.

## 1. Как вызывается `renderPage` и что в результате

Сигнатура: `LacEditor/Preview/MarkdownRenderer.swift:413-421`, статический метод `MarkdownRenderer.renderPage(_ markdown:, darkMode:, includeHTMLMedia:=false, renderEmoji:=false, resolveLocalImages:=false, documentURL:=nil, prepareRemoteImages:=false, syntax:=.init(), forExport:=false, includeHeadingNumbers:=false, includeListStyles:=false, staticWidgetFallback:=false, preserveRawHTMLBlocks:=false, includeSourcePositions:=false, isPreview:=false, highlightCode:=false, wiki:=nil, critic:=nil, embeds:=nil, hidesObsidianComments:=false) -> MarkdownRenderedPage`. Работает без `async`, без главного потока.

`MarkdownRenderedPage` (`MarkdownRenderer.swift:104-124`), что писать в эталон:

| Поле | Тип | В эталон | Стабильность |
| --- | --- | --- | --- |
| `body` | String | да, после нормализации маркеров | см. ниже |
| `darkMode` | Bool | нет (задаётся тестом) | |
| `typography`, `previewAccent` | | нет (renderPage их не задаёт) | |
| `headingIDs` | Set<String> | да, отсортировать | порядок Set случайный |
| `formulas` | [MarkdownRenderedMath] (`source`, `display`) | да, по порядку | |
| `diagrams` | [MarkdownRenderedDiagram] (`kind.rawValue`, `source`) | да, по порядку | |
| `omittedHTML`, `preserveWhitespace` | Bool | да | |
| `remoteImageMarkers` | [String: String] маркер → адрес | да, ключи нормализовать, сортировать по номеру маркера | ключ содержит UUID |
| `localMediaMarkers` | [String: LocalMediaResource(url, fragment)] | да: `url.path` + `fragment` | ключ с UUID; путь зависит от `documentURL` |
| `rawHTMLBlocks` | [(marker, html)] | да, по порядку | маркер с UUID |
| `rawHTMLBlockProofFailed` | Bool | да | |
| `listDepths` | Set<Int> | да, отсортировать | |

**Недетерминированное** (найдено поиском `UUID`, `Date`, `random` по `MarkdownRenderer`, `MarkdownNoteEmbed`, `MarkdownMathExtension`, `CriticMarkupRender`, `MarkdownCalloutRender`; в последних четырёх случайного нет):

- `LACREMOTE<32 hex>` — `MarkdownRenderer.swift:586`;
- `LACBLOCKMEDIA<32 hex>` — `:761`; `LACLOCALMEDIA<32 hex>X<n>` — `:894`;
- `LACRAW<32 hex>` и маркер `<!--LACRAW<32 hex>X<n>-->` — `:1067, 1089, 1116, 1070`;
- `lac-anchor-<UUID с дефисами, верхний регистр>` — `:2182` (только когда есть якорь внутри блока; иначе детерминированный `lac-anchor-<n>`, `:2187`).

**Нормализация маркеров** (функция `BaselineNormalizer.markers(in:)` в поддерживающем файле): регулярное выражение `(LACREMOTE|LACBLOCKMEDIA|LACLOCALMEDIA|LACRAW)[0-9A-F]{32}` заменить на `<префикс>#<k>`, где `k` — порядковый номер первого появления этого префикса+UUID в рамках одной записи (в теле, потом в словарях); `lac-anchor-[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}` → `lac-anchor-U<k>`. Одну и ту же замену применять к `body`, ключам словарей и маркерам `rawHTMLBlocks` (чтобы связь «маркер в теле ↔ запись» сохранялась). Обрабатывать через `NSRegularExpression` и `NSString` (UTF-16), не через Character.

**Зависимость от окружения:**
- Язык: `L10n.tr` подставляет текст в `aria-label` таблиц и `<pre>` (`MarkdownRenderer.swift:437-438`), «预览为空…», оглавление и выноски. В тесте в `setUp` выставлять язык `en` через `UserDefaults(suiteName:)` + `L10n.configure(defaults:)`, в `tearDown` — `L10n.configure()`; образец — `LacEditorTests/MarkdownNoteEmbedTests.swift:25-47`. Статическое состояние `L10n` общее на процесс; тест не должен запускаться одновременно с другими, меняющими язык (в Xcode классы разнесены по процессам; на SwiftPM XCTest последователен).
- Пути: `documentURL` всегда фиктивный `URL(fileURLWithPath: "/lac-baseline/doc.md")` (каталога нет, диск не читается). Если в выводе всё же встретится реальный путь (каталог репозитория, tmp), заменять префикс на `$DOC` в нормализаторе. Реальный `FileManager`-путь в эталон попасть не должен.
- Время/случайность: других нет. Подсветка (`SyntaxHighlighter.tokens`, tree-sitter) детерминирована, классы `tok-k/s/n/y/c` (`:524-528`).

## 2. Как читаются fixture

- `LacEditorTests/Fixtures/GFMSpec/{spec.txt, extensions.txt, SOURCE.txt, exceptions.json}`; `Fixtures/MarkdownBaseline/{long-chapter 17.7 KB, note, note-media, tables}.md`; `Verification/Fixtures/{acceptance, typora-baseline, typora-parity}.md` (остальные файлы там — не Markdown).
- Существующие тесты читают через `URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/GFMSpec")` (`MarkdownSemanticConsistencyTests.swift:9-11`; корпус документов — `:36-44`; `MarkdownSemanticRoundTripTests.swift:19-25`). `MarkdownBaselineDocuments.fixture` (`MarkdownBaselineDocumentsTests.swift:15-22`) под `SWIFT_PACKAGE` берёт `Bundle.module`, иначе `#filePath`. Эти файлы тянут `import AppKit`; их helper не использовать.
- **Проблема стенда:** `gen.py` кладёт тесты в `Tests/LacEditorTests/` как символические ссылки, и `#filePath` указывает на ссылку, а не на `/srv/git_projects/LacEditor/LacEditorTests` (проверено маленькой программой: `#filePath` не разворачивает ссылку). Поэтому стенд создаёт ещё ссылки `Tests/LacEditor` и `Tests/Verification` (`gen.py:41-48`).
- **Решение для новых тестов:** один способ и для Xcode, и для стенда, и для записи эталонов:

  ```swift
  /// Каталог исходников тестов. Ссылку стенда разворачиваем, чтобы читать и писать настоящие файлы проекта.
  static var testsDirectory: URL {
      URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
  }
  ```

  (Проверено: `resolvingSymlinksInPath()` на Linux даёт реальный каталог.) `#filePath` брать в файле поддержки; `Bundle.module` не использовать (на Mac при `swift test` каталог копируется в бандл, но запись эталонов нужна в исходники). Корень проекта для `Verification/Fixtures` — `testsDirectory/..`.
- Xcode: тестовые каталоги — `PBXFileSystemSynchronizedRootGroup` (4 в pbxproj), новые файлы подхватываются сами; в `pbxproj` ничего вносить не надо. `Package.swift:77` уже копирует `Fixtures` целиком.

## 3. Настройки: кто что вызывает

| Вызывающий | Строка | Настройки |
| --- | --- | --- |
| `MarkdownPreview` (`MarkdownRenderActor`) | `MarkdownPreview.swift:13` | `renderEmoji, resolveLocalImages, documentURL, prepareRemoteImages, syntax, includeHeadingNumbers, includeListStyles, includeSourcePositions, isPreview, highlightCode, wiki, critic` |
| `MarkdownPDFExportService` | `:281-284` | `includeHTMLMedia: isHTML, renderEmoji, resolveLocalImages: !isHTML, documentURL, prepareRemoteImages: !isHTML, syntax, forExport, includeHeadingNumbers, includeListStyles, staticWidgetFallback: !isHTML, preserveRawHTMLBlocks: isHTML, highlightCode: !isHTML, wiki, critic` |
| `WriterCombinedPage` | `:34-36` | `renderEmoji, resolveLocalImages, documentURL, prepareRemoteImages, syntax, highlightCode` |
| `MarkdownNoteEmbed.finalize` (вложенный) | `MarkdownNoteEmbed.swift:358` | `syntax, forExport, wiki: nil, embeds: nil, hidesObsidianComments`; покрывается наборами с `embeds` |
| `MarkdownClipboardCopyService` | — | `renderPage` не вызывает (см. п. 0.5) |

Важно: по умолчанию `preserveEditingSoftBreaks = true` и `preserveExportSoftBreaks = nil` (→ true) дают `CMARK_OPT_HARDBREAKS`; `NOBREAKS` включается через `preserveEditingSoftBreaks: false` / `preserveExportSoftBreaks: false` (`MarkdownRenderer.swift:571-572`). Параметры `MarkdownSyntaxOptions`: `strictMode, inlineMath, legacyInlineMath, smartPunctuation, preserveEditingWhitespace, preserveExportWhitespace, preserveEditingSoftBreaks, preserveExportSoftBreaks` (`MarkdownMathExtension.swift:5-24`).

**Семь наборов** (`enum BaselineSet`, у каждого `name` = имя файла эталона):

| Имя | Описание |
| --- | --- |
| `preview` | как `MarkdownPreview`, `wiki: nil`, `critic: nil`, `embeds: nil` |
| `preview-vault` | как `preview` + wiki-контекст + заглушка встраиваний + `critic: .show` + `hidesObsidianComments: true` |
| `preview-nobreaks` | как `preview`, `syntax = .init(strictMode: false, smartPunctuation: false, preserveEditingWhitespace: true, preserveEditingSoftBreaks: false)` |
| `export-pdf` | как PDF-экспорт при `isHTML == false`, `wiki` контекст, `critic: nil` |
| `export-html` | как экспорт при `isHTML == true` (`includeHTMLMedia`, `preserveRawHTMLBlocks`, `resolveLocalImages: false`, `highlightCode: false`), `critic: .result` |
| `export-nobreaks` | как `export-pdf`, `syntax = .init(preserveExportWhitespace: true, preserveExportSoftBreaks: false)`, `critic: .original`, `embeds` заглушка |
| `writer` | как `WriterCombinedPage` |

Режим `critic: .show` при `export-*` не нужен: `.show` проверен в `preview-vault`, `.result/.original` — в экспорте. `darkMode`: везде `false`; `preview-vault` и `export-nobreaks` дополнительно запускать с `darkMode: true` только для документа `Corpus/embeds.md` (embed.finalize принимает `darkMode`) — запись `embeds.md[dark]`.

**Wiki-контекст в тесте** (образец `MarkdownWikiLinkRewriterTests.swift:6-10`):

```swift
MarkdownWikiLinkContext(
    resolver: MarkdownWikiLinkResolver(base: URL(fileURLWithPath: "/lac-baseline", isDirectory: true),
                                       paths: ["a.md", "sub/c.md", "x.md", "sub/x.md", "Корпус.md", "note-a.md"]),
    documentURL: URL(fileURLWithPath: "/lac-baseline/doc.md"))
```

**Провайдер встраиваний** (образец `StubProvider` в `MarkdownNoteEmbedTests.swift:8-21`): `final class BaselineEmbedProvider: MarkdownNoteEmbedProvider, @unchecked Sendable` со словарём «имя → текст» (литерал в тесте: `note-a` (текст с заголовком и списком), `Корпус` (кириллица), `deep` (содержит свой `![[note-a]]`, чтобы проверить глубину 1)), `openAddress` вернуть nil. **Всегда передавать `embeds:` явно**, когда задан `wiki`: иначе `renderPage` создаёт `MarkdownFolderNoteEmbedProvider` и читает диск (`MarkdownRenderer.swift:431`).

## 4. `MarkdownPresentation` (U0.2)

Полный разбор: `MarkdownPresentationParser.parse(_ text:, includeReadableText:, includeEmojiCandidates:, includeUppercaseRuns:, includeWikiLinks:, syntax:, detectsFrontMatter: = true, blocks: nil, isCancelled:)` (`MarkdownPresentationParser.swift:1762`). Контроллер (`MarkdownPresentationController.swift:1789-1812`) вызывает `MarkdownLocalParser.parse(text, options: MarkdownParseOptions(...))`, внутри — тот же полный разбор при отсутствии базы; затем `headingNumbering ? parsed.numberingHeadings(true) : parsed`. Реальные флаги: `includeReadableText = readableEnabled`, `includeEmojiCandidates = enabled || outline || readable || emojiCompletion || mathPair`, `includeUppercaseRuns = enabled && !uppercaseHeadingLevels.isEmpty`, `includeWikiLinks: true`.

**Наборы:**

| Имя | Вызов | Корпус |
| --- | --- | --- |
| `editor` | `parse(text, includeReadableText: true, includeEmojiCandidates: true, includeUppercaseRuns: true, includeWikiLinks: true)` | всё, + CRLF-варианты документов |
| `editor-loose` | то же, `syntax: .init(strictMode: false, legacyInlineMath: true, smartPunctuation: false)` | всё |
| `editor-numbered` | `parse(...)` как `editor` + `.numberingHeadings(true)` | только документы (не примеры spec) |
| `editor-minimal` | `parse(text)` без флагов | только документы |

**Поля `MarkdownPresentation`** (`Models/MarkdownPresentation.swift:866-912`, все хранимые; в эталон идут все, кроме кэшей сдвига):
`spans, headings, namedAnchors, images, diagrams, audioBlocks, iframeBlocks, detailsBlocks, htmlBlocks, pageBreaks, ruby, links, formulas, inlineFormulas, emojiCandidates, emojiCandidatesIncluded, emojiCompletionRanges, smartTextRanges, smartRawHTMLRanges, textReplacements, paragraphs, completedTaskRanges, taskCheckboxes, listMarkers, looseIndents, footnotes, tableOfContents, tables, codeBlocks, fenceContainerLines, fenceBlockedRanges, fenceBlockedEOF, fenceContextAvailable, readableText, wikiLinks, unreliableRanges, elements`.
**Исключить** (состояние для `shift`, не результат разбора): `spanEnds, completedEnds, isReadyForShift, isTextStructureOnly`. `unreliableRanges` и `elements` (индекс для пути элемента: `MarkdownElementIndex`: `textLength`, `blocks`, `inlines` — приватные, видны через `Mirror`) — писать. Список имён полей зафиксировать константой в тесте: если `Mirror` находит поле, которого нет ни в списке «пишем», ни в списке «исключаем», тест падает с сообщением (новое поле нужно осознанно отнести к одному из списков). На этапе 5 из типа удаляются «разбор»-части: правка списка допустима только в задаче U5.2 и записывается в «Изменения оформления».

**Сериализация `MarkdownPresentation`:** обобщённый писатель на `Mirror` (`BaselineDump`), правила:
- `NSRange` → `loc+len`; `NSRange?` → `nil`/`loc+len`;
- `String` → JSON-экранирование в кавычках (`\n`, `\r`, `\t`, `\"`, `\\`, остальное управляющее и U+2028/2029/00A0/200B — `\u{…}`);
- `Bool/Int/UInt16/Double` → `\(value)`; `Double` писать через `String(format: "%.6g")` (разные платформы дают одинаковую запись);
- `Optional` → `nil` или значение;
- `enum` без данных → имя случая; с данными → `case(…)` по меткам Mirror;
- `struct` → `{метка=значение метка=значение}` в порядке объявления (Mirror даёт порядок хранимых полей); пустые массивы и `nil`-поля не опускать — ловят пропажу поля;
- `Array`/любой `Collection` кроме `String` → построчно `[i] …` (для `MarkdownTableRows`, коллекции со сдвигами, обходить как коллекцию, а не как struct: проверка `value as? any Collection`, потому что Mirror показал бы внутренние `base/baseShift`);
- `Set` → сортировка по описанию; `Dictionary` → по ключу;
- не писать `URL`/`Date`/`UUID`, если встретятся: сообщение об ошибке теста.
Формат записи: строка `=== <corpus>/<id> | <section>`, далее `field: значение` и под ним элементы списка с отступом 2 пробела, пустое поле `field: []`. Верхний уровень — только те поля, что в списке «пишем», в порядке списка выше.

## 5. Формат эталонов и размер

Решение: **один файл `.txt` на (набор × группа корпуса)**, внутри записи-блоки; сравнивается целиком как строка. Файлы в `LacEditorTests/Fixtures/RenderBaseline/` и `PresentationBaseline/`:

```
RenderBaseline/Corpus/*.md                       входные документы (см. U0.1)
RenderBaseline/<набор>.spec.txt                  672 примера (наборы: preview, preview-vault, preview-nobreaks, export-pdf)
RenderBaseline/<набор>.ext.txt                   30 примеров, те же наборы
RenderBaseline/<набор>.docs.txt                  документы (все 7 наборов)
PresentationBaseline/<набор>.<группа>.txt        editor(.spec/.ext/.docs), editor-loose(.spec/.ext/.docs), editor-numbered.docs, editor-minimal.docs
```

Почему примеры spec только в четырёх наборах: остальные отличаются возможностями (`critic`, `%%`, `embeds`, HTML-медиа, экспортные флаги), которых в spec почти нет; wiki-маскировку `[[`, `%%` и CriticMarkup `{++` проверяют `preview-vault` и документы корпуса. Документы корпуса идут через все семь наборов; их CRLF-варианты (суффикс `[crlf]`) — только в наборе `preview` и в `editor`.

Запись:

```
=== spec/0123 | Fenced code blocks
[flags] omitted=false whitespace=false rawFailed=false
[headingIDs] foo, bar
[listDepths] 1, 2
[formula] display=false source="x^2"
[diagram] kind=mermaid source="graph TD; A-->B"
[remote] LACREMOTE#0 -> "https://example.com/a.png"
[local] LACLOCALMEDIA#0X0 -> "/lac-baseline/img.png" fragment=""
[raw] <!--LACRAW#0X0--> -> "<div>…</div>"
--- body
<p data-sourcepos="1:1-1:3">foo</p>
```

Правила: пустые разделы (`[formula]` и т. д.) не писать, `[flags]` — всегда; строка тела, начинающаяся с `=` или `\`, получает префикс `\` (запись не ищется парсером, но заголовок записи остаётся однозначным); `\r` в теле писать как `\r` (двумя символами), остальные управляющие символы — `\u{…}`. Все преобразования строк делать по `unicodeScalars`/`utf16`, **не** по `Character`: в Swift `"\r\n"` — один `Character`, `split(separator:"\n")` и `components(separatedBy:)` на Linux не делят CRLF (см. `linux-only-failures.txt`, `MarkdownSectionMoveTests.testCRLFPreserved`). Файлы только с `\n`.

**Размер** (оценка: spec.txt 217 KB; HTML ≈ 40 % входа, `data-sourcepos`/обёртки +50 %): spec+ext в четырёх наборах ≈ 4 × 150 KB = 0,6 MB; документы (≈50, самый большой — `long-chapter.md` 17,7 KB ≈ 60 KB HTML) в семи наборах ≈ 0,5 MB; оформление: spec+ext в двух наборах ≈ 2 × 600 KB, документы — 0,6 MB, итого ≈ 2 MB. Всего 3–4 MB текста в git; diff читается по записям. Если `long-chapter` в оформлении окажется > 300 KB, писать для него в `editor*` только `spans/headings/tables/codeBlocks/links/images/readableText` — решить по факту первого прогона и зафиксировать в статусе.

## 6. Механизм записи эталонов

- Переменная `LAC_RECORD_BASELINE=1` (читать `ProcessInfo.processInfo.environment`). Тест строит всю строку файла и: при записи пишет её в `Fixtures/...` через `String.write(to:atomically:encoding:.utf8)` (каталог создаёт `createDirectory(withIntermediateDirectories: true)`), при проверке сравнивает; отсутствие файла — ошибка «запустите с LAC_RECORD_BASELINE=1» (не молчаливое создание).
- Путь каталога: `testsDirectory` из п. 2 (`#filePath` + `resolvingSymlinksInPath()`). На стенде тест лежит ссылкой в `Tests/LacEditorTests/`, и без разворота запись ушла бы в стенд; с разворотом — в `/srv/git_projects/LacEditor/LacEditorTests/Fixtures/...`.
- Запись также должна проходить в режиме без записи как проверка уникальности: тест дважды строит один и тот же файл и сравнивает строки между собой (отсеивает остаточную недетерминированность до записи эталона). Режим записи не должен падать при несовпадении.
- Запуск записи на стенде (песочница с Swift 6.0.3):

  ```sh
  export PATH=/home/claude-bot/tools/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:$PATH
  cd /home/claude-bot/tools/lac-writer-check
  python3 gen.py && python3 gen_extract.py >/dev/null && python3 gen_tests.py
  swift build --build-tests 2>&1 | grep -E "error:|Compiling|Build" | tail
  R=.build/x86_64-unknown-linux-gnu/debug/LacWriterCheck_LacEditor.resources
  [ -d "$R/zh-hans.lproj" ] && ln -sfn zh-hans.lproj "$R/zh-Hans.lproj"
  LAC_RECORD_BASELINE=1 swift test --skip-build --filter 'MarkdownRenderBaselineTests' 2>&1 | tail -20
  swift test --skip-build --filter 'MarkdownRenderBaselineTests' 2>&1 | tail -5     # без записи: должен пройти
  ```

  (то же `ln` для `zh-Hans.lproj`, что делает `run-tests.sh:11-12`.) Полный `run-tests.sh` запускает все тесты и долго; для точечной работы использовать команду выше.

## 7. U0.3: сверка со спецификацией

Тест `LacEditorTests/MarkdownSpecConformanceTests.swift`; читатель `LacEditorTests/GFMSpecReader.swift`.

**`GFMSpecReader`**: формат spec.txt — ограждение из 32 обратных кавычек + ` example` [+ тег]; Markdown; строка `.`; ожидаемый HTML; закрывающее ограждение; `→` = табуляция (в Markdown заменить на `\t`, в HTML тоже). Образец — `GFMSpecCorpus.parse` (`MarkdownSemanticComparison.swift:126-150`); разбор по `utf8`/`unicodeScalars` строкам с `\n` (файлы LF). Результат: `number, section, markdown, html, tag` (`tag` из ` example autolink|table|strikethrough|tagfilter|disabled`). Расширения нумеруются отдельно (`ext#1…30`). Тест-инвариант: `spec.count == 672`, `ext.count == 30`, 2 с тегом `disabled`. `disabled` пропускаются и считаются в отчёте.

**Настройки рендера для сверки:** `renderPage(markdown, darkMode: false, syntax: .init(smartPunctuation: false, preserveEditingSoftBreaks: false), highlightCode: false)` (без `includeSourcePositions`, `isPreview`, `wiki`, `critic`). Мягкий перенос тогда выводится пробелом (`NOBREAKS`), поэтому нормализация сворачивает пробелы (cmark-gfm эталон выводит `\n`). Дополнительно в отчёт-режиме можно прогнать `inlineMath: false`, чтобы отделить `$…$` от остальных расхождений.

**Нормализация HTML** (`SpecHTMLNormalizer.normalize(_:)`, применяется к обеим сторонам; сначала нормализуется вывод рендера — удаляются добавки LacEditor, затем общая нормализация):
1. Обёртка таблицы: `<div class="table-scroll" role="region" aria-label="…" tabindex="0">` и закрывающий `</div>` после `</table>` (`MarkdownRenderer.swift:437,441-444`). Удалять по точной строке, собранной через `L10n.tr("表格，可横向滚动")` (язык `en`).
2. `<pre tabindex="0" aria-label="…">` → `<pre>` (`:438,445-446`; в `<pre … data-sourcepos>` порядок атрибутов другой, но sourcepos отключён).
3. Служебные вставки: `<span id="…"></span>` перед заголовками (`:1847`) и якорями (`:2189, 2220, 2228`), `<span hidden data-lac-list-depth="…" data-lac-list-kind="…"></span>` (`:1637`), `data-lac-whitespace`, `data-lac-heading-number`, `data-lac-checked-task`, `data-lac-centered-image`, `data-lac-toc`, `data-lac-math`, `data-lac-diagram` — удалить атрибут/элемент; `class="tok-…"` спан-подсветки (при `highlightCode: false` их нет; если появятся — снять).
4. Общая: между тегами `>\s+<` → `><`; внутри текста последовательности пробелов и переводов строки → один пробел; **кроме содержимого `<pre>…</pre>`**, где пробелы сохраняются; `<br />\n` → `<br />`; хвостовой `\n` убрать; `<input checked="" disabled="" type="checkbox" />` приводить к единому порядку атрибутов; самозакрывающиеся теги `<hr />`, `<img … />` без изменений (cmark-gfm и там, и там).
5. Любая дополнительная нормализация должна быть *универсальной* (по виду разметки) и записана в тесте комментарием с причиной; нормализация, подгоняющая конкретный пример, запрещена.

**Первичный список несовпадений.** Режим отчёта: при `LAC_SPEC_REPORT=<путь>` тест не падает, а пишет в файл (путь вне репозитория, например `/tmp/claude-1000/spec-report.txt`) строки `spec#N | section | ожидаемый | фактический` и сводку по `section`. Так основной агент получает список для разбора. Ожидаемые классы расхождений (гипотезы для проверки по первому отчёту):
- **безопасный режим**: сырой HTML заменяется `<!-- raw HTML omitted -->` (флаг `omittedHTML` при этом не ставится: он выставляется только при `includeHTMLMedia: true`) (разделы «HTML blocks», «Raw HTML», часть «Entity», «Links», «Autolinks»): намеренное, правило `docs/agents/markdown-html-media.md`;
- **`$…$` и `$$`** — формулы (`MarkdownMathExtension`): `docs/agents/markdown-editor.md` (формулы);
- эмодзи (`renderEmoji` выключен — не мешает), `[[…]]` (при `wiki: nil` не затрагивается), оглавление `[TOC]`, `==`/`^`/`~` (если включены расширения), подсветка — искать по отчёту;
- `data-lac-*` вне списка выше, `<li>` для задач, нумерованные заголовки — по отчёту;
- настоящие ошибки: 96, 97, 98, 109, 215, 241 к HTML не относятся (это расхождения оформления из `exceptions.json`).

**Структура списков в тесте:**

```swift
private struct SpecDifference {
    let corpus: String          // "spec" или "ext"
    let examples: [Int]
    let reason: String          // непустая, по-русски: что и почему отличается
    let rule: String            // путь правила, например "docs/agents/markdown-html-media.md"; для knownDefects — nil
    let fixIn: String?          // только у knownDefects, например "U3.1"
}
private static let intentionalExtensions: [SpecDifference] = [...]   // описание возможностей LacEditor
private static let knownDefects: [SpecDifference] = [...]            // ошибки, чинятся на этапе 3
```

Проверки: (а) каждое несовпадение входит ровно в один список; (б) запись без несовпадения (устаревшая) — ошибка; (в) `reason` непустая; `rule` указывает на существующий файл (проверка `FileManager.fileExists` от корня проекта = `testsDirectory/..`) и, по возможности, имя файла встречается в `docs/agents/`; `knownDefects` обязан иметь `fixIn`; (г) примеры не дублируются между списками; (д) `matches >= minimumMatches` — число точных совпадений после первичного разбора записывается константой `minimumMatches` (нижняя планка из главного плана); (е) `knownDefects` пуст после U3.4 — напоминание в комментарии над списком. Пример без причины тест не пропускает.

Мини-тесты нормализатора: удаление обёртки таблицы; `<pre>` с `tabindex`; пробелы сохраняются внутри `<pre>`, сворачиваются снаружи.

## 8. Стенд `lac-writer-check`

- Работает: в `lib-files.txt` есть `Preview/MarkdownRenderer.swift`, `MarkdownPresentationParser`, `MarkdownPresentation`, `CriticMarkupRender`, `MarkdownObsidianComment`, `MarkdownCalloutRender`, `MarkdownNoteEmbed`, `MarkdownFolderNoteEmbedProvider`, `Editor/SyntaxParser.swift`; `MarkdownHTMLMediaService`/`MarkdownImageUploadService` — урезанные копии (`gen_trim.py`, `keep-*/drop-*`). `renderPage` вызывают уже 10 тестов стенда: `CriticMarkupRenderTests, MarkdownCalloutTests, MarkdownWikiLinkRewriterTests, MarkdownTableEditingTests, MarkdownLinkNavigationTests, MarkdownNoteEmbedTests, UIPolishJTests, MarkdownObsidianCommentTests, TyporaBaselineTests, MarkdownFormattingServiceTests`. Значит, тест с `renderPage` собирается без изменений стенда.
- Чего нет: тестов, читающих `Fixtures/GFMSpec` (`MarkdownSemantic*` стенду не нужны: у них отдельный стенд `~/tools/lac-semantic-check`); на стенде нет ссылки на `Fixtures` рядом с `Tests/LacEditorTests` — **не нужна**, если использовать `resolvingSymlinksInPath()`. Менять `gen.py` не требуется.
- Новые тестовые файлы должны использовать только `Foundation`, `XCTest`, `@testable import LacEditor` (без `AppKit`: заглушка есть, но тип `NSColor` и прочее не нужны). Классы не `@MainActor` (в `gen_tests.py` `wrap_mainactor` нужен для методов `@MainActor` на Linux).
- **Внести в `~/tools/lac-writer-check/test-files.txt`** (основной агент; файл общий): `GFMSpecReader`, `BaselineSupport` (корпус, нормализатор, писатель `Mirror`, запись), `MarkdownRenderBaselineTests`, `MarkdownSpecConformanceTests`. Новых файлов приложения в `lib-files.txt` не нужно.
- Сборка и точечный запуск — команды из п. 6 и `swift test --skip-build --filter MarkdownSpecConformanceTests`. Время: ≈ 5000 вызовов `renderPage` + 1500 полных разборов; ожидается минуты в отладочной сборке. Если превысит ~10 мин, вынести CRLF-варианты в отдельный тест того же класса.
- `docs/TEST_STATUS.md` (основной агент): строка «новые тесты U0 проходят на lac-writer-check; на Mac не запускались».

## 9. Файлы, шаги, проверки

### Новые файлы

```
LacEditorTests/BaselineSupport.swift                 корпус, наборы, нормализатор маркеров, Mirror-писатель, запись/сравнение
LacEditorTests/GFMSpecReader.swift                   читатель spec.txt и extensions.txt (с ожидаемым HTML)
LacEditorTests/MarkdownRenderBaselineTests.swift     U0.1 и U0.2 (два набора test-методов в одном классе)
LacEditorTests/MarkdownSpecConformanceTests.swift    U0.3
LacEditorTests/Fixtures/RenderBaseline/Corpus/*.md   ≈ 35 документов
LacEditorTests/Fixtures/RenderBaseline/*.txt         эталоны HTML
LacEditorTests/Fixtures/PresentationBaseline/*.txt   эталоны оформления
```

Главный план требует «в том же тестовом файле» для U0.2; допустимо, если `MarkdownRenderBaselineTests` разрастётся — вынести U0.2 в `MarkdownPresentationBaselineTests.swift` (и в `test-files.txt`).

### Шаги

**U0.1**
1. `BaselineSupport.swift`: `testsDirectory`; загрузка корпуса: spec/ext (через `GFMSpecReader`), `Fixtures/MarkdownBaseline/*.md`, `../Verification/Fixtures/*.md`, `Fixtures/RenderBaseline/Corpus/*.md` — все по алфавиту имён; CRLF = `replacingOccurrences("\n"→"\r\n")` по `unicodeScalars`; нормализатор маркеров; `BaselineSet`; `BaselineStore` (запись/сравнение/отчёт о различиях: список идентификаторов записей, до 20 штук, и первое различие по строкам — разбор по `\n` на уровне `utf8`).
2. Написать `Corpus/*.md` (по одному короткому файлу на возможность, всё в LF, с кириллицей, CJK, эмодзи, комбинируемыми символами, где уместно): `critic.md`, `obsidian-comments.md`, `embeds.md`, `wiki.md`, `callouts.md`, `math.md`, `diagrams.md` (mermaid, flow, sequence), `media-html.md` (audio, video, iframe, pdf, svg), `media-data-uri.md` (рабочий PNG из `MarkdownBaselineDocuments.tinyPNGBase64`, 69 байт — скопировать строку, не импортировать), `images-local-remote.md`, `details.md`, `ruby.md`, `emoji.md`, `toc.md`, `footnotes.md`, `tables.md`, `front-matter.md`, `inline-css.md`, `highlight-sub-sup.md`, `tasks.md`, `loose-lists.md`, `code-fences.md`, `html-blocks.md`, `crlf-notes.md` (содержит `\r\n` в самом файле нельзя: git нормализует; CRLF даёт загрузчик), `cyrillic-cjk-emoji.md`, `headings.md` (повторяющиеся заголовки: ID с суффиксами), `twitter-pagebreak.md`, `entities-autolinks.md`. Проверять через стенд, что каждая возможность даёт непустой вклад (в эталоне виден нужный тег или поле).
3. `MarkdownRenderBaselineTests`: `setUp` (язык `en`), `tearDown`; по методу на набор: `testPreviewBaseline()`, … — каждый вызывает `check(set:)`, который строит файлы `<набор>.{spec,ext,docs}.txt`. Сборка записи: вызов `renderPage` с настройками набора → нормализация → форматирование записи. Метод `testRecordsAreDeterministic` строит один набор дважды и сравнивает.
4. Записать эталоны (п. 6), просмотреть `git diff --stat` и выборочно файлы: нет UUID, нет путей `/tmp`, `/srv`, нет `Date`.
5. Прогнать без записи.

**U0.2**
6. Писатель `BaselineDump` и список полей; тест `testPresentationFieldListIsComplete` (Mirror против списков «пишем/исключаем»).
7. `testEditorBaseline`, `testEditorLooseBaseline`, `testEditorNumberedBaseline`, `testEditorMinimalBaseline`; запись и повторный прогон. Для документов — также CRLF-варианты. Если некоторое поле не сериализуется (URL/Date) — вынести в отчёт, а не молча обходить.

**U0.3**
8. `GFMSpecReader` + тест числа примеров.
9. Нормализатор + мини-тесты.
10. `MarkdownSpecConformanceTests` в режиме отчёта (`LAC_SPEC_REPORT`); разобрать несовпадения вместе с основным агентом, заполнить `intentionalExtensions` и `knownDefects`, зафиксировать `minimumMatches`.
11. Прогнать без отчёта; тест зелёный.

### Проверки

```sh
export PATH=/home/claude-bot/tools/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:$PATH
cd /srv/git_projects/LacEditor
for f in LacEditorTests/{BaselineSupport,GFMSpecReader,MarkdownRenderBaselineTests,MarkdownSpecConformanceTests}.swift; do swiftc -frontend -parse $f || echo FAIL $f; done
git diff --check
# стенд: после внесения имён в test-files.txt (п. 8)
/home/claude-bot/tools/lac-writer-check/run-tests.sh      # полный: настоящих падений нет
```

### Критерии готовности

- U0.1: `LAC_RECORD_BASELINE=1` записывает файлы; повторный прогон без записи проходит, и результат не меняется от запуска к запуску (проверка `testRecordsAreDeterministic`); в эталонах нет UUID, дат, tmp/repo-путей; каждая возможность панели из списка главного плана присутствует в корпусе; семь наборов записаны.
- U0.2: все поля списка п. 4 присутствуют в записях; `testPresentationFieldListIsComplete` зелёный; повторный прогон проходит.
- U0.3: тест проходит на стенде; все 672 + 28 (без `disabled`) примера либо совпали, либо записаны в один из двух списков с причиной; `minimumMatches` зафиксирован; в `docs/markdown-unified-model-plan.md` в статусе задач указаны число совпадений и размер списков.
- Код приложения (`LacEditor/`) не изменён: `git status` показывает только новые файлы в `LacEditorTests/` (и правки общих файлов основным агентом).
- В отчёте — что не запускалось (Mac, Xcode).

### Риски

1. **Foundation Linux и macOS.** Эталон снимается на Linux, на Mac первый прогон может дать отличия: `String.components(separatedBy:)`/`split` с `\r\n`; `URL(fileURLWithPath:).path` у несуществующих путей; форматирование `Double` (поэтому `%.6g`); порядок `Set`/`Dictionary` (всегда сортировать); `NSRegularExpression` с `[0-9A-F]` и Unicode; `String.replacingOccurrences` на графемах `\r\n`; `UUID().uuidString` в верхнем регистре (оба); `NSRange` в `Mirror` (на Linux `NSRange` — struct с полями `location/length`, поэтому обрабатывать до общего разбора). Различия записать в статус задачи; при подтверждённом отличии платформы нормализовать универсально, не подгонять.
2. **Языковая среда.** `L10n` статичен; если ещё одному тесту выставляет язык параллельно, эталон поплывёт. Проверка `en` в `setUp` и в начале каждого `check`.
3. **`Mirror` и `private(set)`/приватные поля**: видны, но порядок и метки зависят от объявления. Любая правка структуры на этапе 5 меняет эталон — это ожидаемо, фиксируется в U5.2.
4. **`MarkdownTableRows` и другие обёртки коллекций**: если `Mirror` вернёт внутренности вместо строк, эталон станет зависеть от кэшей сдвига. Проверка: в записи не должно быть меток `baseShift`, `changedIndex`, `followingShift`.
5. **Время прогона**: ≈ 7000 вызовов; запуск в Debug на стенде может занять минуты. Метод тестов разбить по наборам (Xcode распараллеливает по классам, не по методам).
6. **Фиксированная UUID-карта**: если один документ содержит два маркера с одинаковым UUID-префиксом в разных словарях, нумерация должна быть общей на запись (см. п. 1). Проверить на `media-html.md` и `html-blocks.md`.
7. **Размер `long-chapter` в оформлении**: см. п. 5.
8. **Эталоны фиксируют текущие ошибки** (в том числе расхождения с spec): это нужно по плану (побайтное поведение панели — норма), поэтому U3.4 различает «ошибка → исправить в эталоне только если пункт есть в разделе “Намеренные изменения HTML”».
9. **Рендер не очищает кэши между вызовами**: `highlightCache` и `MarkdownEmoji` — детерминированные кэши; на порядок записей не влияют. Если появятся отличия «первый вызов ≠ второй», это находит `testRecordsAreDeterministic`.
10. **Дубль имени типа**: `GFMSpecReader` против `GFMSpecCorpus` (до этапа 2 оба существуют); не переименовывать старый и не переиспользовать.
