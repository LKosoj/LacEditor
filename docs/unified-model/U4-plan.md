# U4 — Перевод потребителей HTML на модель и удаление `MarkdownRenderer` (U4.1–U4.4)

Статус: план (код не менялся), 05.11.2026. Опора: главный план (решения 1–9, этапы 3–4, 6), U3.1–U3.3 (с «Решениями основного агента»),
`docs/agents/text-state-and-background.md`, `export-and-preview.md`, `performance.md`. Номера строк — рабочая копия на 05.11.2026, перед правкой перепроверить `rg`.
Нового слоя в коде ещё нет (`MarkdownDocumentParser`, `MarkdownHTMLRenderer` пишутся в U2.3 и U3.x), поэтому API ниже — из планов U2.3/U3.1–U3.3.

## 0. Что делаем простыми словами

Сейчас правая панель, PDF и «сводный просмотр» писателя зовут один и тот же `MarkdownRenderer.renderPage(текст, флаги…)`: он сам правит текст, разбирает его cmark
(библиотека разбора Markdown) и выдаёт HTML. После U3 есть новый путь: «разобрать один раз в модель (`MarkdownDocumentModel`) → HTML-адаптер
(`MarkdownHTMLRenderer`) пишет HTML по модели». U4 переключает всех потребителей на новый путь и стирает старый: `MarkdownRenderer.swift` и функции
«подготовки текста» (подмена кусков текста перед разбором и правка HTML после). Тесты переводятся на новый вызов с теми же ожиданиями.

## 1. Что обнаружено при чтении кода (влияет на план)

1. **В `MarkdownRenderer.swift` (2497 строк) лежат не только рендер.** Строки 1–390 — типы, которые остаются: `MarkdownTypography` (7), `MarkdownRenderedMath` (94),
   `MarkdownRenderedDiagram` (99), `MarkdownRenderedPage` (104: HTML-оболочка страницы, CSS, `hideRemoteImages`, `resolveRemoteImages`, `prepareLocalMedia`). Строки 392–2497 — `enum MarkdownRenderer`.
   Планы U3 про перенос этих типов молчат. Значит «удалить файл» = сначала вынести 1–390 в `Preview/MarkdownRenderedPage.swift` (дословно, без правок), потом удалить остальное. Это шаг 0 в U4.4 (лучше — сразу в U3.1, тогда адаптер не зависит от старого файла).
2. **Текст в редакторе не равен тексту документа, если в документе есть картинки `data:`.** Контроллер оформления разбирает «экранный» текст (с короткими токенами вместо Base64; `parsedSource`, `sourceMap`),
   а предпросмотр берёт `document.text` (файловый, с настоящими `data:`). Для готового результата `readableText` это решено переносом диапазонов `inSource(map…)` (`MarkdownPresentationController.swift:716–725`).
   У модели такого переноса нет. Решение для U4.1: **модель публикуется только когда карта токенов пуста** (`sourceMap().isEmpty`) и `source` побайтно (UTF-16) равен файловому снимку — та же проверка, что в `installMarkdownReadableText` (`EditorDocument.swift:808`). Документы с вложенными картинками получают модель в U6.1 или не получают (предпросмотр разбирает сам, как сейчас).
3. **Время.** Пауза разбора контроллера `parseDelay`: 0,6 с при оформлении, 0,2/0,4/1,0 в других режимах. Дебаунс предпросмотра — 0,18 с (0,5 для больших файлов; `MarkdownPreview.swift:533`).
   При наборе текста модель контроллера к моменту рендера предпросмотра обычно **ещё не готова** — предпросмотр разбирает сам, как сейчас. Общая модель выручает при повторном рендере той же версии: смена темы, режима `critic`, показ панели, переключение вкладки, перерисовка при смене `wiki`.
   Реальная экономия «один разбор на версию» наступит в U6.1; до него U4.1 — это добавочная работа контроллера (временно 3 разбора на версию вместо 2). См. «Спорное», п. 1.
4. **Контроллер разбирает не всегда.** `schedule` (`MarkdownPresentationController.swift:1780`) выходит, если не включено ни оформление, ни оглавление, ни чтение, ни автодополнение, ни строка пути. В режиме «исходник + панель» модель не появится, пока не добавить условие «панель видна» (U4.1 п. в).
5. **`MarkdownClipboardCopyService` и `MarkdownExportImagesService` не вызывают `renderPage`.** Первый — это ~2000 строк собственного обхода cmark (`project`, 401–2440), который строит фрагмент выделения (`Fragment.html` он пишет сам); второй зовёт `MarkdownPresentationParser.parse` (эмодзи, формулы, диаграммы). Для удаления `MarkdownRenderer` они не нужны. Решение по ним — в п. 3.4 и «Спорном», п. 2.
6. **Чистые помощники HTML-медиа лежат не в `MarkdownRenderer`,** а в `Services/MarkdownHTMLMediaService.swift` (`exportBlock` 764, `iframeHTML` 417, `twitterFallbackHTML` 168, `copyMediaHTML` 1299) — они переживают U4.4. В самом `MarkdownRenderer` остаются только приватные `highlightedCodeHTML`/`highlightCache` (540/534) — их переносит U3.2.
7. **Скрипты сборки.** `EditorDocument.swift` входит в ручные списки `swiftc` в `Scripts/verify-release.sh` (стр. ~51) и `Scripts/run-acceptance.sh` (стр. 68 и 111). Как только `EditorDocument` ссылается на `MarkdownDocumentModel`, в эти три списка надо добавить `Models/MarkdownDocumentModel.swift`, `Models/MarkdownBlockIndex.swift`, `Models/MarkdownSyntaxOptions.swift` и всё, что модель тянет дальше (проверить компиляцией этих команд на Mac; на Linux — `rg` по типам). В них же сейчас нет и `MarkdownSyntaxOptions`.

