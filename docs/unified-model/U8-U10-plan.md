# U8–U10 — Удаление старого кода, перевод тестов, документы (U8.1–U8.2, U9.1–U9.3, U10.1)

Статус: план (код не менялся), 06.11.2026. Опора: главный план (решения 3–5, 9; этапы 8–10), `docs/agents/testing.md`, `release.md`, планы U2.6, U4, U5.
Номера строк и счётчики — рабочая копия на 06.11.2026 (параллельно идёт U2.3+: `MarkdownDocumentParser*.swift`, `MarkdownPresentationParser.swift` в работе). Перед правкой пересчитать `rg`.

## 0. Что делаем простыми словами

К этому моменту все программы приложения уже читают «общую модель документа» (она получается за один разбор текста библиотекой cmark),
а старый разбор редактора (`MarkdownPresentationParser`, 3453 строки) и старый HTML-рендер (`MarkdownRenderer`) никто, кроме тестов, не вызывает.
Остаётся: (1) перевести тесты на новые вызовы, (2) удалить старые файлы вместе со всеми следами (записи проекта, стенды, документы),
(3) доказать командами, что следов не осталось, (4) дописать два-три теста про новый слой, (5) переписать правила в `docs/agents/`.
Всё, что можно проверить на Linux, проверяется на стендах; прогон на Mac (`RunAllTests`) остаётся пользователю.

## 1. Карта текущего кода (что реально зависит от старого API)

### 1.1. Приложение (`LacEditor/`) — это входные данные для U8, к моменту U8 должно быть 0

| Что | Сейчас | Кем вычищается |
| --- | --- | --- |
| `Preview/MarkdownPresentationParser.swift` | 3453 строки; снаружи в приложении 31 файл (`rg -c`), из них 34 обращения в `MarkdownRenderer.swift`, 22 в `MarkdownClipboardCopyService.swift`, 10 в `EditorCoordinator.swift`, 7 в `MarkdownFormattingService.swift`, остальные по 1–5 | U4.4, U4.5, U5, U6, U7 (по плану); U8 только проверяет |
| Помощники, которые сейчас вызываются из других файлов как `MarkdownPresentationParser.X` | `containerPrefixes`, `listContainerPrefixes`, `fencePrefixes`, `isSpanOpening`, `htmlSourceMatches`, `containerHTMLPrefixes`, `standaloneSVGBlockCandidate/InlineCandidates`, `StandaloneSVG`, `PairedMediaCollector`, `multilineMediaOpening`, `inlineDecorations`, `subscriptRange`, `filterInlineHTMLForStyles`, `inlineRubyCandidates`, `unconfirmedRubyRanges`, `confirmedNamedAnchors`, `inlineHTMLPairs`/`InlineHTMLPair`, `underlines`, `fencedCodeBlock`, `recoverLooseLists`, `projection`/`Projection`, `tableRowDisplay`, `tableDisplay`, `tableCellBreaks`, `highlightRanges` | решение 5 главного плана: переезжают в новый слой в U2.3/U2.5/U5.1.b/U6.4/U7. **Дыра, если хоть один остался** — см. U8.0 |
| `Preview/MarkdownReadableTextParser.swift` | 111 строк; вызывается из старого разбора и из `MarkdownReadableTextTests` | U2.5 переносит в `MarkdownDocumentExtras.swift` |
| `Preview/MarkdownRenderer.swift` (2497), `MarkdownSemanticDocument.swift` (222) | удаляются в U4.4 и U2.6 | U8.0 проверяет, что их уже нет |
| `cmark_parser_new` / `cmark_parse_document` | 6 файлов приложения: `MarkdownLinkEditingService`, `MarkdownMathExtension`, `MarkdownPresentationParser`, `MarkdownImageEditingService`, `MarkdownImageUploadService`, `MarkdownTableEditingService` (2) | U6.4, U7.3 (U7.3 убирает свои; `MarkdownMathExtension.withDocument` — общая обёртка, см. «Спорное» п. 6) |
| Комментарии со старыми именами | `MarkdownBlockIndex.swift:4`, `MarkdownDocumentModel.swift:6`, `MarkdownSemanticDocument.swift` и др. | U8.2 (вычитывает `rg` по комментариям) |

### 1.2. Проект, скрипты, стенды

- `LacEditor.xcodeproj/project.pbxproj`: по 4 записи на файл (PBXBuildFile, PBXFileReference, группа, Sources). Старые: `MarkdownPresentationParser` (стр. 118, 562, 1292, 1918), `MarkdownReadableTextParser` (182, 628, 1287, 1814); `MarkdownRenderer` (47, 501, 1298, 1957) и `MarkdownSemanticDocument` (48, 502, 1299, 1958) должны быть убраны в U4.4/U2.6 — U8 проверяет. Тесты в проекте не перечислены: группа `LacEditorTests` — `PBXFileSystemSynchronizedRootGroup` (папка сама), в `Package.swift` — `path: "LacEditorTests"`, `resources: [.copy("Fixtures")]`. Списков исходников в `Package.swift` для приложения нет (`path: "LacEditor"`). Значит удаление/переименование тестового файла правок проекта не требует.
- `Scripts/verify-release.sh` и `Scripts/run-acceptance.sh`: `rg` по старым именам — **пусто**, но у обоих есть ручные списки `swiftc` (verify-release ~45, ~84, ~105; run-acceptance 52, 62, 100, 105) с `MarkdownPresentation.swift`, `MarkdownReadableText.swift`, `EditorDocument.swift` и т. д. Если U4.1/U5.3/U6 добавили к этим файлам новые зависимости (`MarkdownDocumentModel`, `MarkdownBlockIndex`, `MarkdownSyntaxOptions`), в списках должны появиться и они (U4 план, п. 1.7). U8.1 проверяет списки на полноту, а не «удаляет записи» (удалять там нечего).
- Стенд `/home/claude-bot/tools/lac-writer-check`: `lib-files.txt` строки 75 (`Preview/MarkdownPresentationParser.swift`), 77 (`MarkdownReadableTextParser.swift`), 79 (`MarkdownRenderer.swift`) — убрать/заменить; `test-files.txt` (144 имени) — переименованные и удалённые тесты. Из 73 тестовых файлов со старым API **29 собираются на стенде**; из 57 файлов с `MarkdownPresentationParser` — 19 (5238 строк), 38 (29110 строк, AppKit/TextKit) только на Mac. `MarkdownRendererTests` на стенд не входит (`import AppKit`, `WebKit`).
- Стенд `lac-check` (`/home/claude-bot/tools/lac-check`): держит **копию** парсера (`Sources/LacCheck/MarkdownPresentationParser.swift`, обновляется `patch-parser.py`), `MarkdownDocumentParserShim.swift` (`gen-document-parser-shim.py`), `main.swift` (897 строк) и `CaretCheck.swift` вызывают `MarkdownPresentationParser`. Перевод на ядро + построитель — часть U6.2 (стенд сверяет склейку); в U8.1 удаляются копия, `patch-parser.py`, шим и упоминания в `check-howto.md` (стр. 10, 45) и `grow.py`.
- Стенд `lac-semantic-check`: удаляется в U2.6 (главный план); U8.2 проверяет, что каталога нет, а `docs/` и `AGENTS.md` на него не ссылаются.

