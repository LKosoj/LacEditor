# U5 — TextKit-адаптер (U5.1–U5.3) и оформление Obsidian/CriticMarkup в редакторе (U5a.1–U5a.4)

Статус: план (код не менялся), 05.11.2026. Номера строк — по рабочей копии: `Preview/MarkdownPresentationParser.swift` (3538 строк, далее «парсер»),
`Models/MarkdownPresentation.swift` (1930), `Editor/EditorCoordinator.swift`, `Editor/MarkdownPresentationController.swift`, `Editor/FoldLayoutManager.swift`.
Опора: главный план (решения 1, 2, 5, 6, 9; этапы 5, 5а, 6), U2.3, U2.5, U3.3 (контракт R1–R9), `docs/agents/{markdown-editor,editing,vault,performance}.md`.

## 0. Что делаем простыми словами

Сейчас редактор берёт данные оформления (где жирный, где скрыть `**`, где таблица) прямо из дерева cmark внутри парсера на 3500 строк.
После U2 есть общая модель документа. U5.1 пишет «переводчик» `MarkdownPresentationBuilder`: берёт модель и выдаёт тот же `MarkdownPresentation`,
который уже умеет рисовать TextKit. Читать cmark он не должен вообще. U5.2 доказывает, что переводчик выдаёт то же, что парсер (по эталонам U0.2).
U5.3 убирает лишнее из `MarkdownPresentation`. U5a учит редактор красить CriticMarkup, приглушать `%%`, оформлять выноски и `![[…]]` из той же модели
(сейчас это отдельные «подкрашивания» поверх подсветки в `EditorCoordinator`).

Главные находки (проверены поиском по коду):
1. Сдвиг оформления (`shift`, `canShift`, `removeTouched`, `prepareForEditing`, `spanEnds`, `completedEnds`, `isReadyForShift`) — это **горячий путь ввода**:
   его вызывают `MarkdownPresentationController` (стр. 441–442, 1985, 2047–2077, 2156–2207), `FoldLayoutManager.shiftMarkdownPresentation` и `MarkdownPresentation+Splice`
   (сверка локального разбора). После U6 вызывающие остаются. Пункт «U5.3 удаляет сдвиг» из главного плана сломал бы набор текста — см. спорный пункт 1.
   Единственное, что вызывается только из тестов и стенда, — `shiftedForTextEdit`.
2. Цвета CriticMarkup и `%%` сегодня видны и **в режиме исходника** (без оформления): `reapplyCriticColors` не проверяет «оформление включено». Новый путь должен это сохранить (U5a, п. 3.2).
3. Пока контроллер вызывает старый разбор (до U6.1), span-ы новых видов в живом редакторе не появятся. Удалять `reapply*` можно только в связке с U6.1 (спорный пункт 2).

## 1. U5.1 — `Editor/MarkdownPresentationBuilder.swift`

Вход: `MarkdownDocumentModel`, `text: NSString` (исходный, для подстрок), `BuildOptions` (флаги показа: `includeEmojiCandidates`, `includeReadableText`, `wikiLinks`, `syntax`), `isCancelled`.
Выход: `MarkdownPresentation` (инициализатор + `withWikiLinks/withUnreliableRanges/withElements`, как в парсере стр. 3441–3447; эти три метода остаются).
Без AppKit/SwiftUI/cmark (иначе не соберётся на стенде). Ничего из старого парсера не копируется: функции с общей логикой переезжают (решение 5), у парсера они остаются вызовами оттуда.
Данные, которые считает ядро (U2.5), адаптер переносит как есть: `readableText`, `emoji` → `emojiCandidates/emojiCompletionRanges/smartTextRanges/smartRawHTMLRanges`,
`smartReplacements` → `textReplacements`, `fence` → `fence*`, `elements`, `looseIndents`, `unreliableRanges`, `headings.uppercaseRuns`, `footnotes`, `namedAnchors`.

### 1.1. Что и откуда переносится (парсер → адаптер)