## 2. Подзадачи и порядок

```text
U3.4 → U4.1 → ┬ U4.2 ┬→ U4.4
              └ U4.3 ┘
```

U4.2 и U4.3 параллельны, если файлы не пересекаются (U4.2: `MarkdownPreview.swift`, `EditorDocument.swift` читает; U4.3: PDF, WriterCombinedPage, ExportImages, при необходимости ClipboardCopy). U4.4 — после обеих. Каждая подзадача: разработка → ревью → прогон стенда → `git diff --check`.

### U4.1 — Модель у `EditorDocument` и публикация из контроллера

Файлы: `Models/EditorDocument.swift`, `Editor/MarkdownPresentationController.swift`, `Editor/EditorCoordinator.swift` (проводка), тест `LacEditorTests/EditorDocumentMarkdownModelTests.swift`.

а) **Слот модели в документе** — по образцу `markdownReadableText` (`EditorDocument.swift:318`, 705, 797–815):
- `private var markdownModel: MarkdownDocumentModel?` (номер версии лежит в самой модели: `model.revision`, тип `UInt?` из U1.1).
- Сброс в `nil` там же, где сбрасывается `markdownReadableText`: `text.didSet` (стр. 218), `language.didSet` (235), `noteLiveEdit` (705), `invalidateMarkdownReadableText` (рядом — новый `invalidateMarkdownModel`).
- `@discardableResult func installMarkdownModel(_ model: MarkdownDocumentModel, source: String) -> Bool`: гейт `language == .markdown`, `!hasPendingLiveEdits`, `!isLargeFileMode`, `isTakingMetricsSnapshot = true` → `synchronizedSnapshot()` → `snapshot.text.utf16.elementsEqual(source.utf16)` и `model.textLength == source.utf16.count`; на успех кладёт модель с `revision = snapshot.revision`. Без `scheduleMetricsRefresh` (метрики модель не используют).
- `func markdownModel(forRevision revision: UInt) -> MarkdownDocumentModel?`: `nil`, если `hasPendingLiveEdits` или `model.revision != revision` или `textRevision != revision`. Только на главном потоке (как остальное состояние документа).

б) **Контроллер публикует.** В блоке `operation.addExecutionBlock` (стр. ~1822, сразу после `MarkdownLocalParser.parse`) — второй проход `MarkdownDocumentParser.parse(text, options:, isCancelled: { operation.isCancelled })` **в фоне**, результат `model` уходит в главный поток вместе с `result` и ставится в том же месте, где `installReadableText` (стр. ~1893): `document.installMarkdownModel(model, source: text)`.
- Параметры: `syntax` — `self.syntaxOptions`; `isVaultNote = MarkdownObsidianComment.appliesTo(documentURL: document.url)`; `detectsFrontMatter: true`; `includes = [.wikiLinks, .noteEmbeds, .criticMarkup, .emoji]` (всё, что может понадобиться предпросмотру; лишние узлы адаптер выводит срезом исходника, U3.3 п. 2). Данные редактора (`readableText`, `elements`, `blockIndex`, `editorContext`) в U4.1 **не** включать — их пока считает старый разбор.
- Условие запуска: `document.isPreviewEffectivelyEnabled && sourceMap пуст` (см. п. 1.2). Не публиковать при `hasMarkedText`, при смене `generation`/`currentRevision` — теми же `guard`, что и у `parsedResult` (стр. ~1861–1865).
- В `schedule` (guard стр. 1783 и guard на главном потоке 1861) и в `parseDelay` добавить причину «панель видна и модель нужна» (`needsPreviewModel`); дополнительных пауз не вводить: пауза та же, что у остальных причин (для «только панель» это `needsFresh = false → 1,0 с`, что ≥ дебаунса панели — приемлемо, см. п. 1.3).
- `fullParseCount` не менять: это счётчик отката старого локального разбора, модель его не трогает.
- Отмена: `operation.isCancelled` в `parse` — как у старого разбора; отменённая операция ничего не ставит.

в) Проводка: `EditorCoordinator` (стр. ~4319) уже вызывает `update(...)`; панель видна — `document.isPreviewEffectivelyEnabled` читается внутри контроллера на главном потоке (поле `document` у него есть). Новых параметров `update` не нужно.

г) **Тесты** (образец — `DocumentMetricsTaskTests` для `installMarkdownReadableText`, стр. 52, 176–198): установка при совпадении источника; отказ при другом `source`; сброс при правке `text`, `language`, `noteLiveEdit`; `markdownModel(forRevision:)` не отдаёт модель старой версии; отказ при `isLargeFileMode`. Контроллерный тест: после `update` с видимой панелью модель появляется у документа (ожидание опросом, 30 × 100 мс); при непустой карте токенов — не появляется.

Готово: стенд (парсинг), `swiftc -frontend -parse` изменённых файлов; `MarkdownPresentationController.swift` — только `-parse`; новые записи в списках `swiftc` Scripts (п. 1.7) перечислены в отчёте.