### 1.3. Тесты (`LacEditorTests/`, считалось `rg`)

| Показатель | Значение |
| --- | --- |
| Файлов со старым API (парсер, рендер, `MarkdownReadableTextParser`, `MarkdownSemanticDocument`, `renderPage`, `cmark_parser_*`, `MarkdownLocalParser`, `shiftedForTextEdit`, `exceptions.json`) | 73 `.swift` (в главном плане «81» — устарело) |
| Из них с `MarkdownPresentationParser` | 57 файлов, 34 348 строк; **606** вызовов `MarkdownPresentationParser.parse(` + 7 вызовов внутренних помощников (`tableDisplay` 4, `tableCellBreaks` 2, `tableRowDisplay`, `listContainerPrefixes`, `inlineHTMLPairs`, `highlightRanges` по 1) |
| Только с `MarkdownRenderer`/`renderPage` | ещё 14 файлов; всего по рендеру 29 файлов, 12 829 строк, **271** `renderPage(` и 35 `render(` — переводятся в U4.4 заменой имени (решения U4: имя `renderPage` и короткий `render` сохраняются) |
| Белый ящик: тест берёт дерево cmark и зовёт помощник старого разбора | `MarkdownPresentationParserTests` (10 мест: стр. 143, 163, 186, 296, 303, 536, 578, 643, 692, 779), `MarkdownMathExtensionTests:190`, `MarkdownInlineHTMLTests:17`, `MarkdownImageUploadTests:85,94`, `MarkdownEmojiCandidateExtractorTests:10,100`, `MarkdownReadableTextTests:30` (`MarkdownReadableTextParser.build`) |
| Удаляются целиком | `MarkdownSemanticConsistencyTests` (94), `MarkdownSemanticComparison` (189), `Fixtures/GFMSpec/exceptions.json` — в U2.6; U8.2 проверяет |
| Остаются | `MarkdownSemanticRoundTripTests` (проверяет TextKit, к `MarkdownSemanticDocument` не обращается), `MarkdownLocalParseTests` (переводится в U6.2) |
| Крупнейшие | `MarkdownLayoutTests` 3710 (71 вызов), `MarkdownClipboardInteractionTests` 2462 (5), `PandocExportTests` 1931 (1 + 4 рендера), `MarkdownWidthTests` 1775 (18), `MarkdownImageUploadTests` 1739, `MarkdownPresentationParserTests` 1704 (212), `MarkdownClipboardCopyTests` 1662 (1), `MarkdownNativeTableInteractionTests` 1446 (32), `MarkdownPresentationTests` 1444 (19) |

Вывод: «крупнейшие» файлы главного плана в основном **меняются механической заменой одного имени**; настоящая работа — ~25 мест белого ящика и тесты внутренних функций.

## 2. Задачи

Порядок из главного плана (U8.1 → U8.2 → U9.1) невыполним: после удаления `MarkdownPresentationParser.swift` тестовая цель перестаёт собираться (606 вызовов), а «сопоставление удаляемых тестов новым» нельзя сделать задним числом. Предлагаю (см. «Спорное» п. 1):

```text
U8.0 (проверка готовности) → U9.1.0 (механическая замена) → U9.1.a ‖ U9.1.b ‖ U9.1.c ‖ U9.1.d ‖ U9.1.e → U9.1.f (сверка на стенде)
 → U8.1 (удаление) → U8.2 (проверка «ничего не осталось») → U9.2 (новые тесты) → U10.1 (документы) → U9.3 (Mac)
```

### U8.0. Проверка готовности к удалению (читает, не меняет)

Каждая команда — пусто, иначе возврат к задаче-владельцу (U2.5/U4/U5/U6/U7):

```sh
rg -n "MarkdownPresentationParser\." LacEditor --glob '!Preview/MarkdownPresentationParser.swift'   # вызовов нет (допустимы только комментарии)
rg -n "MarkdownRenderer\b|MarkdownSemanticDocument" LacEditor LacEditorTests Scripts docs/agents          # пусто
rg -n "cmark_parser_new|cmark_parse_document" LacEditor                                                     # только allow-list п. 6 «Спорного»
```

Плюс опись `static`-членов старого разбора: `rg -n "^\s*(private )?static (func|var|let)|^\s*(struct|enum|final class) " Preview/MarkdownPresentationParser.swift` → для каждого имени `rg` по приложению; список имён без вызывающих запоминается (это то, что удаляется молча), список с вызывающими обязан быть пуст.

### U9.1. Перевод тестов (до удаления)