| Что | Сейчас в парсере | Как в адаптере |
| --- | --- | --- |
| spans heading/strong/emph/strikethrough/code/link/quote/codeBlock + `markerRanges` | `visit` 2672–2722 (switch 2686–2720); отложенные «mapped» 3014–3041 (`delayedMapped*`, `confirmedInlineRange` 1841) | Обход `blocks`/`inlines` модели: вид узла → `MarkdownPresentationKind`, `markerRanges` узла → маркеры. «Подтверждение» позиции уже сделано ядром (`isUnreliable`); узел без подтверждённого диапазона span не получает, как сейчас (`flagUnreliable` 1823 → `unreliableRanges` из модели) |
| подчёркивание, highlight, sub/sup, strikethrough→subscript | `underlines` 1060, `underline` 853, `inlineDecorations` 1134, `subscriptRange` 1096, `superscriptRanges` 1112, `highlightRanges` 1170; вызовы 2674–2685 | Узлы модели `.underline/.highlight/.subscriptText/.superscriptText` → span. Функции становятся частью ядра (U2.3), в адаптере их нет |
| inlineStyle, `<kbd>`, пары inline-HTML + `links` из `<a>` | `inlineHTMLPairs` 972, `isSpanOpening` 922, `inlineAnchorHref` 879; 2970–2985 | `.inlineStyle/.keyboard` → span; `.link(form: .html)` → `links` |
| alert | `alert` 1148; 2478–2480 | `Alert` → `.alert(label)` + маркер `[!NOTE]` |
| front matter | 1723 | `model.frontMatter` → `.yaml` с `markers` |
| footnote reference span | 2512 | `.footnoteReference` → `.link` без маркеров |
| `listMarkers` | 2140–2164 (маркер пункта, `line`, текст `•`/`N.`, ordinal, depth) | `ListItem.markerRanges[0]`, `ordinal`, `ListBlock.depth/marker`. Текст: `•` или `\(ordinal).`; пункты-задачи (`task != nil`) маркера не дают |
| `looseIndents` | 3441 (`MarkdownMathExtension.looseIndents`) | `model.looseIndents` (U2.5, `.editorContext`) |
| `paragraphs`, `separatorAfter` | 2335–2350 (диапазон целых строк, `referencePrefix`), 3262–3291 (пустая строка между абзацами с учётом `>`) | `paragraph` узлы: `range` целых строк, `lastLine`; `separatorAfter` — по соседним абзацам одного контейнера, глубину `>` берёт из `containerPrefixes`. Это чистая арифметика по диапазонам и тексту |
| чекбоксы | 2515–2528 (`taskCheckbox`, `quotedTaskCheckbox`, `completedTaskRanges`) | `ListItem.task` → `taskCheckboxes`; `state != 32` → `completedTaskRanges` (range пункта) |
| `tables` + `tableDisplay`/`renderedCell`/`projection` | 2352–2383 (контекст цитат/списков, `presentationTable`), 480–566, 596, 610–788, 790–850, перерисовка при подтверждении HTML 2938–2950 | см. п. 1.2 |
| `codeBlocks`, `diagrams`, `formulas`, `images`, `audioBlocks`, `iframeBlocks`, `detailsBlocks`, `htmlBlocks`, `pageBreaks`, `ruby`, `tableOfContents` | в `visit` и пост-проходах 2860–3010 | Прямое отображение: `CodeBlock` + `bodySegments/infoRange/isClosed`, маркеры ограждений — `markerRanges` узла, `continuationPrefix/isNested` — из `containerPrefixes` узла (по U2.4); `HTMLBlock.Kind` → audio/iframe/details/page break/raw; `Image.sizing/isBlock` → `MarkdownImage.isInline`; ruby → `MarkdownRuby` |
| `wikiLinks` и span `.link` для них | 3395–3420 (исключения: ссылки, картинки, таблицы, заголовки, формулы, ruby, HTML-блоки…) | Узлы `.wikiLink` → `MarkdownWikiLink` (`markerRanges` и `displayRange` уже есть) + span `.link`. Исключения уже учла маска/ядро |
| показ: `overlapsMedia` | 2863–2889 | см. п. 1.3 |
| показ: `blockedHTML` | 2913–2919 (сливает `filteredHTML.blocked` 928 и `unconfirmedRubyRanges` 1521); применение 3342–3392 | см. п. 1.3 |
| показ: `safeText` | 3320–3340 | см. п. 1.3 |

### 1.2. Таблицы (`MarkdownPresentationBuilder+Table.swift`)

- `tableDisplay` сегодня идёт по узлам cmark (`nodeRows`, `source.tableCellPositions`, `renderedCell(cell: OpaquePointer…)` 610–772). Новая версия идёт по `Table.Rows[].cells[].inlines`:
  одна функция `renderedCell(inlines:, cell:, …)` даёт `(displayText, [MarkdownTableTextRun])` по видам `.strong/.emphasis/.strikethrough/.code/.link/.formula/.image/.emoji/.keyboard/.inlineStyle`, softBreak → `\n`, сжатие пробелов (`preserveEditingWhitespace`).
  Результат должен совпасть побайтно (эталон `tables` и `displayRuns`).