### U4.2 — Предпросмотр на модели

Файл: `Preview/MarkdownPreview.swift` (+ тест `MarkdownPreviewTests.swift`).

| Место | Было | Станет |
| --- | --- | --- |
| `MarkdownPreview.swift:11–15` — тип и значение по умолчанию замыкания `renderer` | `(String, Bool, URL?, MarkdownSyntaxOptions, MarkdownWikiLinkContext?, CriticMarkupRenderMode?) -> MarkdownRenderedPage`, внутри `MarkdownRenderer.renderPage($0, darkMode:…, renderEmoji: true, resolveLocalImages: true, documentURL:, prepareRemoteImages: true, syntax:, includeHeadingNumbers: true, includeListStyles: true, includeSourcePositions: true, isPreview: true, highlightCode: true, wiki:, critic:)` | к кортежу добавляется седьмой аргумент `MarkdownDocumentModel?`. Значение по умолчанию: если `model` есть и `MarkdownHTMLRenderer.accepts(model, text:, syntax:, wiki:, critic:, documentURL:)` — `MarkdownHTMLRenderer.renderPage(model, text:, darkMode:, …те же флаги…)`; иначе строковый вход `MarkdownHTMLRenderer.renderPage(text, darkMode:, …те же флаги…)` (он сам разбирает; параметры — те же, что у старого вызова) |
| `MarkdownPreview.swift:17` — `actor MarkdownRenderActor.render(...)` | 6 параметров + `coordinator`, `generation` | + `model: MarkdownDocumentModel? = nil` (значение по умолчанию — чтобы 4 теста `MarkdownRenderActor().render("…")` не менялись); сигпост, проверки `Task.isCancelled` и `coordinator.isCurrent(generation, for: .preview)` до и после — без изменений |
| `MarkdownPreview.swift:~527` `beginRender` (в основном потоке, до `Task.detached`) | — | `let model = document.markdownModel(forRevision: revision)` — берётся **в момент запуска рендера**, а не в `render(...)`; значение захватывается в `Task.detached` (структура-значение, `Sendable`) |
| `MarkdownPreview.swift:553–555` | `MarkdownRenderActor.shared.render(markdown, darkMode:, documentURL:, syntax:, wiki:, critic:, coordinator:, generation:)` | то же + `model: model` |

`MarkdownHTMLRenderer.accepts` — маленькая функция в адаптере (U3.1/U3.3 пишут рядом): `model.revision != nil`-проверка не нужна; условия: `model.textLength == text.utf16.count`; `model.options.syntax == syntax`; `model.options.detectsFrontMatter`; `model.options.isVaultNote == MarkdownObsidianComment.appliesTo(documentURL:)`; `includes ⊇ нужные`, где нужные = `.emoji` всегда, `.wikiLinks` и `.noteEmbeds` если `wiki != nil`, `.criticMarkup` если `critic != nil`. Несовпадение — не ошибка, а «разберём сами» (п. 3.2 плана U3.3).

Что **не меняется** (проверить ревью): дебаунс 0,18/0,5 с (стр. 533), `renderTask` и его отмена в `stop()` (стр. 483), `taskGeneration`/`isCurrent`, `lastRequestedRevision`-дедупликация, `apply(...)` с проверкой `document.url`, `allowsRemoteImages`, `generation`. Разбор и вывод идут внутри актора `MarkdownRenderActor` — значит по-прежнему последовательно для всех предпросмотров (правило `text-state-and-background.md`, стр. 14); разбирать вне актора нельзя.

Тесты: `MarkdownPreviewTests.swift:707` — замыкание `{ text, darkMode, _, _, _, _ in` получает седьмой `_`; новый тест «модель совпавшей версии доходит до замыкания, модель другой версии/настроек — нет» (замыкание записывает, что получило; без флагов в production-коде). Остальные тесты панели (`MarkdownPreviewTests` 634–645, 651; `UIPolishJTests:150`) меняются только в U4.4 вместе с остальным (переименование вызова).

### U4.3 — Остальные потребители

