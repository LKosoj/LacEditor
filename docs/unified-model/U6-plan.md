# U6 — редактор на общей модели (U6.1–U6.4)

Статус: план (код не менялся), 06.11.2026. Номера строк — по рабочей копии на эту дату:
`Editor/MarkdownPresentationController.swift` (4292 строки, далее «контроллер»), `Preview/MarkdownLocalParser.swift` (171), `Models/MarkdownPresentation+Splice.swift` (325),
`Models/MarkdownBlockIndex.swift` (40), `Editor/EditorCoordinator.swift` (6368), сервисы редактора в `Services/`.
Опора: главный план (решения 1, 2, 5, 7, 8, 9; этап 6), U2.2 (маска), U2.5 (п. 1.6 индекс блоков), U4 (слот модели), U5 (builder), `docs/agents/{performance,text-state-and-background,editing,markdown-editor}.md`.

## 0. Что делаем простыми словами

Сейчас редактор в фоне зовёт старый разбор `MarkdownPresentationParser.parse` (внутри `MarkdownLocalParser`), а ещё 9 мест в `EditorCoordinator` и 4 сервиса
(форматирование, таблицы, ссылки, картинки) сами запускают cmark или тот же старый разбор «на пробу» (разобрать текст после предполагаемой правки и посмотреть, что вышло).
После U2 есть общая модель документа (`MarkdownDocumentModel`, один разбор на версию), после U5 — «переводчик» модели в `MarkdownPresentation` (`MarkdownPresentationBuilder`, далее «builder»).
U6 переключает редактор: контроллер строит оформление цепочкой «ядро → builder» и кладёт модель в документ; локальный разбор (T5, разбор только участка вокруг правки) делает то же для участка;
`EditorCoordinator` и сервисы берут готовый результат или зовут одну общую функцию вместо своих проходов по cmark. Старого разбора в редакторе после U6 не остаётся (кроме самого файла парсера, его удаляет U8).

Находки, проверенные по коду:
1. **Слота модели в `EditorDocument` ещё нет** (`rg "markdownModel|installMarkdownModel"` пусто): U4.1 не выполнена. U6.1 зависит от неё (план U4, решение 5: публикует модель именно U6.1).
2. **Склейка (`MarkdownPresentation+Splice`) работает над `MarkdownPresentation`, а не над моделью** и парсер не вызывает вообще. «Склейка работает с моделью» из главного плана на деле значит: фрагмент-участок разбирается цепочкой «ядро → builder», склейка остаётся как есть (спорный пункт 2).
3. Девять «прямых» мест `EditorCoordinator` нужны не модель, а `MarkdownPresentation` (ссылки, таблицы, элементы, блоки кода). Модель текущей версии им не нужна; нужна одна общая функция «текст → оформление» (U6.0).
4. Пять мест — **синхронный разбор всего документа на главном потоке** по явной команде (стр. 1600, 1669, 1791, 2019, 2439/2461/2469). Сегодня это допущено (комментарий «один синхронный разбор по явной команде»). Условие главного плана «синхронного полного разбора нет» с ними не сходится (спорный пункт 3).
5. Четыре сервиса (`Link`, `Image`, `TableEditing` ×2, `Formatting`) разбирают **обычным cmark без расширений редактора** (без формул `$…$`, без маски), поэтому их «узлы» иногда расходятся с редактором. Модель даёт ту же картину, что видит пользователь (решение 1), это небольшое намеренное изменение (п. 3.5).
6. Старый разбор при NUL в тексте возвращает пустое оформление, ядро заменяет NUL на U+FFFD. Небольшое изменение, запись в «Изменения оформления в редакторе».

## 1. Карта текущего кода

