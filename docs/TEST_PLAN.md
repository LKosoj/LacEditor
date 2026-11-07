# План доведения тестов до чистого прогона

## Цель

Добиться полного прохода тестов LacEditor в конфигурации Develop/Debug на
macOS: 0 ошибок, 0 предупреждений, 0 пропусков GUI-тестов.

Актуальный список падений и адресный чек-лист ведётся отдельно: [FAILING_TESTS_2026-11-05.md](FAILING_TESTS_2026-11-05.md).

## Правила

1. Перед изменениями проверять `git status` и сохранять чужие изменения.
2. Собирать через Xcode `BuildProject(buildForTesting: true)`.
3. После сборки проверять `GetBuildLog(severity: warning)`.
4. Полный `RunAllTests` запускать одним прогоном и ждать его штатного
   завершения без таймаута и без повторного запуска поверх него. Длительный
   полный прогон не считать зависшим и не прерывать. Пачки использовать только
   после завершения полного прогона для диагностики конкретных классов.
5. GUI-тесты на macOS не пропускать. Исправлять production-код, тестовый
   стенд или ошибочное ожидание — по причине конкретного падения.
6. После каждого исправления запускать затронутый класс и фиксировать результат
   в `docs/TEST_STATUS.md`.
7. Не использовать Production-сборку для проверки тестов и не изменять
   production-окружение.
8. Перед завершением выполнить `git diff --check`, чистую сборку и итоговый
   прогон всех тестов.
9. Отдельно разобрать все тесты со статусами `not run` и `skipped`: установить
   причину (test plan, target membership, условное отключение, окружение или
   ошибка запуска), устранить её либо документировать обоснованное исключение.
   Итоговый прогон не считать чистым, пока эти состояния не объяснены.
10. В target `LacEditorUITests` переносить только сценарии, где unit-тест не
   может корректно воспроизвести реальную доставку ввода (например,
   синтетические AppKit `keyDown`, IME или first responder). Обычные UI-
   проверки не переносить без отдельной причины; для проблемных сценариев
   использовать `XCUIApplication`/`typeText`, а не `NSWindow.sendEvent`.
11. Перед исправлением любого падающего теста искать похожие проходящие тесты
    и сравнивать fixture, оконный стенд, ожидания и управление жизненным
    циклом; исправление строить на рабочем образце, а не на предположении.
12. Не запускать сборку или тесты без подтверждённого изменения кода/fixture.
    Повторный запуск без изменения разрешён только как явно зафиксированный
    диагностический запуск. Если ранее проходивший тест начал зависать,
    сначала анализировать регрессию и логи.

## Рабочие этапы

1. Завершить точечную миграцию проблемных UI-сценариев в `LacEditorUITests`.
   Новый target уже создан в Xcode; переносить только сценарии с проблемной
   доставкой клавиатуры/IME/first responder и проверять их через `typeText`.
2. Закрыть оставшиеся падения `MarkdownAutoPairTests`.
   Проверить путь `NSEvent → LacTextView.keyDown → insertText →
   MarkdownAutoPairService`; отдельно проверить тестовый оконный стенд и
   первого ответчика.
3. Повторно запустить `MarkdownFootnoteTests`, `ManuscriptServiceTests` и
   `MarkdownElementPathTests` после изменений контроллера.
4. Повторить ранее успешные классы небольшими пачками.
5. Запустить полный набор unit- и UI-тестов одним непрерывным `RunAllTests` и
   дождаться итогового отчёта; после него при необходимости перейти к пачкам.
6. Проверить предупреждения сборки и `git diff --check`.
7. Разобрать `not run` и `skipped`, проверить активный test plan и membership
   тестов.
8. Обновить `docs/TEST_STATUS.md` итоговыми цифрами и оставшимися ограничениями.

## Правило размещения UI-тестов