| Файл:строка | Было | Станет | Особенности |
| --- | --- | --- | --- |
| `Preview/MarkdownPDFExportService.swift:281` (внутри `Task.detached`, стр. ~276) | `MarkdownRenderer.renderPage(snapshot.text, darkMode:, includeHTMLMedia: isHTML, renderEmoji: true, resolveLocalImages: !isHTML, documentURL: sourceURL, prepareRemoteImages: !isHTML, syntax:, forExport: true, includeHeadingNumbers: true, includeListStyles: true, staticWidgetFallback: !isHTML, preserveRawHTMLBlocks: isHTML, highlightCode: !isHTML, wiki: wikiContext, critic:)` | `MarkdownHTMLRenderer.renderPage(` с теми же аргументами (строковый вход) | Свежий `wikiContext` грузится с диска в том же `Task.detached` (стр. 277–279) — поэтому общую модель документа **не используем**: набор `includes` зависит от `wikiContext`, а экспорт редок. Отмена: строковый вход сам передаёт `isCancelled: { Task.isCancelled }`, при отмене страница пустая; дальше `pageTask.cancel()` через `withTaskCancellationHandler` (стр. 301) и `guard !cancelled` отбрасывают результат. `rawHTMLBlockProofFailed`/`formulas`/`diagrams`/`omittedHTML`/`rawHTMLBlocks` читаются с той же страницы (стр. 303–307) |
| `Preview/WriterCombinedPage.swift:34` (цикл по частям) | `MarkdownRenderer.renderPage(part.text, darkMode:, renderEmoji: true, resolveLocalImages: true, documentURL: part.documentURL, prepareRemoteImages: true, syntax:, highlightCode: true)` | `MarkdownHTMLRenderer.renderPage(` с теми же аргументами | Вызывается из `WriterCombinedViewController.reload()` через `runDetached` (`WriterCombinedViewController.swift:94`); частей много, каждая — отдельный разбор; моделей документов у частей нет. Комментарий в строке 4 («рендер делает `MarkdownRenderer`») обновить |
| `Preview/MarkdownNoteEmbed.swift:358` (внутри `finalize`) | вложенный `MarkdownRenderer.renderPage(limited, darkMode:, syntax:, forExport:, wiki: nil, embeds: nil, …)` | уже заменён в U3.3 (`MarkdownHTMLRenderer+Embeds.swift`: своя модель встроенной заметки с `includes: []`, глубина 1, кэш по `цель\0раздел`) | В U4.3 только проверка: `rg "MarkdownRenderer" LacEditor/Preview/MarkdownNoteEmbed.swift` — остаётся лишь код, который удалит U4.4 (`prepare`/`finalize`) |
| `Preview/MarkdownExportImagesService.swift:62` | `MarkdownPresentationParser.parse(text, includeEmojiCandidates: includeMath, syntax:, isCancelled:)` → `presentation.emojiCandidates`, `.formulas`, `.inlineFormulas`, `.diagrams` (диапазон + `source`) | `MarkdownDocumentParser.parse(text, options: .init(syntax:, includes: includeMath ? [.emoji] : [], isVaultNote: false, detectsFrontMatter: true), isCancelled: { Task.isCancelled })`; кандидаты — `model.emoji?.candidates`; формулы — обход блоков (`.mathBlock(source:)` с `range`, строчные `.formula(source:)`), диаграммы — `.codeBlock` с `diagram != nil` (`range`, текст тела) | Не потребитель `renderPage`, не блокирует U4.4. Объём малый (~30 строк обхода). Результат `Task.detached` не меняется: `(model, emojiValues)`; `nil` при отмене → `CancellationError`. Ожидания `MarkdownExportImagesServiceTests` — те же; сверить диапазоны (кириллица, CJK, эмодзи, `\r\n`). Записан также в U7.1 — оставить только здесь |
| `Services/MarkdownClipboardCopyService.swift:401–2440` (`project`) | свой cmark + `MarkdownSourcePositions`, `htmlSourceMatches`, `fencedCodeBlock`, `PairedMediaCollector`… → `Fragment` | **не переводится в U4** (см. «Спорное», п. 2) | Единственный вызывающий — `EditorCoordinator.swift:112`; `renderPage` не используется; в списке U4.4 не участвует |

Комментарии-упоминания `MarkdownRenderer` в `MarkdownDocumentModel.swift:7` и `MarkdownSemanticDocument.swift:8` (файл удаляет U2.6) — поправить в U4.4.

### U4.4 — Удаление и перевод тестов

Порядок внутри задачи:

0. Вынести `MarkdownRenderer.swift:1–390` в `Preview/MarkdownRenderedPage.swift` (если не сделано в U3.1). Записи: `project.pbxproj` (4 строки у `MarkdownRenderer.swift`: 47, 500, 1295, 1953 → заменить на `MarkdownRenderedPage.swift`), `~/tools/lac-writer-check/lib-files.txt` (стр. 79 → новый файл), `Package.swift` — не трогать (берёт каталог).
1. Перевести тесты (таблица в разделе 5), затем потребители готовы (U4.2/U4.3), затем:
2. Удалить `enum MarkdownRenderer` (весь остаток файла, вместе с `RemoteImageMarkers`/`LocalMediaMarkers`/`RawHTMLBlocks`/`ListDepths`, `renderBody`, `substitutingWikiLinks`) и запись файла в `project.pbxproj`/`lib-files.txt`.
3. Удалить функции подготовки: `CriticMarkupRender.prepare` (125) и `finalize` (173) со структурой `Prepared`, `freeBase`, `lineBreaks`, `tagName`, `commentLabel`/`attributeEscaped` (если адаптер U3.3 не вызывает — проверить `rg`); `MarkdownNoteEmbed.prepare` (231), `finalize` (325), `Prepared` (222), `markerRange` (395), `fileReplacement`/`escaped` (если без вызывающих); `MarkdownCalloutRender.separatingTitles` (113), `transform` (176), `callout(in:…)` (217), `attribute`, `mayContainCallout` (165; один тест вызывает — переводится); `MarkdownObsidianComment.hidden` обе формы (96 и 108). Остаётся по плану U3.3: типы выносок, провайдеры встраиваний (`MarkdownNoteEmbedProvider`, `MarkdownFolderNoteEmbedProvider`), `items`/`kind`/`body`/`section`/`limitedNote`/`blockHTML`/`flatten`, `CriticMarkupRender.items`/`resolved`/`mayContainMarkup`, `MarkdownObsidianComment.ranges`/`commentRanges`/`removed`/`appliesTo`/`mayContainComment`.
4. **Перенос правил в маску (`MarkdownSourceMask`).** `hidden(_ text: NSString, ranges:)` вызывается ещё из `MarkdownSourceMask.keepsParagraphFlags` (`MarkdownSourceMask.swift:139–144`): маска подсовывает пробный текст и смотрит, вставил ли `hidden` знак U+200B. Это единственное чужое использование. Перенос: `keepsParagraphFlags` считает признак сам по правилу `isInsideParagraph` из `hidden` (строка комментария целиком; до комментария на строке только пробелы/префикс; после — только пробелы; строки выше и ниже не пустые по `isBlankLine`). В маске уже есть `afterPrefix(units)` и `wholeLineFlags`; добавить рядом `isBlankLine` и `insideParagraph` (~20 строк, без пробного текста и подмены U+200B на U+E000). Проверка эквивалентности до удаления `hidden`: временный тест гоняет `keepsParagraph` по всему корпусу U0 (`BaselineCorpus`, LF и CRLF) и сравнивает со старым расчётом; после совпадения старый расчёт и временный тест удаляются в той же задаче. Выходной знак U+200B в HTML выводит адаптер U3.3 (п. 3.2), в маске он не нужен.
   Остальные потребители удаляемых функций: `MarkdownRenderer.swift:425–473` (удаляется), тесты (раздел 5). `CriticMarkupService`, `PandocExportService`, `CustomMarkdownExportService` удаляемые функции **не** используют (они зовут `MarkdownObsidianComment.removed`/`appliesTo`, `CriticMarkupPandoc`).