| Что | Где | Вызывает старый разбор / cmark |
| --- | --- | --- |
| Фоновая операция разбора | контроллер `schedule` 1780–1935; вызов 1812 `MarkdownLocalParser.parse`; результат 1884–1923 | косвенно (через LocalParser) |
| Опции разбора | `MarkdownParseOptions` (LocalParser 4–10): `includeReadableText/EmojiCandidates/UppercaseRuns/WikiLinks`, `syntax` | — |
| База локального разбора | `MarkdownParseBase` (LocalParser 14–19), контроллер `parseBase` 465, сброс 1991 | — |
| Полный разбор | `fullParse` (LocalParser 64–71): `MarkdownPresentationParser.parse(... blocks: { index = $0 })` | да |
| Разбор участка | `attempt` 83–170, вызов 130: `MarkdownPresentationParser.parse(windowText, ..., detectsFrontMatter: false, blocks:)` | да |
| Склейка | `MarkdownPresentation.spliced` (Splice 100–240), `Unmergeable(field:)` | нет |
| Индекс блоков | `MarkdownBlockIndex` (40 строк); модель отдаёт его в `blockIndex` (U2.5 п. 1.6) | нет |
| Готовый результат для других | `navigationPresentation` 1214, `criticElementIndex` 1221, `currentTablePresentation` 1252, `parsedResult` | нет |
| Синхронные разборы в координаторе | `EditorCoordinator` 745 (фон, `Task.detached`; запасной), 1600, 1669, 1791, 2019, 2439, 2461, 2469, 2932 (фон, блоки кода) | да (9 мест) |
| Проводка ячейки | 2329 `tableRowDisplay`, `MarkdownTableCellEditor` 38–44 `projection` | переезд делает U5.1.b |
| Форматирование | `MarkdownFormattingService`: 110, 136 (parse «на пробу»), 167–273 `containerMathEdit` (обход cmark), 430–603 `existingListEdit`, 605–660 `formattingStructure` (подпись структуры), 772 | да + cmark |
| Таблицы | `MarkdownTableEditingService.tableLines` 322–365, `isOutsideBlocks` 390–405 | cmark |
| Ссылки | `MarkdownLinkEditingService.nodes(in:)` 120–185 | cmark |
| Картинки | `MarkdownImageEditingService.nodes(in:)` 254–327 | cmark |
| Строчное форматирование | `MarkdownInlineFormatting` 273 (`parse(source).spans`), `MarkdownPlainTextFormatting` 21, 101 | да |
| Не меняются | `MarkdownFormattingState`, `MarkdownDisplayMap` (читают готовое `MarkdownPresentation`; в `MarkdownDisplayMap` 84 только слово «cmark» в комментарии) | — |
| Сдвиг оформления при вводе (горячий путь) | контроллер 441–442, 1985, 2047–2077, 2156–2207; `FoldLayoutManager` | **не трогаем** |

## 2. Задачи

### U6.0 (подготовка внутри U6.1) — общая точка входа без AppKit

Новый файл `Editor/MarkdownPresentationBuilder+Parse.swift` (≈80 строк, без AppKit/cmark; на стенде собирается):
- `MarkdownPresentationBuilder.presentation(of text: String, syntax: MarkdownSyntaxOptions, flags…, isCancelled:) -> MarkdownPresentation` — «ядро → builder» за один вызов, как старый `MarkdownPresentationParser.parse(text, syntax:)`. Флаги по умолчанию — минимум (без эмодзи, чтения, wiki): у сервисов и команд нет нужды в них. Если ядро вернуло `nil` (отмена) — пустое оформление, как сегодня при NUL.
- `MarkdownPresentationBuilder.model(of text: String, syntax:, includes:, isCancelled:) -> MarkdownDocumentModel?` — для сервисов, которым нужны узлы (ссылки, картинки, таблицы, списки).
- `isVaultNote: false`, `detectsFrontMatter: true`; сводка «какие `Includes` нужны» — константы `editorIncludes(...)`.
Эти две функции — единственные места, где редактор зовёт ядро (кроме `fullParse` локального разбора). Файл правится первым и один раз; U6.1, U6.3, U6.4 только вызывают.
Проверка: `swiftc -frontend -parse`, добавить в `lib-files.txt` (основной агент).

### U6.1 Контроллер

Файлы: `Editor/MarkdownPresentationController.swift`, `Preview/MarkdownLocalParser.swift` (только типы и `fullParse`), `Models/EditorDocument.swift` (слот, если U4.1 не сделана), новый тест.