- `projection` (480), `tableCellTransforms/tableCellBreaks` (790–850), `tableRowDisplay` (596), `referenceLabel` (568) и строковый `renderedCell(raw…)` (774) нужны правке ячейки (`MarkdownTableCellEditor.swift:38–44`, `EditorCoordinator.swift:2329`) и не зависят от дерева документа.
  Они **переезжают** в `+Table.swift`; два вызывающих переименовываются в той же задаче. Внутренний cmark-разбор текста одной ячейки (стр. 785–788) заменяется вызовом ядра (`MarkdownDocumentParser` над строкой ячейки, абзац → `inlines` → та же `renderedCell(inlines:)`). Так cmark остаётся только в ядре (U8.2).
- Узловая версия `tableDisplay(node:)` остаётся в парсере до U8 — это другой вход, не копия: общие куски (`projection`, `referenceLabel`, `tableCellTransforms`) вызываются из нового файла.
- Контекст `containerPrefix/quoteDepth/nestedList` и `MarkdownTableEditingService.presentationTable` (вызов 2379) берутся из `containerPrefixes` узла таблицы; если ядро не даёт префикс — адаптер подставляет `presentationTable(in:range:…)` как сейчас (это не cmark).

### 1.3. Отсев показа (`MarkdownPresentationBuilder+Filter.swift`, чистые функции над диапазонами)

Это решение редактора «что показано картинкой/медиа/сырым HTML, под тем нельзя красить текст». Модель этого знать не должна (U2.5, спорное 3), поэтому переносится целиком:
- `overlapsMedia(range)`: двоичный поиск по диапазонам audio+iframe с префиксными максимумами (2863–2889); удаляет `images`, `inlineFormulas`, `emojiCandidates`, лежащие внутри медиа.
- `blockedHTML`: диапазоны неподтверждённых строчных HTML-тегов и ruby. Источник в модели — строчные узлы `.rawHTML` без подтверждённого вида (по контракту U2.3: стилевые теги, не вошедшие в пару `.inlineStyle/.keyboard/.underline`, и теги ruby без `.ruby`). Слияние как в 2913–2919.
  Применение — список полей 3345–3373 (spans, links, anchors, images, media, details, html, pageBreaks, ruby, diagrams, formulas, emoji, completion, wiki, smart, safeText, paragraphs, checkbox, listMarkers, footnotes, toc, codeBlocks); заголовки теряют `number/plainTextRange/uppercaseRuns`; ячейки таблиц внутри — `displayText = исходник`, `displayRuns = []`.
- `safeText`: `smartReplacements` минус диапазоны картинок, медиа, details, html, ruby, диаграмм, формул, эмодзи, таблиц, оглавления (3320–3340).
- Порядок как сейчас: overlap → ruby/SVG-подтверждение (у ядра) → safeText (по полям до отсева) → blocked → wiki. Проверка — U5.2.
- Риск: если ядро не помечает неподтверждённые теги как `.rawHTML`, `blockedHTML` не восстановить. Проверить в начале U5.1 по `Fixtures/RenderBaseline/Corpus` (html, ruby, inline CSS); при дыре — правка контракта в U2.3 до начала U5.1.

### 1.4. Новые виды блоков модели
Показываются как обычный текст (без span): `callout`, `critic`, `comment`, `noteEmbed`, `mathBlock` кроме уже известных редактору. Четыре вида этапа 5а добавляются в U5a, не здесь.

### 1.5. Подзадачи U5.1 и параллельность
| Шаг | Файл | После чего | Параллельно с |
| --- | --- | --- | --- |
| U5.1.0 сигнатуры: `BuildOptions`, `build(...)`, пустые `+Table`/`+Filter` | основной файл | U2.3 (типы модели есть с U1.1) | — |
| U5.1.a обход модели: spans, маркеры, списки, абзацы, чекбоксы, прямые отображения, `elements`/`emoji`/`fence`/`readable` | `MarkdownPresentationBuilder.swift` | U2.3, U2.4, U2.5 | b, c |
| U5.1.b таблицы и переезд функций ячеек | `+Table.swift`, два места вызова | U5.1.0, U2.3 | a, c |
| U5.1.c отсев показа | `+Filter.swift` | U5.1.0 | a, b |
| U5.1.d склейка a+b+c, тест `MarkdownPresentationBuilderTests` (малые случаи: кириллица, CJK, эмодзи, `\r\n`, цитата в списке, таблица с формулой) | тест | a, b, c | — |
Файлы стенда (вносит основной агент): `~/tools/lac-writer-check/lib-files.txt` ← `Editor/MarkdownPresentationBuilder{,+Table,+Filter}.swift`; `test-files.txt` ← `MarkdownPresentationBuilderTests`; `LacEditor.xcodeproj`, `Package.swift` (список исходников). Файлы без AppKit.
Проверки: `swiftc -frontend -parse` по каждому файлу; `lac-writer-check/run-tests.sh`. Mac: не нужен.