5. Документы: `docs/agents/export-and-preview.md` (стр. 17, 34, 40–43: порядок обработки `renderPage` заменить описанием «маска → модель → адаптер»; `MarkdownSemanticDocument` — стр. 45 правит U2.6), `docs/agents/testing.md` (38, 46), `docs/agents/markdown-editor.md`, `vault.md` (40), `text-state-and-background.md` (14, «синхронный cmark» → «разбор модели»), `docs/TEST_STATUS.md` (новые/переименованные тесты, «на Mac не запускалось»).

## 3. Безопасность передачи модели между потоками

- `MarkdownDocumentModel` — структура-значение, `Sendable` (`MarkdownDocumentModel.swift:5`); `rg "unchecked|OpaquePointer|class " Models/MarkdownDocumentModel.swift` пусто, вложенные типы (`MarkdownBlockNode`, `MarkdownReadableText`, `MarkdownBlockIndex`, `MarkdownElementIndex`, `MarkdownNamedAnchor`, `MarkdownFootnote`…) тоже помечены `Sendable` — это проверяет компилятор Swift 6 при сборке на Mac. Копия модели при передаче дешёвая (массивы — copy-on-write, то есть общая память до первой записи; адаптер модель не меняет).
- Единственные владельцы: слот `EditorDocument` (главный поток, как `markdownReadableText`) и локальная переменная `Task.detached`/актора. Мутабельного общего состояния нет; `MarkdownRenderActor` — актор (последовательное исполнение), PDF и сводный просмотр — отдельные `Task.detached` без общих данных.
- Дерево cmark (`OpaquePointer`) наружу из парсера не выходит (решение 4 главного плана); поэтому повторный разбор в адаптере невозможен, а старые ключи-указатели (`RemoteImageMarkers` и др.) исчезают с `renderBody`.
- Поздние результаты: версия — в `model.revision`; `markdownModel(forRevision:)` не отдаёт устаревшую; предпросмотр дополнительно сверяет `coordinator.isCurrent`, `generation`, `document.url`, `allowsRemoteImages` (существующий `apply`).
- Модель не должна пережить смену `language`/правку: сброс в `nil` в тех же местах, что и `markdownReadableText`; публикация — только в главном потоке после проверки `contentRevision`.

## 4. Где ещё используются подготовительные функции

| Функция | Вызывающие помимо `MarkdownRenderer` | Что с ними |
| --- | --- | --- |
| `MarkdownObsidianComment.hidden(String, syntax:)` | тесты `MarkdownObsidianCommentTests` (14 вызовов) | см. раздел 5 |
| `MarkdownObsidianComment.hidden(NSString, ranges:)` | **`MarkdownSourceMask.keepsParagraphFlags` (U2.2)**, тесты | правило переносится в маску (U4.4 п. 4) |
| `CriticMarkupRender.prepare` | `MarkdownSourceMaskTests.swift:215` (сверка длины строк), `CriticMarkupRenderTests` (4), `MarkdownNoteEmbedTests` нет | тесты переводятся; `CriticMarkupService` не использует |
| `CriticMarkupRender.finalize` | только `MarkdownRenderer.swift:466` | удаляется |
| `MarkdownNoteEmbed.prepare` | `MarkdownNoteEmbedTests` (141, 243, 259) | тесты переводятся |
| `MarkdownNoteEmbed.finalize`, `substitutingWikiLinks`, `renderBody` | только `MarkdownRenderer.swift` | удаляются |
| `MarkdownCalloutRender.separatingTitles` / `transform` | `MarkdownCalloutTests` (57–59; 186, 193–194), `MarkdownRenderer.swift` | тесты переводятся |

Остаются нетронутыми: `MarkdownWikiLinkRewriter` (нужен Pandoc), `CriticMarkupRender.items`/`resolved` (нужны маске и командам).

## 5. Тесты к переводу (файл, число строк с вызовами `MarkdownRenderer.render*`; всего ≈ 310 строк в 28 файлах)