Эталон поведения: «ожидания не ослабляются» (AGENTS.md, `testing.md`). Тест, упавший после перевода, — либо ошибка нового слоя (чинится в коде), либо запись в «Изменения оформления в редакторе» главного плана (U5.2) вместе с правилом; подгонять ожидание нельзя.

**U9.1.0. Механическая замена (один исполнитель, ~5 минут, затрагивает все 57 файлов, поэтому не параллелится).**
- Нужна одна функция `MarkdownPresentationBuilder.parse(_ text:, includeReadableText:, includeEmojiCandidates:, includeUppercaseRuns:, includeWikiLinks:, syntax:, detectsFrontMatter:, isCancelled:) -> MarkdownPresentation` с теми же именами и умолчаниями, что у `MarkdownPresentationParser.parse` (стр. 1650): внутри «ядро → построитель». Ожидается, что её уже сделали U5.1/U6.4 для служб приложения (`AIAgentTools`, `MarkdownTagReader` и др., 14 мест); если нет — создать в `Editor/MarkdownPresentationBuilder.swift` (~20 строк, не тестовый helper: она нужна приложению). См. «Спорное» п. 2.
- `sed -i 's/MarkdownPresentationParser\.parse(/MarkdownPresentationBuilder.parse(/g'` по 57 файлам, затем `swiftc -frontend -parse` каждого. Результат: список мест, где замена не компилируется (внутренние помощники и белый ящик, ~25 мест).
- Баз-проверка: `rg -c "MarkdownPresentationParser" LacEditorTests` → только места белого ящика.

**Подзадачи (после U9.1.0; файлы не пересекаются, идут параллельно; каждая заканчивается `-parse` и, где возможно, стендом):**

| Подзадача | Файлы | Строк | Что делать | Проверка |
| --- | --- | --- | --- | --- |
| U9.1.a Разбор и белый ящик (стенд) | `MarkdownPresentationParserTests` (1704), `MarkdownMathExtensionTests` (534), `MarkdownInlineHTMLTests` (123), `MarkdownEmojiCandidateExtractorTests` (106), `MarkdownReadableTextTests` (132), `MarkdownSourceMaskTests` (298), `MarkdownFormattingServiceTests` (630), `MarkdownNativeTableParserTests` (87), `MarkdownEmailSourceTests` (64), `MarkdownDataMediaTests` (97), `MarkdownWikiLinkTests` (59), `MarkdownEmojiStatisticsTests` (55), `MarkdownFormattingStateTests` (33), `MarkdownNativeMermaidParserTests` (17) | ≈3 900 | 10 мест `MarkdownPresentationParserTests`: тест строит дерево cmark и зовёт старые `highlightRanges`, `tableCellBreaks`, `Source.…` — переписать на вызов новых владельцев (ядро / `MarkdownPresentationBuilder+Table`), сценарии и данные те же. Файл переименовать (см. «Спорное» п. 3). `MarkdownReadableTextTests:30`: `MarkdownReadableTextParser.build` → функция из `MarkdownDocumentExtras` | `lac-writer-check/run-tests.sh` (все эти файлы там собираются) |
| U9.1.b Таблицы | `MarkdownNativeTableInteractionTests` (1446), `MarkdownNativeGeneratedBlockTests` (1079), `MarkdownTableNavigationTests` (415), `MarkdownLinkTableTests` (165), `MarkdownTableShortcutTests` (122) | ≈3 200 | 4 вызова `tableDisplay`, `tableRowDisplay` — на `MarkdownPresentationBuilder.tableDisplay` (U5.1.b) с теми же аргументами | `-parse`; Mac |
| U9.1.c Раскладка и ширина (AppKit) | `MarkdownLayoutTests` (3710), `MarkdownWidthTests` (1775), `MarkdownAudioInteractionTests` (1159), `MarkdownImageInteractionTests` (913), `MarkdownHiddenGlyphStressTests` (588), `MarkdownRevealLayoutTests` (132), `MarkdownImageTests` (504) | ≈8 800 | Только замена имени. Не менять стенды окон и ожидания | `-parse`; Mac |
| U9.1.d Буфер, ввод, службы (AppKit) | `MarkdownClipboardInteractionTests` (2462), `MarkdownClipboardCopyTests` (1662), `MarkdownFormattingInteractionTests` (969), `MarkdownHTMLMediaServiceTests` (644), `MarkdownImageUploadTests` (1739; белый ящик 2 места), `MarkdownEditTransactionTests` (502), `PandocExportTests` (1931), `PandocImportTests` (517) | ≈10 400 | Замена имени; `MarkdownImageUploadTests:85,94` — новый владелец помощников; `PandocExportTests`, `PandocImportTests` — по U7.1 | `-parse`; Mac |
| U9.1.e Остальное малое | остальные ~25 файлов до 400 строк (`MarkdownLinkNavigation*`, `MarkdownSectionMoveTests`, `MarkdownOutlineTests`, `TaskListEditingTests`, `TaskCheckboxTests`, `MarkdownDisplayMap*Tests`, `MarkdownFootnoteTests`, `MarkdownElementPathTests`, `MarkdownBaselineDocumentsTests`, `MarkdownHTMLBlockProofTests`, `CriticMarkupServiceTests`, `MarkdownRubyOutputTests` и др.) | ≈4 500 | Замена имени | `-parse`; стенд для тех, что в `test-files.txt` |
| (уже сделано другими) | `BaselineSupport` — U5.2; `MarkdownRendererTests`, `MarkdownPreviewTests`, `UIPolish*`, `Typora*` и т. п. 29 файлов по рендеру — U4.4; `MarkdownPresentationTests`, `MarkdownDisplayMapTests` (`shiftedForTextEdit`) — U5.3; `MarkdownLocalParseTests` — U6.2 | | Проверить `rg`, ничего не дублировать | `rg` |