## 2. U5.2 — сверка с эталонами оформления

1. `LacEditorTests/BaselineSupport.swift`, `PresentationBaselineSet.parse` (стр. 478–489): тело переключается с `MarkdownPresentationParser.parse(...)` на `core → builder` с теми же флагами (четыре набора: `editor`, `editor-loose`, `editor-numbered` (+`numberingHeadings(true)`), `editor-minimal`). Переключателей «старый/новый» нет (решение 9): пока тест на адаптере, эталон = «правда о парсере».
2. Старый эталон сохранить копией в scratchpad (файлы `Fixtures/PresentationBaseline/*` не в git: `??`), прогнать без `LAC_RECORD_BASELINE`. Падение печатает первую разницу `BaselineStore.difference`; для разбора нужен свой разбивающий прогон: стенд пишет новый файл в scratchpad и сравнивает по блокам `=== id` и полям — выводит счётчик «поле × число документов» и 10 первых id по каждому полю.
3. Порядок разбора (от фундамента): `unreliableRanges` → `elements` → `spans` (заголовки, quote, codeBlock, затем inline) → `listMarkers/paragraphs/taskCheckboxes/completedTaskRanges/looseIndents` → `tables` (display/runs) → медиа (`images`, `audioBlocks`, `iframeBlocks`, `detailsBlocks`, `htmlBlocks`, `ruby`, `diagrams`, `pageBreaks`) → `formulas/inlineFormulas/footnotes/tableOfContents/namedAnchors` → `emojiCandidates/emojiCompletionRanges/smartTextRanges/smartRawHTMLRanges/textReplacements` → `fence*` → `readableText` → `wikiLinks`.
   Если падают сразу несколько полей — чинить самое раннее: следующие часто его следствия.
4. Каждое отличие получает класс:
   - **А. Ошибка адаптера/ядра** — исправляется, эталон не трогается.
   - **Б. Расхождение редактора и панели** (решение 1: верна панель) — критичное исправляется в пользу панели; запись в раздел «Изменения оформления в редакторе» главного плана (документ, поле, было → стало, причина), правило в `docs/agents/markdown-editor.md`, эталон переписывается только для этих документов (`LAC_RECORD_BASELINE=1`, `git`-слежки нет: копию «до» хранить в scratchpad и положить список в отчёт).
   - **В. Некритичное Б** — тоже записывается; эталон переписывается вместе с правилом.
   Пример без класса тест не пропускает. Известные кандидаты в Б: callout (сегодня просто цитата — будет в U5a), встраивания, `data-sourcepos`-независимые вещи не относятся.
5. Известный риск: `elements` парсер строит после отсева `blockedHTML` (стр. 3399–3412 берёт spans после удаления). Если ядро строит `elements` до отсева, поле разойдётся; тогда адаптер фильтрует `elements.inlines` по blocked, а не ядро.
6. Готово: 4 набора проходят; список Б записан в главный план; `testPresentationFieldListIsComplete` проходит.
Проверка: `lac-writer-check/run-tests.sh` (тесты U0.2 в `test-files.txt` уже есть). Mac: один прогон `MarkdownPresentationBaselineTests` (различия Foundation Linux/macOS, как в статусе U0).

## 3. U5.3 — чистка `MarkdownPresentation`

Все вызывающие (по `rg` на 05.11.2026, приложение; тесты и стенды отдельно):

| Имя | Вызывающие в приложении | Тесты/стенд | Можно удалить |
| --- | --- | --- | --- |
| `shiftedForTextEdit` (1584) | **нет** | `MarkdownPresentationTests` (~15), `MarkdownDisplayMapTests` 348/350, `lac-check/main.swift` 478–513 | **да, в U5.3 до U6** — тесты переписать на уже существующий helper `parsedForShift` + `canShift` + `shift` |
| `shift` (1363) | контроллер 2051, 2073, 2077 | много | нет, пока жив быстрый ввод |
| `removeTouched` (1471), `MarkdownTouchedElements` (854) | контроллер 2067, `dropTouched` 2089 | `MarkdownPresentationTests` 443, 468 | нет |
| `canShift`, `canShiftElements`, `firstAffectedLocation`, `paragraphBreakEdit`, `allowsTypingEdit`, `MarkdownTextEdit` | контроллер 2048, 2156–2174, `FoldLayoutManager` | `MarkdownLayoutTests`, `MarkdownPresentationTests`, `lac-check` | нет |
| `prepareForEditing`, `spanEnds`, `completedEnds`, `isReadyForShift`, `isTextStructureOnly` | контроллер 441–442, 1985, 2172, 2206; `MarkdownLocalParser` 50–51; `Splice` 246, 317–320 | `BaselineSupport.excludedFields` (475) | нет |
| `withWikiLinks`, `withUnreliableRanges`, `withElements`, `mergedRanges` | сборка адаптера (`mergedRanges` ещё и ядро, U2.5 п. 2.8) | — | нет, адаптер ими пользуется |
| `MarkdownHeadingAnchors.Allocator`, `MarkdownElementIndex` | ядро, модель | — | нет (теперь общий слой, не «разбор редактора») |