Для AppKit/SwiftUI unit-стендов, создающих `NSWindow` вручную, обязательна
явная раскладка hosting view: задать frame по размеру окна, `isHidden = false`,
вызвать `displayIfNeeded()` и `layoutSubtreeIfNeeded()`, а затем проверить
`NSTextView.string` и ненулевой frame. Иначе окно может быть видимым, но
содержать визуально пустой редактор, а проверки temporary attributes будут
ложно падать.

Только тесты, для которых unit-стенд не воспроизводит реальную доставку
пользовательского ввода (синтетические `keyDown`, IME, first responder),
размещаются в target `LacEditorUITests`. Остальные UI-проверки не переносятся
автоматически. Для перенесённых сценариев используется `XCUIApplication` и
`typeText`; ручной вызов `NSWindow.sendEvent` не используется.

Проверка target’ов:

- [x] В Xcode создан target `LacEditorUITests` (`bundle.ui-testing`).
- [ ] Перенести только проблемные UI-сценарии из `LacEditorTests`; пока
  подтверждён только существующий auto-pair сценарий.
- [x] Реальная доставка ввода для проблемных клавиш проверяется через
  `XCUIApplication` и `typeText`; логика автопар остаётся в unit-проверках
  `MarkdownAutoPairService`.
- [ ] Скрипт `Scripts/run-acceptance.sh` запускает Xcode Debug test pass,
  включающий `LacEditorUITests`.

## Чек-лист выполнения

- [x] Зафиксировать правила и статус в Markdown-файлах.
- [x] Добиться чистой Develop/Debug-сборки.
- [x] Исправить fast-path ревизии и закрыть `MarkdownFootnoteTests`.
- [x] Закрыть `ManuscriptServiceTests`.
- [x] Закрыть `MarkdownElementPathTests`.
- [ ] Устранить два падения `MarkdownAutoPairTests`: синтетические оконные
  сценарии удалены из unit-target, а доставка пользовательского ввода вынесена
  в UI-target; production fallback и `skip` не используются.
- [ ] Перенести оставшиеся проблемные UI-сценарии в `LacEditorUITests`;
  обычные проверки сервисов и моделей оставить в unit-target.
- [x] Добавить в `LacEditorUITests` реальные сценарии ввода Markdown через
  `XCUIApplication`/`typeText` для auto-pair (2/2).
- [x] Запустить ранее успешные классы короткими пачками (132/132).
- [ ] Запустить полный набор тестов одним непрерывным прогоном и дождаться его
  штатного завершения; диагностические пачки запускать только после отчёта.
  Прогон 2026-11-05 завершён штатно (3904: 3727 passed, 165 failed,
  11 skipped, 1 not run), поэтому этап запуска выполнен, но критерий чистоты
  остаётся невыполненным.
- [x] Установить причины всех 11 `skipped`: 4 headless
  `FolderQuickOpenTests`, 4 UI-перенесённых сценария
  `MarkdownFormattingInteractionTests` и 3 опциональных `UIExperimentTests`,
  включаемых переменными окружения. Единственная запись `No result` — пустой
  агрегатный suite `LacEditorTests` (`LacEditorTests.swift:2`); отдельного
  `not run` test case в текстовом отчёте нет.
- [ ] Подтвердить причину счётчика Xcode `1 not run`: текстовый отчёт не
  содержит такого состояния, поэтому после следующего прогона нужно сверить
  исходный `xcresult` и формат его сводки; не считать `No result` доказанным
  `not run`.
- [x] Проверить 0 предупреждений и выполнить `git diff --check`.
- [ ] Обновить итоговый статус и отметить цель выполненной после общего прогона.

### Последняя адресная проверка (2026-11-05)

- Полный `RunAllTests` после чистой сборки: 3911 тестов, 3776 passed,
  123 failed, 11 skipped, 1 not run; предупреждений сборки нет.
- `MarkdownAudioInteractionTests`: 26/28; два media runtime-падения
  воспроизводятся изолированно (remote SVG и vertical iframe).