Шаги:
1. `MarkdownParseOptions` (LocalParser 4–10): добавить `isVaultNote: Bool` (от `MarkdownObsidianComment.appliesTo(documentURL: document.url)`, считается в `schedule` на главном потоке до запуска операции, как `syntax`). Опции сравниваются в `attempt` (`base.options == options`), поэтому смена типа документа сбрасывает базу сама.
2. `MarkdownLocalParser.fullParse` (стр. 64–71): тело заменить на `MarkdownDocumentParser.parse(text, options:…)` + `MarkdownPresentationBuilder.build(...)`. `includes` собирает функция из U6.0: всегда `.wikiLinks, .elementIndex, .blockIndex, .editorContext, .criticMarkup, .noteEmbeds`; `.emoji` — если `includeEmojiCandidates`; `.readableText` — если `includeReadableText`; `.uppercaseRuns` — если `includeUppercaseRuns`. `base = model.blockIndex.map { MarkdownParseBase(...) }`. Колбэка `blocks:` больше нет. Модель возвращается в новом поле `Result.model: MarkdownDocumentModel?` (nil, если участок собран локально).
3. Контроллер: в блоке результата (1884–1923), там же где `installReadableText`, вызвать `document.installMarkdownModel(model, source: text)` (проверки версии и пустой карты токенов внутри метода, план U4 п. 1.2). Условия `guard` те же, что у `parsedResult` (1861–1865): активность, поколение, `currentRevision() == revision`, `taskCoordinator.isCurrent`, `!hasMarkedText`. Поздний результат отбрасывается целиком, модель тоже — решение 8.
4. Причина разбора «панель видна и нужна модель» (`needsPreviewModel`) в `schedule` guard (1783, 1861) и в `parseDelay` — **без новых пауз**, по плану U4 п. 1б (спорный пункт 4).
5. Что НЕ меняется: `numberingHeadings`, `fullParseCount` (считает только установленные полные разборы), `headingNumbering`, `emojiOperation`, `parsedResultToken`, сдвиг.
6. «Временное двойное построение U4.1» убирать нечего: по решению 5 плана U4 оно не вводилось. Проверить `rg "MarkdownDocumentParser\.parse" Editor/` — должен остаться один вызов (в `fullParse`).

Подзадачи: (a) U6.0 + шаги 1–2 (LocalParser, ≈150 строк) → (b) шаги 3–5 (контроллер, ≈100 строк) → (c) тесты. a и b последовательны (b использует `Result.model`).

### U6.2 Локальный разбор на модели

Файлы: `Preview/MarkdownLocalParser.swift` (`attempt`), `Models/MarkdownBlockIndex.swift` (комментарий), `Models/MarkdownPresentation+Splice.swift` (комментарий, при необходимости список полей).
1. Вызов 130 → «ядро над текстом участка с `detectsFrontMatter: false`, тот же `isVaultNote` и `includes` + builder». Индекс участка — `model.blockIndex` (`fragmentIndex`). Остальной `attempt` (общее начало/конец, ядро/контекст, границы, `readable`) не меняется: формат `MarkdownBlockIndex` тот же (U2.5 п. 1.6).
2. **Новые отказы (маска — функция всего текста, U2.2 риск 4).** Если включён критик (всегда) или `isVaultNote`, и старый или новый текст участка содержит любой из `{++ {-- {~~ {>> {== ++} --} ~~} <<} ==} ~> %%` — полный разбор, причина «в участке разметка критика или `%%`». Проверка по уже собранным `windowText`/`oldWindowText` (как для `]:`, `[^`, `$$`, стр. 123–126). **Сделано иначе (ревью):** пара знаков может охватывать окно снаружи (`%%` в блоке 2 и 20, правка в блоке 10), поэтому дополнительно проход по всему новому тексту (`hasMaskOpener`): любой открывающий знак критика или (`isVaultNote`) `%%` — полный разбор, причина «в тексте разметка критика или «%%»»; проверка окон остаётся (ловит удаление последнего открывающего знака).
3. Склейка: проверить, что `Unmergeable`-проверки (стр. 142–170) не зависят от старого парсера. Новые поля из U5 (`.critic`, `.obsidianComment`, `.callout` в `spans`; `isEmbed` у `wikiLinks`) — списки уже склеиваются по диапазонам; `testComparedFieldsCoverEveryPresentationProperty` ловит забытые поля.
4. Режим сверки (DEBUG — каждый раз, Release — каждый 20-й) остаётся: `fullParse` + `firstDifference` после `prepareForEditing`.
5. Комментарии «Строит `MarkdownPresentationParser.parse`» (BlockIndex 4) → «строит ядро разбора».
6. Идентификаторы заголовков (`headingIDs`, `namedAnchors`, дубли `-1/-2`): ядро считает по всему документу, участок — только по своему окну. Проверить на стенде (повторяющиеся заголовки по обе стороны правки); если расходится — добавить отказ «в участке заголовок» или пересчёт склейкой (риск 3).