Общий приём: у строкового входа `MarkdownHTMLRenderer.renderPage(_ markdown:…)` **те же метки параметров** (U3.1 п. 1.1: `includeHTMLMedia`, `renderEmoji`, `resolveLocalImages`, `documentURL`, `prepareRemoteImages`, `syntax`, `forExport`, `includeHeadingNumbers`, `includeListStyles`, `staticWidgetFallback`, `preserveRawHTMLBlocks`, `includeSourcePositions`, `isPreview`, `highlightCode`, `wiki`, `critic`, `embeds`, `hidesObsidianComments`), поэтому перевод для большинства файлов — механическая замена имени типа; ожидания не меняются. Нужно решить судьбу `MarkdownRenderer.render(_:darkMode:) -> String` (только тела, ~36 вызовов): либо оставить такую же короткую `MarkdownHTMLRenderer.render` в адаптере (проще), либо заменить на `.renderPage(…).html`. Предлагаю оставить (одна строка, ни одного нового ожидания).

| Файл | Вызовов | Особенности |
| --- | --- | --- |
| `MarkdownRendererTests.swift` | 192 (184 `renderPage` + 8 `render`) | механическая замена; файл не переименовывать (или — на `MarkdownHTMLRendererTests`, решает основной агент; тогда обновить `docs/agents/testing.md:38`) |
| `UIPolishJTests.swift` | 18 | механическая; плюс `:150` `MarkdownRenderActor().render("")` без изменений |
| `TaskListEditingTests.swift` | 10 | механическая |
| `UIPolishBTests.swift` | 8 (6 `render`) | механическая |
| `PandocImportTests.swift` | 8 (`render`) | механическая |
| `BaselineSupport.swift` | 7 (297–323) | механическая; это эталоны U0.1 — сверка идёт к тем же файлам, переписывать только пункты «Намеренные изменения HTML» |
| `MarkdownTableEditingTests.swift` | 7 | механическая |
| `MarkdownObsidianCommentTests.swift` | 7 + 14 `hidden` | **содержательная**: `testHiddenKeepsLineCountAndPreview` (стр. 72), `testCommentLineDoesNotBreakParagraph` (115–130, ~13 проверок `hidden`), `testInlineComments`/`testMultilineComments`/`testPlainTextSkipsParsing` (27, 35, 152). Проверка «строка не рвёт абзац» → признак `keepsParagraph` и `occupiesWholeLines` у сегментов `MarkdownSourceMask` для тех же входов (`<p>…</p>` в HTML вместо U+200B в тексте) + проверка HTML адаптера; «число строк прежнее» → `data-sourcepos` |
| `MarkdownCalloutTests.swift` | 7 + 3 `separatingTitles` + 3 `transform` | `separatingTitles` (57–59) → HTML строки-маркера с `lac-callout-text` при `preserveEditingSoftBreaks` true/false (уже частично есть выше, стр. 44–55); код не превращается в выноску; `transform` (186, 193–194) → `forExport: true` раскрывает свёрнутые, обычная страница без выносок не содержит `lac-callout`; `mayContainCallout` (192) — удалить вместе с функцией, сценарий «обычный HTML не меняется» остаётся через `renderPage` |
| `MarkdownRubyOutputTests.swift` | 5 | механическая |
| `MarkdownFormattingServiceTests.swift` | 5 | механическая |
| `PandocExportTests.swift` | 4 | механическая |
| `MarkdownPreviewTests.swift` | 4 + 1 актор | механическая; `:707` замыкание получает 7-й аргумент |
| `MarkdownNativeTableInteractionTests.swift` | 3 | механическая |
| `MarkdownWikiLinkRewriterTests.swift`, `MarkdownNoteEmbedTests.swift`, `MarkdownLinkEditingTests.swift`, `MarkdownFootnoteTests.swift`, `CriticMarkupRenderTests.swift` | по 2 | `MarkdownNoteEmbedTests`: 3 `prepare` → HTML (`<img src="pic.png" alt="pic.png">`, `<a href="doc.pdf">`, `<em>Attachment unavailable: …</em>`, `<img src="../pic.png"` через `renderPage(… documentURL:, wiki:)`), `testPrepareKeepsLineCount` → один блок `lac-embed` и `data-sourcepos` соседних абзацев; `CriticMarkupRenderTests`: `prepare` (34, 41, 105, 115) → `body(…, .show/.result)` (`markerBase == nil` ⇒ HTML равен обычному; число строк ⇒ `data-sourcepos`; «таблица/front matter/формула нетронуты» ⇒ в HTML остаются `{++x++}`; `.result` даёт «not saved yet») |
| `TyporaBaselineTests`, `MarkdownSpecConformanceTests` (172), `MarkdownMathExtensionTests`, `MarkdownLinkNavigationTests`, `MarkdownInlineHTMLTests`, `MarkdownImageEditingTests`, `MarkdownNativeTableParserTests`, `MarkdownExportImagesServiceTests` | по 1 | механическая; `MarkdownSpecConformanceTests` сверяет **новый** адаптер (планка U0.3 — нижняя) |
| `MarkdownSemanticConsistencyTests` | 1 | удалён в U2.6 |
| `MarkdownSourceMaskTests.swift` | 1 `prepare` (215) | `testMaskKeepsLineCountOfOldShowPreparation` → фиксированное число строк (оно равно числу `\n` исходника) без старого оракула |