- После iframe-cleanup targeted-прогон `MarkdownAudioInteractionTests` снова
  26/28: stale-view assertion устранён, остаются remote SVG timeout и
  vertical geometry (160 вместо 180).
- После исправления предупреждения `NSRange` повторная сборка чистая:
  `GetBuildLog(severity: warning)` — 0.
- Разбор группы layout завершён: внесены минимальные правки геометрии
  native page-break, fallback `rawHTMLRanges` и снятие iframe при reveal;
  `MarkdownAudioInteractionTests` — 26/28, отдельный
  `testNativePageBreakGeometryAndReveal` — 0/1 (rect не найден).
- Разбор `MarkdownRendererTests` завершён без правок: статический анализ не
  подтвердил безопасную production-причину первичных падений; требуется
  runtime-диагностика targeted-тестами.
- PDF-export группа разобрана без правок: production-путь подготовки media и
  SVG статически согласован, но промежуточный HTML/PDF runtime не подтверждён;
  правки отложены до диагностического запуска.
- Preview группа (link routing, stale DOM, local audio) разобрана без правок:
  guards и revision/generation checks согласованы, подтверждённой причины без
  runtime-assertions нет.
- Image copy/edit группа разобрана без правок: snapshot/selection guards,
  retained remote copies и undo-группы статически соответствуют контракту;
  production-изменение без дополнительного runtime-доказательства отклонено.
- Renderer-разбор выявил подтверждённый дефект HTML audio с boolean `controls`:
  ветка использовала строгий `audioSource`. Исправление переведено на
  `embeddedMedia`; сборка чистая, но полный `MarkdownRendererTests` пока
  остаётся 92/103 (11 падений), включая raw HTML/media сценарии.

- Полный `RunAllTests`: 3904 всего, 3727 passed, 165 failed, 11 skipped,
  1 not run; сборка и журнал предупреждений чистые.
- `FolderOpeningTests/testQueuedFolderThenFileKeepsExplicitFolder` — 1/1
  после разрешения повторного `fulfill` по образцу проходящего теста.

- `MarkdownPresentationTests/testFormattingAndReturningToSourcePreserveTextAndSelection` — 1/1 после исправления fixture и ожидания production-разбора.
- `MarkdownPresentationTests/testInactiveEditorWaitsUntilActivationToApplyFormatting` — 1/1 после исправления fixture окна/first responder и ожидания production-разбора.
- Класс `MarkdownPresentationTests` — 55/75 passed, 20 failed; полный прогон пока не повторяется до исправления подтверждённых причин.
- `TaskCheckboxTests/testClickUsesCurrentSourceAndUndo` — 1/1.
- `ToolbarDefaultsTests/testDefaultToolbarItemIdentifiers` — 1/1.
- `MarkdownFormattingInteractionTests` — 12/16 passed, 0 failed, 4 skipped;
  skipped-сценарии перенесены в `LacEditorUITests`.
- Критерий классификации: тест, который ждёт нажатия кнопки либо зависит от
  реальной доставки клавиатуры/first responder/IME, относится к UI-сценарию.
  Такие тесты переносить в `LacEditorUITests`; внутренние проверки parser и
  controller без пользовательского события оставлять в `LacEditorTests`.
- `MarkdownAudioInteractionTests` — 19/28 passed после синхронизации fixture;
  9 media runtime-падений остаются.
- Адресный повтор 2026-11-05: 22/28 passed, 6 media runtime-падений
  воспроизводятся изолированно; следующий шаг — сравнить их fixture с
  проходящими `MarkdownAudioInteractionTests` перед любым патчем.

## Linux-стенд (2026-11-04)

Тесты без AppKit/AppState собираются и запускаются на сервере стендом
`/home/claude-bot/tools/lac-writer-check` (`run-tests.sh`, подробности — в
`docs/TEST_STATUS.md` и `docs/agents/testing.md`). Стенд не заменяет прогон на Mac.