Подзадачи: (a) шаги 1–2 (≈60 строк) → (b) 3–6 (≈60 строк) → (c) тесты; параллелить нечего (один файл).

### U6.3 `EditorCoordinator`

Файл: только `Editor/EditorCoordinator.swift` (+ `Editor/MarkdownPresentationController.swift` для одного метода, см. ниже). Каждое место:

| Стр. | Что сейчас | Что станет |
| --- | --- | --- |
| 745 | `Task.detached { parse?(text) ?? MarkdownPresentationParser.parse(text, includeWikiLinks: true, syntax:) }` — фон | `MarkdownPresentationBuilder.presentation(of:syntax:wikiLinks: true, …, isCancelled: { Task.isCancelled })`; тестовый хук `markdownLinkParse` остаётся (тип тот же) |
| 1600 | `formattingPresentation`: готовый `navigationPresentation` или синхронный разбор | готовый как сейчас; запасной — функция U6.0 (спорный пункт 3) |
| 1669 | критик: `parse(...).elements` | то же: готовый `criticElementIndex` или U6.0 с `elements` (`.elementIndex`) |
| 1791 | `openTableCellAtSelection(freshParse:)` | U6.0 |
| 2019 | запасной разбор при открытии ячейки | U6.0 |
| 2329 | `MarkdownPresentationParser.tableRowDisplay` | уже переименовано в U5.1.b — проверить, что нет старого имени |
| 2439, 2461, 2469 | таблицы после команды строки/Tab | U6.0; «свежий» результат нужен потому, что текст только что изменён |
| 2932 | детач: блоки кода из `parse(...).codeBlocks` | U6.0 в `Task.detached`, с `isCancelled` |

После правки `rg "MarkdownPresentationParser|MarkdownSourcePositions" Editor/EditorCoordinator.swift` пусто. `criticElementIndex` остаётся (решение 5 плана U5), переименование — по желанию, не в этой задаче.
Подзадачи: одна (≈60 строк правок), параллельно с U6.4 (разные файлы), но после U6.0.

### U6.4 Сервисы редактора (API сервисов не меняется: тесты вызывают их напрямую)

**U6.4a `MarkdownFormattingService`** (≈330 строк обхода cmark переписываются на модель):
- 110, 136, 772: `parse(...)` → `MarkdownPresentationBuilder.presentation(of:syntax:)`.
- `containerMathEdit` (167–273) и `quotedTaskContent` (151–165): обход cmark → обход `model.blocks` (`quote`, `list`, `listItem`, `paragraph`, `formula`/`mathBlock`) с `containerPrefixes`, `ListItem.task`, `markerRanges[0]`. «Проверка пробой» (253–270, 581–596) — повторный вызов `model(of: probe)` и поиск нужного блока по диапазону.
- `existingListEdit` (430–603): пункты, порядок номеров (`ListItem.ordinal`, `ListBlock.marker`), плотность (`isTight`), вложенность, `listContainerPrefixes` → `containerPrefixes` узла.
- `formattingStructure` (605–660): подпись структуры (вид, номер, разделитель, плотность, `checked`, адрес, заголовок, info ограждения, уровень) строится из модели; сравнение «до/после» остаётся.
- `import cmark_gfm*` из файла удаляется.
Нужно в модели: у всех перечисленных полей есть (ListBlock/ListItem, Link, Image, CodeBlock.info, Heading.level). Нет `cmark`-флага «списка был рыхлым после правки» — выводится из `isTight`. Отдельной функции `ownerIndex` не требуется.