**U9.1.f. Сверка до удаления (стенд, не в репозитории).**
1. Прогон `run-tests.sh` целиком: ожидание — только падения из `linux-only-failures.txt`.
2. Дифференциальный прогон (рекомендуется, «Спорное» п. 4): скрипт на стенде вытаскивает из 57 файлов все строковые литералы с Markdown (многострочные `"""` и `let source/text = "…"`), разбирает каждый и старым парсером, и `MarkdownPresentationBuilder.parse` и сравнивает дампом `BaselineDump` (код уже есть в `BaselineSupport`). Это единственный способ проверить на Linux 38 Mac-файлов. Различие классифицируется как в U5.2 (А — ошибка; Б/В — запись в главный план). Выполняется **пока оба парсера ещё существуют**, поэтому строго до U8.1.
3. В статус задачи записывается сопоставление «удаляемый тест → новый» (в основном «тот же, переименован»): `MarkdownPresentationParserTests` → новое имя; `MarkdownSemantic*` → `MarkdownDocumentModelCorpusTests` (U2.6); `MarkdownRendererTests` → тот же (U4.4).

### U8.1. Удаление

Один исполнитель (общие файлы).
1. `git rm`: `Preview/MarkdownPresentationParser.swift`, `Preview/MarkdownReadableTextParser.swift`. Если U4.4/U2.6 что-то из `MarkdownRenderer.swift`, `MarkdownSemanticDocument.swift` не удалили — удалить здесь.
2. `project.pbxproj` (правит основной агент): убрать 4+4 записи (см. 1.2) и, если остались, 4+4 записи `MarkdownRenderer`/`MarkdownSemanticDocument`. Проверка: `rg -c "MarkdownPresentationParser|MarkdownReadableTextParser|MarkdownRenderer\b|MarkdownSemanticDocument" LacEditor.xcodeproj/project.pbxproj` → пусто; число `PBXBuildFile` и `Sources` совпадает (по 1 на каждую новую запись: `MarkdownDocumentParser`, `MarkdownSourceMask`, `MarkdownFrontMatter`, `MarkdownHTMLRenderer*`, `MarkdownPresentationBuilder*`, `MarkdownRenderedPage` и др. из U2–U5 — это не удаление, но сверка «файл на диске ↔ запись в проекте» делается тут: `ls LacEditor/*/*.swift | wc -l` против числа `in Sources` на приложении).
3. `Scripts/verify-release.sh`, `Scripts/run-acceptance.sh`: убрать несуществующие файлы (их там нет), проверить полноту ручных списков `swiftc` (см. 1.2). На Linux это только `rg` по типам, настоящая проверка — Mac.
4. Стенды (вне репозитория, правит основной агент): `lac-writer-check/lib-files.txt` (стр. 75, 77, 79 → убрать; новые файлы слоя уже должны быть дописаны задачами U2–U5), `test-files.txt` (переименования); `lac-check`: удалить копию парсера, `patch-parser.py`, шим и `gen-document-parser-shim.py`, обновить `check-howto.md`, `grow.py`.
5. Документы: в `docs/agents/*.md` и `docs/markdown-editor-plan.md` убрать описания старого разбора — делает U10.1; здесь только то, без чего `rg` в U8.2 не пройдёт, если U10.1 откладывается.
6. Сборка стенда: `run-tests.sh` без `error:`; `git diff --check`.

### U8.2. Проверка «ничего не осталось»

Результат команд записывается в статус задачи. Исключения из поиска — журналы (`docs/TEST_STATUS.md`, `docs/TEST_PLAN.md`, `docs/FAILING_TESTS_*.md`, `docs/unified-model/`, `docs/markdown-unified-model-plan.md`).

```sh
P='MarkdownPresentationParser|MarkdownRenderer\b|MarkdownSemanticDocument|MarkdownReadableTextParser|separatingTitles|substitutingWikiLinks|shiftedForTextEdit|exceptions\.json|reapplyCriticColors|reapplyObsidianCommentColors|lac-semantic-check|MarkdownSemanticConsistency|MarkdownSemanticComparison'
rg -n "$P" LacEditor LacEditorTests Verification Scripts Package.swift LacEditor.xcodeproj docs/agents docs/markdown-editor-plan.md README.md AGENTS.md   # пусто
rg -n "cmark_parser_new|cmark_parse_document" LacEditor LacEditorTests    # только allow-list: ядро/обёртка + 2 независимых эталонных теста (MarkdownSpecConformanceTests, MarkdownDocumentModelCorpusTests)
rg -n -i "oldParser|legacyParser|useLegacy|useNewModel|fallbackToOld|старый путь|старый разбор" LacEditor LacEditorTests docs/agents   # пусто
rg -n "LAC_(USE|LEGACY|OLD)" LacEditor LacEditorTests Scripts   # пусто; допустим LAC_RECORD_BASELINE
```
Допустимые «старые» слова, не ошибка: `LegacyDiagramRenderService` (решение 7), `legacyInlineMath` (настройка синтаксиса). Критерий `rg renderPage` из главного плана заменён решением U4 на `MarkdownRenderer\b`.
Дополнительно: `MarkdownRenderBaselineTests`/`MarkdownPresentationBaselineTests` проходят без `LAC_RECORD_BASELINE` и `git status Fixtures/*Baseline*` не показывает изменений после прогона; `rg` по комментариям с именами удалённых функций (`hidden(`, `prepare(`, `finalize(`) пуст; орфаны: для каждого файла из U4/U7, где удалены вызовы, проверить, что приватные функции без вызовов удалены (Swift не предупреждает).

### U9.2. Новые тесты (после U8.2; на стенде `lac-writer-check`)

Новые файлы: `LacEditorTests/MarkdownUnifiedModelTests.swift` (+ дописать в `test-files.txt`; в `docs/TEST_STATUS.md` — «на Mac не запускался»). Образец стенда — `EditorDocumentMarkdownModelTests` (U4.1) и `MarkdownLocalParseTests`.