Итог: после U6 в `MarkdownPresentation` удалять нечего, кроме `shiftedForTextEdit`. Пересмотр «сдвига целиком» возможен только как отдельное решение о новом быстром пути ввода (после замеров на Mac) — не часть U5.3.
Порядок: (1) удалить `shiftedForTextEdit`, переписать его тесты (один проход, стенд зелёный); (2) после U6.4 — поиск по `rg` на мёртвые остатки (`isUnshiftable` и т. п. остаются, пока их кто-то вызывает); (3) комментарии в `MarkdownPresentation.swift`, ссылающиеся на парсер, обновить; (4) `docs/agents/performance.md` стр. 17 — убрать упоминание, что сдвиг «после разбора парсера», если оно есть; `check-howto.md` стенда lac-check: переименовать заголовок («shiftedForTextEdit» → «shift»).

## 4. U5a — оформление CriticMarkup, `%%`, выносок и `![[…]]` в редакторе

### 4.1. Что есть сейчас
- `EditorCoordinator.reapplyCriticColors` (6166–6188): по окну абзаца ищет правки `CriticMarkupService.items` (запреты — `MarkdownElementIndex.excludedRanges`), красит временным `.foregroundColor` (`criticColor` 6153–6161, цвета `NSColor.lacCritic*Text` в `SyntaxHighlighter` 1244–1275).
- `reapplyObsidianCommentColors` (6190–6219): только заметки хранилища, только текст ≤ 300 000 UTF-16, весь текст один раз на версию (`obsidianCommentCache` 213), `lacCommentText`.
- `reapplyVaultPageDim` (6221–6232): арифметика над кэшем охранника страницы, `lacMutedText`; **не меняется**, но обязан идти после новых цветов (он их перекрывает).
- Вызовы всех трёх: 4235–4237 (колбэк `parsedResultDidChange`, `MarkdownPresentationController` 483, 1923), 5902–5904 (после применения токенов подсветки), 6005–6007 (после прокрутки/снятия подсветки); очистка `clearCriticHighlights` (6235) и флаг `hasCriticColors` (212).
- `criticElementIndex` (контроллер 1221) нужен ещё и команде `applyCriticMarkup` (`EditorCoordinator` 1665: индекс → запретные зоны) — это **не** только окраска.
- Выноски `> [!тип]` — просто цитата (курсив + фон); алерт GitHub — span `.alert(label)` с маркером `[!NOTE]`, подпись рисует `FoldLayoutManager` (1841–1860, список `markdownAlerts` 2028).
- `![[…]]` не находится в редакторе (`MarkdownWikiLinkExtractor` стр. 30 пропускает `[[` после `!`). Cmd-клик: `EditorCoordinator` 715–735 (`follow` → `parsed.wikiLinks` → `followWikiLink` → `wikiNavigationLink` 784 → `fileAddress(for:)`), запасной разбор — 740.

### 4.2. Новые виды span (U5a.0, общий шаг; правит `MarkdownPresentation.swift`, `FoldLayoutManager` список маркеров)
В `MarkdownPresentationKind` добавляются: `.critic(CriticMarkupKind)`, `.obsidianComment`, `.callout(label: String, kind: MarkdownCalloutKind?)`. Embed: не span-вид, а запись в `wikiLinks` (`MarkdownWikiLink` + поле `isEmbed: Bool = false`) и обычный span `.link`.
- `.critic`/`.obsidianComment` — строчные: добавить в список `inline` (`FoldLayoutManager` 2030–2036) и в группу «строчные» функции `shiftedRange(of:)`/`hasOnlyTextStructure` (`MarkdownPresentation.swift` 1195–1201), чтобы ввод внутри `{++ ++}` оставался на быстром пути, а не сбрасывал оформление (правку внутри ловит `inline`, границы — `markerRanges`).
- `.callout` — блочный, как `.alert`: добавить в фильтр `markdownAlerts` (2028) и в отрисовку (1841–1860).
- Все `switch` по `MarkdownPresentationKind` найти через `rg "case \.underline|case \.inlineStyle|\.keyboard"` (в `FoldLayoutManager` 776, 1033; контроллер 1436, 2387–2415, 2799 — в них нужен `default`, поведение прежнее).