**U6.4b Таблицы, ссылки, картинки** (≈250 строк):
- `MarkdownTableEditingService.tableLines` → таблица из `presentation.tables` (диапазон, `containerPrefix`, `quoteDepth`, `nestedList`, `rows`) для строки выделения; `isOutsideBlocks` → верхнеуровневые блоки `model.blocks` не содержат строку (кроме абзаца, из которого строится таблица). Строчная логика `parseRow`, `cellOffset` не меняется.
- `MarkdownLinkEditingService.nodes(in:)`: ссылки `.link` (адрес, заголовок, диапазон), `.code`, `.image`, `codeBlock` блоков; узел или блок с `isUnreliable` → вид `"unresolved"` на строки блока, как сегодня при отсутствии позиции (`position` возвращало `nil`). Диапазон `.code` — проверить по U1.1/U2.3: включает ли он обратные кавычки (сейчас они добираются вручную); если нет — оставить добор.
- `MarkdownImageEditingService.nodes(in:)`: `.image` (`url`, `alt`, `title`, `addressRange`, `syntax`), `complexAlt` = у узла есть вложенные узлы не-`text`.
- `MarkdownPlainTextFormatting` (21, 101) и `MarkdownInlineFormatting` (273): `parse(...)` → U6.0.
- `containerPrefixes`, `listContainerPrefixes`, `fencePrefixes` (главный план: «переносятся в новый слой») — их переносит U2.3 (`containerPrefixes` узла); в U6.4 проверить, что у старого `MarkdownPresentationParser.containerPrefixes/listContainerPrefixes` нет вызывающих вне парсера (`rg`), и список для U8 передать основному агенту.
- `import cmark_gfm*` из Link/Image/TableEditing удаляется.

Параллельность U6.4: a ‖ b (разные файлы) ‖ U6.3. Все три — после U6.0 и U2.3–U2.5. Порядок внутри a: 110/136/772 → `containerMathEdit` → `existingListEdit` → `formattingStructure` (по возрастанию сложности; тесты `MarkdownFormattingServiceTests` после каждого шага).

## 3. Тесты

1. **Переводятся без смены ожиданий**: `MarkdownLocalParseTests` (13; опции, `Result`, `firstDifference`; `testComparedFieldsCoverEveryPresentationProperty`), `MarkdownFormattingServiceTests`, `MarkdownInlineFormattingTests`, `MarkdownTableEditingTests`, `MarkdownTableNavigationTests`, `MarkdownLinkEditingTests`, `MarkdownImageEditingTests`, `MarkdownImageTests` (вызовы сервисов API не меняются — менять нечего; прогнать как контроль).
2. **Новые**:
   - `MarkdownLocalParseTests`: отказ при правке рядом с `{++ … ++}` и `%%` и при паре вокруг окна (причина «в тексте разметка критика или «%%»»), при заметке хранилища и в обычной (`isVaultNote` в опциях); смена `isVaultNote` сбрасывает базу; участок с кириллицей, CJK, эмодзи (суррогатные пары на границе правки) и `\r\n` собирается локально и совпадает с полным; повторяющиеся заголовки по обе стороны правки (`headingIDs`).
   - `MarkdownLocalParseTests` (контроллер, стр. 242–330): модель появляется у документа после полного разбора и **не** появляется после локального; поздний результат (другая версия) не ставит модель; непустая карта токенов — модели нет (`fullParseCount` растёт только на полных).
   - Формат/таблицы/ссылки/картинки: то же, что в п. 1, плюс по одному случаю на каждый переведённый обход: цитата в списке с задачей, нумерованный список с пропуском номера, формула в цитате, ссылка внутри неподтверждённой строки (`unresolved`), картинка с вложенной подписью.
   - Тест на `MarkdownPresentationBuilder.presentation(of:)`: пусто для отмены, NUL → U+FFFD (позиции сохранены).