1. **Одна модель на версию.** (а) `EditorDocument`: после `installMarkdownModel` два вызова `markdownModel(forRevision:)` дают равные модели, правка текста сбрасывает слот (уже в U4.1 — здесь только сквозной сценарий). (б) Предпросмотр: замыкание `renderer` (U4.2) получает модель, если версия и настройки совпали, и `nil` иначе; при втором рендере той же версии (смена темы) модель та же. Счётчика разборов в production-коде **не добавлять** — наблюдаем по тому, что приходит в замыкание (правило «без флагов ради теста»). Асинхронность — опрос 30 × 100 мс.
2. **Склейка равна полному разбору.** Случайные правки с фиксированным зерном (12345, как `LOCALCHECK` в `lac-check`): документ из кириллицы, CJK, эмодзи (суррогатные пары), `\r\n`, таблицы, списки в цитате, блок кода, front matter, `%%`, CriticMarkup; после каждой правки модель/оформление из склейки (U6.2) `==` полному разбору. Сообщение с номером шага и правкой.
3. **`data-sourcepos` указывает на строку исходника.** Для документа с выносками, `![[…]]` (тестовый провайдер), wiki-ссылками, CriticMarkup, `%%`, front matter и CRLF: у заголовка, абзаца, пункта списка, таблицы, блока кода, цитаты и выноски в HTML `data-sourcepos="L:C-L2:C2"`; ожидаемые `L` записаны в тесте явно (по номерам строк исходника), строка `L` после снятия префиксов контейнера начинается с первых символов узла. Это закрывает пункт «`data-sourcepos` после выносок и встраиваний указывает на верную строку» из U3.4.
4. По необходимости (если не покрыто U2.6): отмена `isCancelled` возвращает `nil` и не публикует модель.

### U9.3. Mac (только пользователь; агент готовит инструкцию и шаблон отчёта)

1. «До»: замеры P1–P9 (таблица в `docs/agents/markdown-editing-flow.md`, стр. ~749) на сборке до миграции — коммит `b3c2394` (или `git stash` рабочей копии); «после» — на текущей. См. «Спорное» п. 7.
2. `swift build`, `swift build -c release`, затем Xcode `RunAllTests` **без прерывания** (AGENTS.md); `sh Scripts/prepare-pandoc.sh` перед сборкой; `./Scripts/verify-release.sh`, `./Scripts/run-acceptance.sh` (проверят ручные списки `swiftc`).
3. Один прогон `MarkdownRenderBaselineTests`, `MarkdownPresentationBaselineTests`, `MarkdownSpecConformanceTests` (различия Foundation Linux/macOS, как в статусе U0).
4. Ручная проверка из главного плана: оформление на корпусе, панель/прокрутка/PDF, копирование с оформлением, VoiceOver, IME.
5. Итог дописывается в `docs/TEST_STATUS.md` новым разделом (журнал не переписывается).

### U10.1. Документы

Правило для новых возможностей (в `markdown-editor.md`, раздел «Единый слой Markdown»): «узел в модели → вывод в оба адаптера (HTML, TextKit) → эталоны U0 → правила». Новый файл правил не создаётся (см. «Спорное» п. 8), `AGENTS.md` не меняется (возможно, одна строка про стенд и `LAC_RECORD_BASELINE`).

| Файл | Строк / попаданий | Что писать |
| --- | --- | --- |
| `docs/agents/markdown-editor.md` | 64 / 10 (стр. 12–59) | Раздел «Единый слой»: маска → ядро (`MarkdownDocumentParser`) → модель (версия, позиции UTF-16) → два адаптера; удалить правила про `MarkdownSemanticDocument` (стр. 56), старый `MarkdownPresentationParser` (14, 54), выноски «над готовым HTML» (48); описание 6 исправленных блоков кода (96, 97, 98, 109, 215, 241); список «Изменения оформления» из U5.2 |
| `docs/agents/export-and-preview.md` | 45 / 5 (17, 34, 40, 45) | Порядок `renderPage` (стр. 40) заменить: маска → модель → HTML-адаптер; `data-sourcepos` по исходному тексту; сводный просмотр из адаптера; «Намеренные изменения HTML» из U3.4 |
| `docs/agents/markdown-html-media.md` | 59 / 1 (42) | Подтверждение медиа/HTML/SVG/ruby — в ядре, одинаково для панели и редактора |
| `docs/agents/performance.md` | 39 / 4 (15, 17, 36, 39) | Один разбор на версию; модель публикуется контроллером; локальный разбор склеивает модель; `fullParseCount` |
| `docs/agents/text-state-and-background.md` | 28 | Модель — значение `Sendable` с номером версии; принимается только для текущей версии; на главном потоке полного разбора нет |
| `docs/agents/markdown-editing-flow.md` | 853 / 6 (79, 138, 651, 667, 777, 852) | Живые правила (стр. 79, 777) переписать; журнальные места (651, 667 про `reapplyCriticColors`, 852) пометить «история, код заменён U5a» или удалить имена (>800 строк: правка точечная, `rg` + `sed -n`) |
| `docs/agents/testing.md` | 75 / 2 (38, 46) | Строки таблицы: `MarkdownRendererTests` остаётся, добавить `MarkdownRenderBaselineTests`, `MarkdownPresentationBaselineTests`, `MarkdownSpecConformanceTests`, `MarkdownDocumentModelCorpusTests`, `MarkdownUnifiedModelTests`; правило «эталон перезаписывается (`LAC_RECORD_BASELINE=1`) только вместе с правилом в `docs/agents/`»; стенды `lac-writer-check`, `lac-check` (без `lac-semantic-check`) |
| `docs/agents/vault.md` (40), `notes.md` (11) | | `%%`, выноски, `![[…]]`, wiki — узлы модели и оформление из неё |
| `docs/markdown-editor-plan.md` | 449 / 10 (16, 157–164, 337, 356, 378, 417–421) | Раздел «этап 6/T6» заменить ссылкой на `markdown-unified-model-plan.md`; статусы T5/T6 пометить «заменено единым слоем» |
| `docs/TEST_STATUS.md`, `TEST_PLAN.md` | журналы | Только новый раздел; прежние записи не править |