### 4.3. Цвета: один путь вместо трёх
Новая функция `MarkdownPresentationController.reapplyDecorationColors(in:)` заменяет `reapplyCriticColors` и `reapplyObsidianCommentColors`. Читает `parsedResult` (актуальной версии, как `criticElementIndex`: `isActive`, `revision`, `!hasMarkedText`), двоичным поиском берёт span-ы `.critic`/`.obsidianComment` в окне и ставит `.foregroundColor` временным атрибутом (цвет — `criticColor`, переезжает в контроллер вместе с `NSColor.lacCritic*`; для `%%` — `lacCommentText`). Работает и без оформления (режим исходника), как сейчас. Вызывается в тех же трёх местах (4235, 5902, 6005), перед `reapplyVaultPageDim`.
Скрытие знаков вне курсора — общий механизм маркеров (`markerRanges` span-а), отдельной логики не нужно.

### 4.4. Подзадачи (каждая делится на А — адаптер/отрисовка и Б — подключение к живому редактору)
| Задача | А: ядро→span (builder `+Obsidian.swift`, стенд) | Б: подключение и удаление старого (после U6.1) |
| --- | --- | --- |
| **U5a.1 CriticMarkup** | узлы `.critic(kind)` (контракт R1–R3: куски по контейнерам, у комментария `children` пуст, у подмены три маркера) → span `.critic(kind)` с `markerRanges` из узла; диапазон = весь `{…}`, цвет одинаков для «было»/«стало». Включается флагом `.criticMarkup` (сегодня критик в редакторе всегда включён; нужен быстрый пропуск, если в тексте нет `{++`, `{--`, `{~~`, `{>>`, `{==`: проверка в ядре по UTF-8, как `mayContainComment`) | удалить `reapplyCriticColors`, колбэк `parsedResultDidChange` (оставить для `reopenPendingTableCell` — он живёт там же, стр. 4233), `hasCriticColors` у критика; `criticElementIndex` **не удалять**, а переименовать (`currentElementIndex`): он нужен `applyCriticMarkup` до U6.3, потом команда берёт `model.elements` |
| **U5a.2 `%%`** | узлы `.comment` (блочный и строчный) только при `options.isVaultNote` → span `.obsidianComment`, маркеры `%%` в `markerRanges`; правило «комментарий в строке абзаца не рвёт абзац» (markdown-editor.md стр. 49) уже учтено маской: проверить на `Corpus/obsidian-comments.md` (число строк, U+200B не нужен — в редакторе текст остаётся исходником) | удалить `reapplyObsidianCommentColors`, `obsidianCommentCache`, предел 300 000. Флаг «заметка хранилища» (`MarkdownObsidianComment.appliesTo(documentURL:)`) добавить в `MarkdownParseOptions` контроллера (U6.1): смена URL = смена опций = полный разбор |
| **U5a.3 выноски** | `.callout` → span `.callout(label:, kind:)`; `label` = знак + подпись типа (`MarkdownCalloutKind.symbol/.label`; неизвестный тип — `.note` с подписью самого типа); маркер = `markerRange` (`[!тип]±` целиком, `±` скрыт вместе); заголовок (`titleRange`) — ещё и span `.strong` без маркеров; тело остаётся цитатой (`.quote` как сейчас). Цвет подписи по `colorGroup` (`FoldLayoutManager`: отображение группы в `NSColor` — рядом с рисованием алерта; `note/tip/warning/important/caution/quote` → системные цвета). Свёрнутая выноска (`fold == .collapsed`) в редакторе раскрыта — ничего не прячем | `markdownAlerts` в `FoldLayoutManager` включает `.callout`; `reapplyVaultPageDim` без изменений |
| **U5a.4 `![[…]]`** | узлы `.noteEmbed` (блочный и строчный) → `MarkdownWikiLink(isEmbed: true)`: `range` от `!` до `]]`, `markerRanges` `![[` и `]]` (контракт U2.2 п. 1.5), `displayRange` по тем же правилам, что у wiki (`target#heading`, с алиасом — после `|`; считается из `contentRange` узла, тип `NoteEmbed` не меняется) + span `.link` с этими маркерами | Cmd-клик: путь уже общий — `follow` ищет в `parsed.wikiLinks`, `followWikiLink`→`wikiNavigationLink`→`MarkdownWikiLinkContext.fileAddress(for:)`. Менять `EditorCoordinator` не нужно, кроме запасного разбора (740), которому в U6.3 включить `.noteEmbeds`. Серый цвет неразрешённой ссылки (`applyUnresolvedWikiColors`) работает и для встраиваний |
Backlinks и переименование (U7.2) работают с узлами `.wikiLink`, не `.noteEmbed`: поведение «`![[x]]` не считается wiki-ссылкой» сохраняется.