3. Тесты, вызывающие `MarkdownPresentationParser.parse` напрямую (≈400 вызовов в `MarkdownPresentationParserTests`, `MarkdownLayoutTests`, `MarkdownNativeTableInteractionTests` и др.), к U6 не относятся: их переводит U9.1 на функцию U6.0.
4. Данные: минимальные, не-ASCII, `\r\n`; позиции — UTF-16. Ожидания не ослабляются; образец стенда — соседние тесты файла (`makeFixture`, `Fixture`, опрос 30×100 мс).
5. `docs/TEST_STATUS.md`: основной агент отмечает «на Mac не запускалось».

## 4. Проверки

- `swiftc -frontend -parse` по каждому изменённому файлу; `EditorCoordinator.swift` — `swiftc -typecheck -swift-version 5` (ошибка `no such module 'AppKit'` ожидаема); `MarkdownPresentationController.swift` — только `-parse` (typecheck зависает).
- Стенд `lac-writer-check/run-tests.sh`: в `lib-files.txt` нужны `MarkdownPresentationBuilder+Parse.swift` (новый), `MarkdownLocalParser.swift`, `MarkdownBlockIndex.swift`, `MarkdownPresentation+Splice.swift`, сервисы U6.4 (уже были; проверить, что убранный `import cmark_gfm` не ломает заглушки); записи вносит основной агент. Тесты LocalParse и сервисов — уже в `test-files.txt`.
- Стенд `lac-check`: `LOCALCHECK=1 [LOCALEDITS=40] .build/debug/LacCheck` — сверка локального разбора с полным на случайных правках (зерно 12345) должна дать **0 расхождений** (критерий этапа). Для этого стенду нужны ссылки на файлы ядра/builder (`gen-document-parser-shim.py` уже есть), после правки — `python3 patch-parser.py` больше не нужен для этих файлов, только пока жив старый парсер (U8).
- `rg "MarkdownPresentationParser|MarkdownSourcePositions|cmark_" LacEditor/Editor LacEditor/Services/Markdown{Formatting,TableEditing,LinkEditing,ImageEditing,InlineFormatting,PlainTextFormatting}Service.swift LacEditor/Preview/MarkdownLocalParser.swift` — пусто (кроме импортов, которых не останется).
- `git diff --check`.
- **Не проверить на Linux**: фактическое время локального и полного разбора (порог 20 000 UTF-16 не замерен), ввод с IME, сдвиг оформления на живом TextKit, замеры P1–P9, тесты T1–T11, `fullParseCount` при вводе; предпросмотр и рендер. «Готово на стенде», не «завершено».

## 5. Документы (в тех же задачах)

`docs/agents/performance.md` стр. 15, 36 (локальный разбор: порог, новые отказы, «модель публикуется только после полного разбора»), `text-state-and-background.md` (контроллер публикует модель, поздний результат отбрасывается вместе с ней), `markdown-editor.md` (разбор редактора = ядро + builder; сервисы форматирования/таблиц/ссылок/картинок берут модель), `editing.md` (синхронные команды: что остаётся), раздел «Изменения оформления в редакторе» главного плана (NUL, п. 3.5).

## 6. Риски

1. **Скорость горячего пути.** Модель тяжелее прежнего оформления; `includes` собираются по реальным флагам. Если на Mac полный разбор станет заметно дольше, это видно в `MarkdownPresentationParse` (signpost); локальный разбор остаётся основным для документов ≥ 20 000.
2. **Модель после локального разбора не публикуется** (спорный пункт 2): панель при наборе в большом документе разбирает сама, как сегодня.
3. **Идентификаторы заголовков и сноски** в окне считаются неполно; сноски уже отказ («`[^`»), заголовки — проверить (U6.2, шаг 6).
4. **Маска критика/`%%`** зависит от всего текста; закрыто отказом по знакам в окне, но «мягкий» случай (знак стоит рядом с окном, но вне) стенд должен поймать случайными правками — расширить корпус `lac-check` документами `critic`, `obsidian-comments`.
5. **Сервисы** получают чуть иную картину, чем при голом cmark (формулы, маска, `isUnreliable`): возможны отличия в крайних случаях (ссылка в строке с `$…$`). Ловят тесты п. 3.2; расхождения идут в «Изменения оформления».
6. **Синхронные команды** на больших документах (1600, 1669, 1791, 2019, 2439, 2461, 2469): ядро + builder может быть медленнее прежнего `parse`; с минимумом флагов — не должно, замерить на Mac.
7. **Зависимость от U4.1/U5/U2.3–U2.5.** Нет слота модели, builder, флагов `.blockIndex/.elementIndex/.editorContext` — U6 не начинать. Параллельно идущие правки `MarkdownDocumentParser*.swift` и `MarkdownPresentationParser.swift` — читать как есть.
8. **Коллизия правок файлов.** `MarkdownPresentationController.swift` и `EditorCoordinator.swift` правят также U5a.Б (`reapplyDecorationColors`): идти строго по очереди (U6.1 → U5a.Б → U6.3), одним разработчиком.