Проверка U10.1: `rg` по паттерну U8.2 пуст; каждая ссылка на файл/тест в документе существует (`rg -o '`[A-Za-z]+Tests`' docs/agents | sort -u` сверить с `ls LacEditorTests`); имена функций в правилах находятся в коде.

## 3. Тесты — итог

- Переводятся: 57 файлов с `MarkdownPresentationParser` (U9.1) + 29 по рендеру (U4.4, уже до U8). Ожидания не меняются; данные уже содержат кириллицу/CJK/эмодзи/`\r\n` в корпусе U0 и в `MarkdownLayoutTests`/`PandocExportTests`.
- Новые: `MarkdownUnifiedModelTests` (U9.2, 3–4 теста); `MarkdownPresentationBuilderTests` и `MarkdownDocumentModelCorpusTests` создаются в U5.1/U2.6, не здесь.
- Удаляются: `MarkdownSemantic*` (U2.6). Переименовывается: `MarkdownPresentationParserTests`.
- Фикстуры: `Fixtures/GFMSpec/exceptions.json` удалён (U2.6), `RenderBaseline/`, `PresentationBaseline/` остаются.

## 4. Проверки

- Каждый изменённый `.swift`: `export PATH=/home/claude-bot/tools/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:$PATH; swiftc -frontend -parse <файл>`; `EditorCoordinator.swift` — `-typecheck -swift-version 5` (ошибка `no such module 'AppKit'` ожидаема); `MarkdownPresentationController.swift` — только `-parse`.
- Стенд `/home/claude-bot/tools/lac-writer-check/run-tests.sh` после U9.1.0, после каждой подзадачи a–e, после U8.1 и U9.2; `lac-check` (`check-howto.md`): сдвиги и склейка после U8.1.
- `git diff --check`; `git status` — не откатывать чужие незакоммиченные изменения.
- На Linux **не проверяется**: сборка 38 Mac-файлов (AppKit/TextKit), ручные списки `swiftc` в `Scripts`, `project.pbxproj` (только `rg`), WebKit, IME, VoiceOver, замеры P1–P9, различия Foundation Linux/macOS. Эти пункты идут в `docs/TEST_STATUS.md` как «на Mac не запускалось».

## 5. Риски

1. **Тихие расхождения в Mac-тестах.** 38 файлов (29 тыс. строк) проверяются только на Mac. Смягчение: дифференциальный прогон U9.1.f.2 и эталоны U0.2; без него первый красный прогон придёт уже после удаления старого парсера.
2. **Забытый помощник старого разбора** (вызывается по имени из другого файла) — после удаления файл не собирается, а Linux этого не видит для AppKit-файлов. Смягчение: U8.0 (опись `static`-членов) и `rg` по каждому имени.
3. **Ручные списки `swiftc` в `Scripts`** не проверяются стендом: пропущенная зависимость модели ломает `verify-release.sh`/`run-acceptance.sh` только на Mac.
4. **Параллельная правка** `MarkdownDocumentParser*.swift`/`MarkdownPresentationParser.swift` другими задачами: счётчики и номера строк плана к старту U8 устареют; U8.0 пересчитывает.
5. **Сопоставление «удаляемый тест → новый»** формально; если тест проверял поведение, которого новое ядро не воспроизводит, это станет видно только при переносе белого ящика (U9.1.a) — оставить 1–2 дня запаса.
6. **Стенд `lac-check`** держит копию парсера: его перевод забудут — U8.2 включает проверку каталога стенда.
7. **Документы >800 строк** (`markdown-editing-flow.md`, 853): точечная правка, иначе потеря журнальной истории.

## 6. Спорные решения (для утверждения основным агентом)

1. **Порядок.** Переставить U9.1 перед U8.1 (иначе тестовая цель не собирается). Рекомендую: U8.0 → U9.1 → U8.1 → U8.2 → U9.2 → U10.1 → U9.3.
2. **Где жить функции «текст → `MarkdownPresentation`».** Рекомендую публичную в приложении `MarkdownPresentationBuilder.parse(...)` с сигнатурой старого `parse` (служб приложения она тоже нужна), а не тестовый helper: тогда 606 вызовов меняются одной заменой имени. Альтернатива — helper в `BaselineSupport.swift` и тесты зависят от него (приложение его не видит).
3. **Имя `MarkdownPresentationParserTests`.** Предлагаю `MarkdownPresentationBuilderScenarioTests` (чтобы не путать с `MarkdownPresentationTests` и `MarkdownPresentationBuilderTests` из U5.1.d); либо разнести по темам (заголовки/списки/HTML/эмодзи) — дороже и не нужно.
4. **Дифференциальный прогон U9.1.f.2** на стенде (скрипт вне репозитория, ~полдня). Рекомендую делать: это единственная проверка 38 Mac-файлов до Mac. Если нет — U9.1 остаётся «готово на стенде / не проверено на Mac».
5. **Перевод `lac-check`** (копия парсера, шим): в U6.2 (рекомендую) или в U8.1.
6. **Allow-list для `cmark_parser_new`.** Предлагаю: `Preview/MarkdownMathExtension.swift` (общая обёртка `withDocument`, её используют ядро и эталонные тесты) + тесты `MarkdownSpecConformanceTests`, `MarkdownDocumentModelCorpusTests` (независимый эталон на чистом cmark). Если обёртку решат встроить в `MarkdownDocumentParser.swift`, список короче.
7. **Замеры P1–P9 «до».** Нужна сборка до миграции на Mac (HEAD `b3c2394` без незакоммиченных изменений или отдельная рабочая копия). Без неё сравнение «до/после» невозможно: уточнить у пользователя, где брать базу.
8. **Новый файл правил** `docs/agents/markdown-model.md` вместо раздела в `markdown-editor.md`? Рекомендую раздел в существующем файле (меньше правок `AGENTS.md`), но файл `markdown-editor.md` вырастет до ~120 строк.
9. **Журналы** (`TEST_STATUS.md`, `TEST_PLAN.md`, `markdown-editing-flow.md` как история) исключены из `rg` U8.2. Подтвердить исключение; иначе их придётся переписывать, потеряв историю.