Тесты на Linux: `swiftc -frontend -parse` каждого изменённого; стенд `lac-writer-check/run-tests.sh` (все перечисленные файлы там собираются; новый `EditorDocumentMarkdownModelTests` в `test-files.txt` **не** класть, если он не собирается со стабами `EditorDocument` — тогда помечается «только Mac» в `TEST_STATUS.md`). Ожидания не ослаблять; если тест противоречит новому адаптеру — это запись в «Намеренные изменения HTML» (U3.4), а не правка ожидания.

## 6. Параллельность и распределение файлов

- U4.1 → (U4.2 ‖ U4.3) → U4.4. U4.2 меняет `MarkdownPreview.swift`, тест панели; U4.3 — `MarkdownPDFExportService.swift`, `WriterCombinedPage.swift`, `MarkdownExportImagesService.swift` (+ их тесты). Пересечений нет.
- В U4.4 один исполнитель на удаление (общие файлы), перевод тестов можно разнести: (а) `MarkdownRendererTests`; (б) остальные механические; (в) содержательные Obsidian/Critic/Callout/NoteEmbed/SourceMask. Группы (а) и (б) идут сразу после U4.2/U4.3; (в) вместе с удалением функций.
- Общие файлы правит основной агент: `project.pbxproj`, `Scripts/verify-release.sh`, `Scripts/run-acceptance.sh`, `docs/TEST_STATUS.md`, `lib-files.txt`, `test-files.txt`.

## 7. Риски

1. **Горячий путь (ввод).** Второй проход контроллера (модель) — лишняя работа в фоне на каждую паузу разбора при видимой панели; на больших документах это может заметно нагрузить очередь, где идут и старые разборы. Смягчение: только при видимой панели, не при `isLargeFileMode`, не при `hasMarkedText`, отменяется вместе с операцией; замеры P1–P9 до/после на Mac. Если замер плох — публикацию модели отложить до U6.1 (п. 1 «Спорного»).
2. **Задержка предпросмотра.** Новый путь не должен быть медленнее старого: HTML-адаптер пишет строку сам (раньше `cmark_render_html`); разбор по-прежнему в акторе. Дебаунс, `renderTask`, `isCurrent` не трогаются. Проверить на корпусе U0 время `renderPage` (стенд, грубо) и на Mac — «Открыть документ ~1 МБ с панелью», набор текста с панелью.
3. **Несовпадение настроек модели и рендера** (`wiki`/`critic`/`isVaultNote`/`syntax`) → неправильный HTML без ошибки. Защита — `accepts` + тесты на каждый параметр (модель с критиком, рендер без критика → разобрать самим или вывести срезом).
4. **Экранный и файловый текст** (токены `data:`): разные диапазоны — модель публикуется только при пустой карте токенов (п. 1.2).
5. **Порядок удаления.** Если `MarkdownSourceMask.keepsParagraphFlags` удалить вместе с `hidden` без переноса правила — маска сломается; поэтому п. 4 в U4.4 идёт **до** удаления и подтверждается сравнением на корпусе.
6. **Орфаны.** После удаления у приватных помощников могут не остаться вызовов — Swift не ругается; проверять `rg` вручную (критерии ниже).
7. **Только Linux.** WebKit, актор панели, контроллер на TextKit проверяются только на Mac; до этого задача «готова на стенде».

## 8. Проверки и критерии «ничего не осталось»

Перед завершением U4.4 (результат — в статус задачи):

```sh
rg -n "MarkdownRenderer\b" LacEditor LacEditorTests Verification Scripts Package.swift LacEditor.xcodeproj docs/agents   # пусто (TEST_STATUS.md — журнал, исключить)
rg -n "renderBody|substitutingWikiLinks|separatingTitles|MarkdownCalloutRender\.transform|CriticMarkupRender\.(prepare|finalize)|MarkdownObsidianComment\.hidden|MarkdownNoteEmbed\.(prepare|finalize)" LacEditor LacEditorTests   # пусто
rg -n "RemoteImageMarkers|LocalMediaMarkers|RawHTMLBlocks|ListDepths|markerBase|MarkdownNoteEmbed\.Prepared|CriticMarkupRender\.Prepared" LacEditor LacEditorTests   # пусто, кроме одноимённых типов контекста адаптера (U3.2 `MediaContext`)
rg -n "MarkdownRenderer\.swift" LacEditor.xcodeproj ~/tools/lac-writer-check/lib-files.txt   # пусто
rg -c "MarkdownRenderedPage.swift" LacEditor.xcodeproj/project.pbxproj   # 4 записи
```

Орфаны: для каждого оставшегося приватного помощника в `CriticMarkupRender.swift`, `MarkdownNoteEmbed.swift`, `MarkdownCalloutRender.swift`, `MarkdownObsidianComment.swift` (`tagName`, `attributeEscaped`, `commentLabel`, `freeBase`, `lineBreaks`, `fileReplacement`, `escaped`, `markerRange`, `callout(in:`, `attribute`) — `rg` находит вызывающего вне собственного определения.

Прогоны: стенд `lac-writer-check` (`run-tests.sh`), `swiftc -frontend -parse` всех изменённых; `git diff --check`; на Mac — тесты панели, PDF, сводного просмотра, `MarkdownPreviewTests`, ручная проверка панели (прокрутка, смена темы, `critic`, wiki, `![[…]]`), `fullParseCount` при вводе.