## 7. Спорные решения (для утверждения основным агентом)

1. **Порядок и разбивка.** Принять ли: U6.0 → U6.1 (a→b) → U6.2; U6.3 ‖ U6.4a ‖ U6.4b после U6.0; U5a.Б между U6.1 и U6.3. Рекомендую да.
2. **Модель и локальный разбор.** Варианты: (A) модель публикуется только после полного разбора, после локального — нет (предпросмотр разбирает сам) — рекомендую; (B) всегда полный разбор — убивает выигрыш T5; (C) склейка моделей — большая новая работа без пользы для редактора. Текст главного плана «склейка работает с моделью» предлагаю заменить на «участок разбирается ядром, склейка остаётся над `MarkdownPresentation`».
3. **Синхронные разборы по команде** (1600, 1669, 1791, 2019, 2439, 2461, 2469). Варианты: (A) оставить синхронными (поведение не меняется), но через минимальную функцию U6.0 — рекомендую; (B) асинхронно с повтором команды — меняет UX и тесты; (C) для больших документов — разбор окна вокруг таблицы. Решить, как сформулировать критерий «синхронного полного разбора нет» (сейчас это нарушается 7 местами).
4. **`needsPreviewModel` в U6.1.** Включать ли разбор контроллера ради одной видимой панели (режим «исходник + панель»), пауза 1,0 с? Рекомендую да, только при пустой карте токенов; иначе модель появится лишь при включённом оформлении.
5. **Состав `includes` редактора** (критик, `noteEmbeds` — всегда, `%%` — по `isVaultNote`): до U5a.Б они не используются builder'ом, лишняя работа ядра. Рекомендую включить сразу (иначе придётся править место дважды) с быстрым пропуском в ядре.
6. **Сервисы форматирования: узлы по модели вместо голого cmark** (п. 1.5) — принять небольшие расхождения как намеренные (решение 1).
7. **`criticElementIndex`/`navigationPresentation`/`currentTablePresentation`** оставить как есть (отдают `MarkdownPresentation`); переименование — отдельно, не в U6.
8. **NUL в тексте** (ядро заменяет, старый разбор отдавал пусто) — принять как намеренное изменение.

## Решения основного агента

1. Модель публикуется только после полного разбора. Локальный разбор участка делает ядро, склейка остаётся над `MarkdownPresentation`. В главном плане U6.2 переформулирован.
2. Синхронные разборы по явной команде пользователя (7 мест в `EditorCoordinator`) берут модель текущей версии, если она есть; иначе — синхронный разбор через вход U6.0. Критерий U6.3 главного плана уточнён: «нет синхронного полного разбора, кроме явных команд при отсутствии модели текущей версии».
3. `needsPreviewModel` — да, кроме документов с media-токенами (как рекомендовано).
4. `includes` редактора: критик и `noteEmbeds` сразу; `%%` — по `isVaultNote`.
5. Расхождения четырёх сервисов с прежним cmark и замена NUL на U+FFFD — намеренные; записываются в «Изменения оформления в редакторе» главного плана с примерами.
6. Порядок строго U6.1 → U5a.Б → U6.3, один разработчик на `MarkdownPresentationController`/`EditorCoordinator`.
7. Вход U6.0 (`MarkdownPresentationBuilder.parse(...)` с сигнатурой старого `parse`) — общий с U9.1 (план U8–U10, решение 2); это обычная функция приложения, не переключатель (решение 9 не нарушено).
8. Слот модели в `EditorDocument` появляется в U4.1, U6.1 начинается после него.