## Решения основного агента

1. Порядок: проверка готовности → U9.1 → U8.1 → U8.2 → U9.2 → U10.1 → U9.3. Главный план исправлен.
2. `MarkdownPresentationBuilder.parse(...)` — функция приложения (общая с U6.0), 606 вызовов меняются заменой имени.
3. До удаления старого парсера — сравнение старого и нового разбора на строках-примерах из 38 тестов, не собираемых на Linux; скрипт вне репозитория, итог — в `docs/TEST_STATUS.md`.
4. Исключения в U8.2: `MarkdownMathExtension.withDocument` и два эталонных теста для `cmark_parser_new`; журналы (`TEST_STATUS.md`, `TEST_PLAN.md`, `markdown-editing-flow.md`) не проверяются.
5. Замеры P1–P9 «до» — сборка коммита `b3c2394` на Mac пользователем (U9.3, шаг пользователя; на Linux не выполняется).
6. `MarkdownPresentationParserTests` → `MarkdownPresentationBuilderTests`; копия парсера и шим стенда `lac-check` убираются в U8.1; правила — раздел в `docs/agents/markdown-editor.md`, отдельного файла нет.
7. Тестовых файлов со старым API — 73 (главный план исправлен).
8. (06.11.2026) U8.0 выполнен. Вне старого разбора к нему обращаются только ядро и `MarkdownSourcePositions`: `fencePrefixes` (`MarkdownDocumentParser+HTML.swift` 47, 75, 95, 140; `MarkdownSourcePositions.swift:708`), `simpleEmptyFencePrefix` (`MarkdownDocumentParser+Fence.swift:133`), `confirmedNamedAnchors` (`MarkdownDocumentParser.swift:67`). Кроме того, `MarkdownReadableTextParser.build` зовёт `MarkdownDocumentParser+Extras.swift:45`. Всё это переезжает в файлы ядра отдельной задачей перед U8.1 (перенос, не копия). `cmark_parser_new` вне `MarkdownMathExtension.withDocument` остаётся ещё в `MarkdownHTMLConfirmation.imageIdentity` (перенесён без изменений в U7.3.b): это файл ядра, разбор одной картинки, допускается как исключение U8.2.
9. U9.1.0 выполнен заменой имени `MarkdownPresentationParser.parse(` → `MarkdownPresentationBuilder.parse(` (599 вызовов в 57 файлах, `-parse` чистый). Имя `MarkdownPresentationBuilderTests` уже занято (U5.1.d), поэтому `MarkdownPresentationParserTests` переименовывается в `MarkdownPresentationBuilderScenarioTests`. Четыре вызова старого `tableDisplay` в тестах переводятся на путь, которым пользуется приложение (`MarkdownPresentationBuilder+Table`).
10. Тесты-сверки «модель = старый разбор» (`MarkdownDocumentExtrasTests`, `MarkdownDocumentReplacementsTests`, `MarkdownDocumentElementsTests`, `MarkdownDocumentFenceTests` — тесты, которые сравнивают модель с `MarkdownPresentationParser.parse`) на замену имени не переводятся: после неё они сравнивали бы модель с построителем, который из неё же собран. До U8.1 они зовут старый разбор, в U8.1 такие тесты удаляются (как сверка копирования в U4.5.6), остальные тесты этих файлов остаются.

## U9.1: отличия сценарных тестов

Файл `LacEditorTests/MarkdownPresentationBuilderScenarioTests.swift` после механической замены вызовов: в логе падало 11 тестов (двенадцатого нет). Причины и правки:

| Тест | Причина | Класс | Что сделано |
| --- | --- | --- | --- |
| testEditingTextReplacementMapsTabbedUnicodeSource, testEditingWhitespaceProvesWholeLeadingTabs, testEditingWhitespaceProvesTopLevelParagraphEdges, testPlainMultilineContinuationTabsUseExactRetainedSuffix, testReferenceRetainedTabsMapInlineRanges | Позиции cmark на строках с табом ненадёжны; старый разбор подтверждал текст по кандидатам-колонкам (байты и знаки, шаг таба 4), ядро не умело | А | Перенесён `tabColumns` в `MarkdownSourcePositions`; `Context.tabbedTextRange` в `MarkdownDocumentParser.swift` берёт единственного кандидата, прошедшего `MarkdownInlineTextProjection.pieces`; префикс контейнера для unreliable-абзаца берётся от первого подтверждённого inline-узла (`finish` в `block()`); `inlineRange` для кода берёт `source.range` |
| testFenceContainerLinesConfirmParagraphPrefix | Нулевой префикс контейнера на абзаце со строками с табом | А | Тот же `prefixRange` |
| testInlineSpanUsesConfirmedTypedStylePairs, testMultilineBodyTabsKeepConfirmedInlineHTML, testMultilineEditingMapsConfirmedInlineHTML | Диапазоны `html_inline` у cmark сдвинуты в многострочном абзаце и во вложенных контейнерах; парные теги HTML принимались как подтверждённые в строгом режиме абзаца | А | `confirmHTML` (`+HTML.swift`): `paragraphLazy` даёт диапазоны через `lazyParagraphInlineRanges` (в том числе для пар); в `isProvable` (`+Replacements.swift`) парный тег (маркер `<`) в строгом режиме не доказан |
| testMultilineEditingMapsOnlyExactMarkdownImages | Картинки с заголовком, ссылкой-определением, экранированием и сущностью на строке продолжения: старый разбор их не показывал, новый показывает с точными диапазонами (как на первой строке) | Б | Ожидание заменено: одна картинка, диапазон равен разметке; комментарий над проверкой |
| testFenceContextTracksOpaqueLinesIndependentlyOfPresentation | Текст с NUL: U6.1 заменяет NUL на U+FFFD, контекст ограждений есть (раньше разбор был пустым) | Б | Ожидание для `"\0"` стало `XCTAssertTrue`; комментарий |