### 4.5. Параллельность U5a
U5a.0 → (U5a.1 + U5a.2: одна функция `reapplyDecorationColors`, один разработчик, файлы `MarkdownPresentationController`, `EditorCoordinator`) ‖ U5a.3 (`FoldLayoutManager`) → U5a.4 (мелкая правка `Builder+Obsidian`/`EditorCoordinator`). Части А всех четырёх пишутся в отдельном файле `MarkdownPresentationBuilder+Obsidian.swift`, поэтому не конфликтуют с U5.1.a. Части Б — одним коммитом-пакетом сразу после U6.1.

## 5. Параллельность с U3 и общий порядок
```text
U2.6 ─┬─ U3.x (HTML-адаптер: Preview/MarkdownHTMLRenderer*)        — не пересекается по файлам с U5
      └─ U5.1.0 ─┬ U5.1.a ┐
                 ├ U5.1.b ├─ U5.1.d ─ U5.2 ─ U5.3(1) ─ U5a.0 ─ U5a.1+2 ‖ U5a.3 ─ U5a.4   (части А)
                 └ U5.1.c ┘                                   └─ U6.1 ─ части Б U5a ─ U6.2 …
```
Общие файлы только для основного агента: `project.pbxproj`, `Package.swift`, `Scripts/*.sh`, `docs/TEST_STATUS.md`, списки стенда. Общий с U3 файл один — `LacEditorTests/BaselineSupport.swift` (U3.4 переключает HTML-эталоны, U5.2 — оформление): правят разные функции, но не одновременно.

## 6. Проверки

| Этап | Стенд `lac-writer-check` (Linux) | Стенд `lac-check` | Нужен Mac |
| --- | --- | --- | --- |
| U5.1 | сборка с новыми файлами, `MarkdownPresentationBuilderTests` | без изменений (парсер жив) | нет |
| U5.2 | `MarkdownPresentationBaselineTests` ×4 набора, `testPresentationFieldListIsComplete` | — | один прогон эталонов (Foundation) |
| U5.3 | тесты, переписанные с `shiftedForTextEdit` | `swift build && .build/debug/LacCheck` — сдвиг против полного разбора остаётся главной проверкой | нет |
| U5a А | диапазоны `.critic/.obsidianComment/.callout/embed` равны диапазонам `CriticMarkupService.items`, `MarkdownObsidianComment.ranges`, `MarkdownCalloutRender.marker`, `MarkdownNoteEmbed.items` на корпусе `RenderBaseline/Corpus/{critic,obsidian-comments,callouts,embeds}.md` (кириллица, эмодзи, CRLF) | в `documents` стенда добавить те же четыре документа; убедиться, что `gen_layout.py` подхватил изменение списка `markdownAlerts` и правок `shiftedRange`; случайные правки внутри `{++ ++}` и `%%` не расходятся с полным разбором | нет |
| U5a Б | — | — | **да**: цвета при наборе и undo; скрытие знаков у курсора и IME внутри `{++ ++}`; Cmd-клик по `![[…]]` и `[[…]]`; документ > 300 000 символов с `%%` (время разбора, нет подвисаний); `fullParseCount` при вводе не растёт; режим исходника сохраняет цвета; выноски всех 13 типов в светлой/тёмной теме; страница хранилища с рабочей зоной (приглушение поверх цвета) |

Документы (в тех же задачах): `markdown-editor.md` стр. 12, 48, 49, 51 (правила критика, выносок, `%%`, порядок `reapply*`), `vault.md` стр. 40, `performance.md` стр. 32 (приглушение `%%`: теперь не «один проход на версию в основном потоке», а часть фонового разбора), `editing.md` по необходимости.

## 7. Риски
- **Контракт ядра.** U5.1 зависит от того, что ядро (U2.3–U2.5) помечает неподтверждённые строчные HTML-теги и ruby (`blockedHTML`), строит `elements` совместимо с отсевом и отдаёт `containerPrefixes` для таблиц и ограждений. Проверить до начала U5.1.a; иначе правка контракта.
- **Таблицы.** `renderedCell` по узлам модели вместо cmark — самая большая переписка (≈160 строк); эталон `tables/displayRuns` покажет любой дрейф (пробелы, `<br>`, HTML-картинки, формулы и эмодзи в ячейках).
- **Скорость ввода.** Новые виды span в быстром пути (`shiftedRange`). Ошибка в классификации даёт либо потерю быстрого пути, либо неверные позиции после сдвига; ловит только `lac-check` на случайных правках — расширить корпус.
- **Режим исходника.** Если реализовать цвета только через «оформление включено», пропадут цвета критика в исходнике (спорное 3).
- **Типы `{`, `}`, `%`, `]`.** `allowsTypingEdit` их не отклоняет: набор закрывающего `}` не создаёт span до следующего разбора (≤ `parseDelay`), как сегодня с `]]` у wiki. Менять не предлагается; на Mac оценить.
- **Подтверждение на Mac.** Всё про TextKit, IME, VoiceOver остаётся «готово на стенде» до проверки на Mac.