Сделано:

- [x] Стенд подключён ко всем тестам без AppKit/AppState: 1873 теста, 1 пропуск
  (`FileVersionServiceTests`, том без хранилища версий).
- [x] Исправлен код: таблица имён узлов Swift в `TreeSitterGenericBackend`
  (`SyntaxParser.swift`), экранирование `\[[` в wiki-ссылках, граница длины в
  `MarkdownReadableText`, `stableHelp` в `FolderSearchView`,
  `CriticMarkupExportAccessory`, `on*`-атрибуты у изображения в
  `MarkdownHTMLMediaService`, эмодзи внутри подтверждённой `<a href>`.
- [x] `MarkdownPresentationParser`: колонка продолжения пункта задачи, таблица в
  `tasklist`, незакрытый fenced-блок, табуляция в заголовке оглавления, жёсткий
  перенос `\` (отставание строк cmark), табуляция в префиксе цитаты/списка.
- [x] Исправлены ошибочные ожидания тестов (без ослабления проверок):
  `TextCompareController`, `MarkdownBacklinks`, `FileVersion`,
  `MarkdownReadableText`, `MarkdownTableEditing`, `SemanticFont`, `UIPolishK`,
  часть `MarkdownPresentationParser`.
- [ ] Итоговый чистый прогон ещё не достигнут: после исправлений остаются
  только ещё не проверенные классы и общий прогон; Linux-only список не считать
  объяснением Mac-падений.

Осталось:

- [ ] Собрать на Mac и прогнать изменённые классы, прежде всего
  `MarkdownPresentationParserTests`, `MarkdownEmojiCandidate*`,
  `MarkdownHTMLMedia*`, `SyntaxParser`/Tree-sitter, `FolderSearchView`.
- [ ] Проверить на Mac тесты, которые на Linux не запускаются: AppKit/AppState,
  JavaScriptCore, Keychain, `FocusSentenceTests` (`.bySentences`) и тесты из
  `linux-only-failures.txt`.
- [ ] Затем выполнить общий итоговый прогон из чек-листа выше.

## Текущее состояние (Mac)

### Проход 2026-11-07

- [x] `BuildProject(buildForTesting: true)`: 0 ошибок, 0 предупреждений.
- [x] Проверена адресная пачка из статуса: 291 тест, 248 passed, 43 failed,
  0 skipped, 0 not run.
- [x] Исправлен lifetime `NSTextStorage` в 12 fixture
  `MarkdownLayoutTests`; повторный класс: 93/120 passed, 27 failed.
- [x] Закрыты три нестабильных clipboard-сценария: 3/3 passed.
- [x] Закрыты четыре media-сценария `MarkdownAudioInteractionTests`: 4/4
  passed.
- [x] Закрыто одиночное падение `MarkdownFootnoteTests`: 1/1 passed.
- [x] Повторён `MarkdownLayoutTests` после fixture-исправлений: 103/120
  passed, 17 failed, 0 skipped, 0 not run.
- [x] Закрыты адресно: смена code font, повтор code highlight после IME,
  обновление HTML block и plain details после метрик, состояние details после
  rebuild/IME, centered heading после смены настроек (6/6).
- [x] Проверены и отклонены гипотезы TOC-fixture про `visibleRect`, высоту
  view и `allowsNonContiguousLayout`: `firstUnlaidCharacterIndex` остаётся
  равен длине текста; неэффективные изменения отменены.
- [x] Диагностический повтор `MarkdownLayoutTests`: 120 тестов, 105 passed,
  15 failed, 0 skipped, 0 not run. Ранее открытый centered-heading сценарий
  подтверждён как проходящий; список оставшихся падений обновлён по отчёту
  Xcode `C88961EC-6A40-4F49-8770-5470FA720233.txt`.
- [ ] Разобрать и устранить оставшиеся 14 падений `MarkdownLayoutTests`.
  `testParagraphSpacingReplacesBlankSeparatorAndRevealsSource` закрывать
  последним из известных адресных падений по указанию пользователя; `XCTSkip`
  в код не добавлялся. Сразу после его исправления и контрольных адресных
  проверок перейти к полному тестированию.
- [x] Закрыть `testParagraphAlignmentChangesVisibleTextAndRestoresSource`:
  1/1; соседние alignment/numbering сценарии — 3/3.
- [x] Повторить `MarkdownLayoutTests` после alignment-исправления: 120 тестов,
  106 passed, 14 failed, 0 skipped, 0 not run.
- [x] Закрыть `testShiftInPlaceMovesImagesFormulasAndEmoji`: plain text того же
  абзаца подтверждается через `MarkdownImage.paragraphRange`; связанная пачка
  shift-сценариев проходит 4/4.
- [x] Повторить `MarkdownLayoutTests` после shift-исправления: 120 тестов,
  107 passed, 13 failed, 0 skipped, 0 not run.
- [x] Закрыть восстановление номера при раскрытии заголовка без доступного
  viewport: основной и два соседних сценария проходят 3/3.
- [x] Закрыть лишнюю invalidation при inline selection в обычном тексте:
  основной и два соседних сценария проходят 3/3.
- [x] Повторить `MarkdownLayoutTests` после двух исправлений: 120 тестов,
  109 passed, 11 failed, 0 skipped, 0 not run.
- [x] Закрыть повторный рендер Ruby после смены метрик/appearance: основной
  сценарий 1/1; соседние Ruby-сценарии сохраняют результат 2/2.
- [x] Повторить `MarkdownLayoutTests` после Ruby-исправления: 120 тестов,
  110 passed, 10 failed, 0 skipped, 0 not run.
- [ ] Повторить целиком `MarkdownAudioInteractionTests` и
  `MarkdownClipboardInteractionTests` после закрытия известных кластеров.
- [ ] После последнего исправления
  `testParagraphSpacingReplacesBlankSeparatorAndRevealsSource` выполнить
  единый непрерывный `RunAllTests`, дождаться штатного завершения и затем
  устранить все обнаруженные ошибки и предупреждения до чистого прогона.

- `MarkdownElementPathTests`: 22/22.
- `MarkdownFootnoteTests`: 9/9.
- `ManuscriptServiceTests`: 17/17.
- `MarkdownAutoPairTests`: 5/5 unit-тестов проходят; 2 проблемных сценария
  реальной доставки ввода проходят в `LacEditorUITests` (2/2).
- Develop/Debug build: 0 ошибок, 0 предупреждений.
- Повторная пачка успешных классов: 132/132.
- `MarkdownImageTests`: 14/14 проходят после исправления fixture lifecycle,
  переноса media-cache, divergent parse и pending remote loading.
- Полный прогон 2026-11-05 завершён штатно: 3900 тестов, 3701 passed,
  191 failed, 7 skipped, 1 not run. Следующий этап — распределить новые
  падения по кластерам и устранить их; причины 7 skipped и 1 not run также
  должны быть отдельно установлены и записаны.
- Правило диагностики: перед исправлением каждого падения сверять fixture,
  lifecycle и ожидания с похожим проходящим тестом; полный прогон запускать
  только после устранения известных падений и дожидаться его завершения.
- Сценарии, ожидающие кнопку или зависящие от реальной доставки клавиатуры,
  first responder, IME либо text-checking/completion, считать UI-тестами и
  переносить в `LacEditorUITests`; текущие math-pair и smart-quote требуют
  такого переноса или отдельной диагностики AppKit event delivery.
- После переноса UI-сценариев проверять не только наличие окна, но и
  editable/first-responder state перед `typeText`; таймаут синтеза события
  считать отдельной ошибкой fixture/lifecycle.