Заметно пользователю (только в лучшую сторону): картинки на строках продолжения абзаца показываются так же, как на первой строке; текст с NUL оформляется; элементы на строках с табом (текст, замены, абзацы пунктов) подтверждаются и оформляются.

Побочные правки по проверкам стенда:
- `MarkdownPresentationBaselineTests` (editor, editor-loose): в `spec/0009 | Tabs` добавился третий абзац `16+8` (пункт `\t - baz`) — совпадает со старым разбором; эталоны `editor.spec.txt` и `editor-loose.spec.txt` перезаписаны (изменилась только эта запись, класс А), остальные эталоны и `MarkdownRenderBaselineTests` не менялись.
- `MarkdownDocumentFenceTests`: вход `"> a\t**b** *c*\n"` добавлен в `knownDivergences` (поле `containerLines`: модель подтверждает префикс цитаты, старый разбор отдавал пустой список), класс Б.

Остаточные отличия класса Б в порядке spans, лишних `fenceContainerLines` (`> hard  \n> break`) и правках `spaces` в абзаце после определений ссылок с табом тестами не проверяются и ожидания тестов не меняют.

Стенд `lac-writer-check` под flock: зелёный, кроме 5 тестов `MarkdownClipboardCopyTestsCorpus` (ImageIO). `MarkdownDocumentExtrasTests`, `MarkdownDocumentReplacementsTests`, `MarkdownDocumentElementsTests`, `MarkdownDocumentFenceTests` проходят.

## U9.1.f: итог сверки старого и нового разбора

Сверка на 11 418 литералах из тестов (45 672 варианта: перевод строки, CRLF, режим full). До правок различались 915 литералов (7 900 записей), после — 794 литерала (7 442 записи, из них 168 — только порядок элементов, класс В). Группы класса А исчезли полностью (`A_PARA_WIKI_EMOJI` было 54 литерала, `<a href>`, `<kbd>` после `<script>`), `A_TAB` упала со 107 до 36 литералов; всё оставшееся — классы Б/В, кроме одного известного остатка (ниже). Идентичны старому 21 328 вариантов.

Исправлено (класс А), у каждой правки есть тест в `MarkdownPresentationBuilderScenarioTests` / `MarkdownDocumentParserHTMLTests`:
- А1: `<a href>дом</a>` снова даёт span `link` с двумя скрытыми тегами (`testHTMLLinkInParagraphHidesBothTags`).
- А2: абзац из одного `[[Цель]]` или `:smile:` сохраняется (`testParagraphOfSingleWikiLinkOrEmojiIsKept`).
- А3: таб после `>`/маркера списка: абзац восстанавливается по подтверждённым листьям, обёртка выделения без позиции не мешает, мягкий перенос без позиции не теряет абзац (`testTabAfterQuoteMarkerKeepsParagraphWithStrongRuns`); сущность `&amp;` не режет текст на строке с табом.
- А4: `<kbd>`/`<u>` после `<script>` в цитате и списке подтверждаются (порт `scriptGapPrefixes` в `confirmHTML`; `testKeyboardAfterScriptInQuoteAndListKeepsTags`, старый тест `testScriptInQuoteAndListResetsContext` переписан в `...KeepsConfirmedContext`).
- Зачёркивание через перенос строки (`~~з\nд~~`): cmark-gfm даёт ему конец первой строки; теперь у такого узла нет позиции, дети берут границы родителя, абзац сохраняется, ложного span нет (`testStrikethroughAcrossLinesInQuoteKeepsParagraphWithoutFalseSpan`).

Решения по «панель верна» (класс Б, новый слой совпадает с панелью):
- `<iframe>`/`<audio>` внутри `<div>`: cmark считает весь `<div>` блоком сырого HTML, панель виджет не строит.
- `**…**` и `<strong>` внутри `<ruby>`: жирное входит в `baseRuns` ruby (панель показывает `<strong>` внутри `<ruby>`), отдельного span нет.
- `<br class>`, `<script><br>`: панель выводит «raw HTML omitted», в модели это `brBlocked`; абзац не оформляется.
- `<AUDIO src>` (верхний регистр): панель делает `<audio>`, абзац из одного медиа текстом не считается.
- `* п\n\n  > ~~з\n  > д~~ и`: абзац есть и у панели, и теперь у нового слоя; у старого был ложный span `9+3` без маркеров.
- Ленивые продолжения цитаты и списка, `[\n ]: /uri`, сноски: новый слой даёт абзац там, где старый его терял (панель показывает абзац).

Бывший остаток `- [a]: /x\n  q\t*a&amp;* z` исправлен: литерал, совпавший с началом сущности (`a&` перед `amp;`), расширяется до `;`, если исходник декодируется в литерал (`Context.entityExtended` поверх общего `MarkdownInlineTextProjection.pieces`; правка в `followingText`, обычные абзацы без табов не затронуты). Тесты: `testEntityInEmphasisOnTabbedLineAfterReferenceDefinition` (LF и CRLF, точные span и абзац); ожидание в `testEmphasisAfterReferenceDefinitionsFindsMarkersInAllPositions` изменено с «ненадёжно» на точный диапазон 14+8. После правки сверка: 794 литерала, 7 442 записи, `A_TAB` 36 литералов (все Б/В). Класса А не осталось.

Эталоны `editor.spec.txt` и `editor-loose.spec.txt` перезаписаны по двум записям: `spec/0518` (ссылка через перенос строки) и `spec/0659` (`*foo\` + перенос) — теперь есть абзац, как показывает панель.