## 8. Спорные пункты (нужно решение пользователя)
1. **U5.3 и сдвиг.** В главном плане: «удаляются `shift`, `removeTouched`, `spanEnds`…, тесты сдвига удаляются, `lac-check` не проверяет сдвиг». Это единственный быстрый путь ввода (performance.md стр. 17), вызывающие в контроллере остаются после U6. Рекомендация: U5.3 удаляет только `shiftedForTextEdit`; сдвиг и стенд `lac-check` остаются. Удаление сдвига — отдельное решение с замерами на Mac.
2. **Порядок U5a и U6.1.** До U6.1 контроллер не умеет строить span-ы новых видов, а удалять `reapply*` без них нельзя. Рекомендация: делить U5a на А (до U6.1) и Б (сразу после U6.1), как в п. 4.4; иначе поменять местами U6.1 и U5a.
3. **Цвета в режиме исходника.** Рекомендация: сохранить (`reapplyDecorationColors` читает `parsedResult` независимо от оформления) — как сегодня. Альтернатива «только в оформленном режиме» проще, но убирает видимую возможность.
4. **«Полоса» у выноски.** В главном плане: «оформление как у алерта: полоса и цвет по kind». У алерта в редакторе полосы нет (рисуется только цветная подпись). Принято: как у алерта — цветная подпись + жирный заголовок, без полосы. Если нужна полоса — это новая отрисовка в `FoldLayoutManager`.
5. **`criticElementIndex`.** План U5a.1 «удаляет» его, но им пользуется команда `applyCriticMarkup`. Принято: переименовать и убрать только при U6.3.
6. **Модель и embed.** Для Cmd-клика `![[…]]` нужен `MarkdownWikiLink.isEmbed` (новое поле со значением по умолчанию, остальной код не затронут); `displayRange` считается в адаптере из `contentRange`. Альтернатива — добавить `displayRange` в `MarkdownBlockNode.NoteEmbed` (правка U1.1 после U2.3).

## Решения основного агента

1. Механизм сдвига оформления (`shift`, `removeTouched` и др.) обслуживает быстрый путь ввода и остаётся; в U5.3 удаляется только `shiftedForTextEdit` и то, у чего нет вызывающих; стенд `lac-check` остаётся. Главный план поправлен.
2. Принято деление U5a на части А (ядро → span, до U6.1) и Б (подключение к редактору, после U6.1).
3. Цвета CriticMarkup и `%%` в режиме исходника сохраняются (как сейчас).
4. Выноска оформляется как алерт: цветная подпись без полосы.
5. `criticElementIndex` остаётся до U6.3.
6. `![[…]]` — поле `isEmbed` у `MarkdownWikiLink` (заполняет ядро в U2.3b; внесено в `U2.3-plan.md`).
7. Риск `blockedHTML`: ядро обязано помечать неподтверждённые строчные HTML-теги и ruby — внесено в контракт `U2.3-plan.md` (U2.3c).

8. По итогам U5.1.a (06.11.2026): пары строчных HTML-тегов `<b>`/`<strong>`/`<em>`/`<i>`/`<s>`/`<del>` ядро распознаёт, но не превращает в узлы — правка ядра после U3.1d (узлы с маркерами-тегами; HTML-адаптер в U3.1 выводит их как сырой HTML — «raw HTML omitted», как любой строчный тег; настоящие теги возвращает U3.2 вместе с тестом `testRawHTMLIsReplacedWithOmittedComment`). У `HTMLBlock.Kind.images` добавляются диапазоны тегов `<img>` в той же правке; там же проверяется строчный `<svg>` в абзаце (`media-html`).
9. Принятые отличия адаптера от старого разбора (решение 1, класс Б): `<audio>`/`<video>` отдельной строкой — HTML-блок, как у cmark, а не абзац (`note-media`, `typora-parity`); точный диапазон ссылки без `<>` (`entities-autolinks`); разведённые маркеры `***текст***` (`highlight-sub-sup`). Записываются в раздел «Изменения оформления в редакторе» главного плана в U5.2.
10. `<kbd>` в ячейке таблицы: редактор оформляет (как старый парсер), панель выводит сырым тегом (как старый рендер) — расхождение было и до плана; сохраняется, запись в «Изменения оформления в редакторе» в U5.2.