Критерий `renderPage` из главного плана (U4.4 и U8.2): адаптер называется `MarkdownHTMLRenderer.renderPage`, поэтому «`rg renderPage` пусто» невозможно. Предлагаю в U8.2 заменить на `rg "MarkdownRenderer\.|renderBody"` (см. «Спорное», п. 3).

## Спорное (для утверждения основным агентом)

1. **Нужна ли публикация модели в U4.1 до U6.1.** При наборе модель контроллера (пауза ≥ 0,6 с) не успевает к рендеру панели (0,18 с), а контроллер временно делает третий разбор на версию. Выигрыш — только повторный рендер той же версии и показ панели. Вариант Б: в U4.1 только слот в `EditorDocument` и `markdownModel(forRevision:)`, а публикацию из контроллера включить в U6.1 (когда контроллер всё равно строит модель); тогда U4.2 берёт модель из слота, если она есть, иначе разбирает сам. Рекомендую вариант Б, если замер P1–P9 с двойным построением окажется плохим; план написан по вашей постановке (вариант А).
2. **`MarkdownClipboardCopyService` в U4.3.** Это не потребитель HTML-страницы, а ~2000 строк обхода cmark для фрагмента выделения; у адаптера нет режима «вывести HTML фрагмента по диапазону блоков» (формат `Fragment.html` другой: `<img src="`, `<pre><code`, без `data-sourcepos`, `HARDBREAKS`). Перевод — отдельная большая задача (модель + выделение + сверка с `Fragment` на корпусе). Рекомендую вынести в отдельную задачу после U4.4 (например U4.5 или в U7) и не блокировать ею удаление `MarkdownRenderer`. `MarkdownExportImagesService` (малая) оставляю в U4.3 и убираю из U7.1.
3. **Имя `renderPage` у адаптера** противоречит критерию U8.2 (`rg renderPage` — пусто). Либо оставить имя (меньше правок в ~310 тестовых строках) и переписать критерий, либо назвать `MarkdownHTMLRenderer.page(...)` (тогда замена тестов не механическая). Рекомендую оставить имя.
4. **`MarkdownRenderer.render(_:darkMode:)`** (только тело, ~36 вызовов): оставить аналог `MarkdownHTMLRenderer.render` или заменить на `.renderPage(…).html`. Рекомендую оставить.
5. **Вынос `MarkdownRenderedPage`** (строки 1–390) — в U3.1 (раньше) или в U4.4 (шаг 0). Рекомендую в U3.1: адаптер не должен жить рядом с удаляемым файлом.
6. **Единый список `swiftc` в `Scripts`** (п. 1.7) придётся расширять: `EditorDocument` потянет модель, `MarkdownSyntaxOptions`, индексы. Альтернатива — хранить модель в `EditorDocument` как `Any`-обёртку/протокол без зависимостей (хуже читается). Рекомендую расширить списки.

## Записи в общие файлы (вносит основной агент)

- `project.pbxproj`: новые `Models/…` нет; новые `Preview/MarkdownRenderedPage.swift` (4 записи) вместо `MarkdownRenderer.swift`; `LacEditorTests/EditorDocumentMarkdownModelTests.swift` (если проект перечисляет тесты явно; AGENTS.md говорит, что берёт из папки).
- `Scripts/verify-release.sh` (~51), `Scripts/run-acceptance.sh` (68, 111): добавить модель и её зависимости к спискам с `EditorDocument.swift`.
- `~/tools/lac-writer-check/lib-files.txt`: стр. 79 `Preview/MarkdownRenderer.swift` → `Preview/MarkdownRenderedPage.swift`; `test-files.txt`: новые/переименованные тесты.
- `docs/TEST_STATUS.md`: «на Mac не запускался» для новых тестов и перенесённых ожиданий; `docs/markdown-unified-model-plan.md`: статус U4.1–U4.4, раздел «Намеренные изменения HTML» (если перевод тестов выявил отличия).

## Решения основного агента

1. Порядок U4.1 → (U4.2 ‖ U4.3) → U4.4 принят.
2. Типы `MarkdownRenderedPage`, `MarkdownTypography`, `MarkdownRenderedMath`, `MarkdownRenderedDiagram` выносятся в `Preview/MarkdownRenderedPage.swift` уже в U3.1 (внесено в `U3.1-plan.md`).
3. Правила `afterPrefix`/`isBlankLine`/`isInsideParagraph` уже вынесены в U2.2 как `internal static` у `MarkdownObsidianComment`; в U4.4 они переезжают в `MarkdownSourceMask` (перенос), `hidden` удаляется.
4. Принято: модель отдаётся предпросмотру только при совпадении версии и пустой карте media-токенов.
5. U4.1 — только слот модели в `EditorDocument`; публикация из контроллера — в U6.1 (решение 7 «один разбор на версию»: третий разбор на горячем пути не добавляем).
6. Собственный разбор `MarkdownClipboardCopyService` — отдельная задача U4.5 после U4.4 (не исключается: старый код удаляется целиком). `MarkdownExportImagesService` — в U4.3, из U7.1 убрать.
7. Имя `renderPage` у адаптера сохраняется; критерий U8.2 — «`rg "MarkdownRenderer\b"` пусто».
8. Короткий `MarkdownHTMLRenderer.render` (только тело) — принят.
