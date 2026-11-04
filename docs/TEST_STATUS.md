# Статус проверки тестов LacEditor

Последнее обновление: 2026-11-04

## Цель

Добиться полного прогона тестов в режиме Develop/Debug на macOS без ошибок,
предупреждений и пропусков GUI-сценариев.

## Правила запуска

- Использовать Xcode-схему `LacEditor` и конфигурацию Develop/Debug.
- Сначала выполнять `BuildProject(buildForTesting: true)`.
- Проверять предупреждения через `GetBuildLog(severity: warning)`.
- Пачка тестов не должна работать дольше 30 секунд; большие наборы делить по
  классам или отдельным тестам.
- GUI-тесты не пропускать на macOS; исправлять код, тестовый стенд или ожидание.
- Не менять production-окружение и не запускать production-сборку как замену
  тестовой.
- После каждого исправления запускать затронутый класс, затем добавлять его в
  итоговый проход.
- Перед завершением выполнить `git diff --check` и полный итоговый прогон.

## Последние результаты

| Набор | Результат | Состояние |
|---|---:|---|
| `MarkdownElementPathTests` | 22/22 | проходит |
| `MarkdownFootnoteTests` | 9/9 | проходит |
| `MarkdownAutoPairTests` | 5/7 | 2 падения; синтетические клавиши не доставляются в оконном стенде |
| `ManuscriptServiceTests` | 17/17 | проходит |
| Сборка Develop/Debug | 0 ошибок, 0 предупреждений | проходит |
| `MarkdownAutoPairTests` (повтор 2026-11-04) | 5/7 | 2 падения в оконном стенде |

Дополнительная пачка 2026-11-04: `MarkdownElementPathTests`,
`MarkdownFootnoteTests`, `ManuscriptServiceTests`, `FolderWorkspaceTests`,
`MarkdownFormattingServiceTests`, `AutosaveTests` — 132/132, 0 ошибок,
0 пропусков.

После устранения предупреждения повторная пачка `MarkdownElementPathTests`,
`MarkdownFootnoteTests`, `ManuscriptServiceTests` — 48/48, 0 ошибок,
0 пропусков.

Ранее также подтверждены проходы `FolderWorkspaceTests` (24/24),
`MarkdownFormattingServiceTests` (44/44), `AutosaveTests` (16/16) и крупные
пачки AI/Markdown/Clipboard тестов.

## Linux-стенд `lac-writer-check` (2026-11-04)

Тесты без AppKit/AppState собираются на Linux стендом `/home/claude-bot/tools/lac-writer-check`
(Swift 6.0.3, OpenCombine, tree-sitter из `Vendor/`). Прогон `run-tests.sh`: 1873 теста,
1 пропуск (`FileVersionServiceTests`, том без хранилища версий), падения только
Linux (`linux-only-failures.txt`: ImageIO, FSEvents, `NLTokenizer`, CRLF как один `Character`)
настоящих падений нет.

Исправлены: жёсткий перенос `\` в заголовке (cmark не переводит позицию на новую строку,
текст после него и после следующих мягких переносов получает чужую строку — такие узлы
теперь остаются исходником), эмодзи внутри подтверждённой HTML-ссылки `<a href>` и пять
случаев табуляции в префиксе цитаты или списка (код приведён к тестам: частично
поглощённая маркером табуляция оставляет строку исходником).

Классы с AppKit/AppState, JavaScriptCore, Keychain и `.bySentences` (`FocusSentenceTests`)
на Linux не запускаются.

## Что осталось расследовать

1. `MarkdownAutoPairTests`: `LacTextView.keyDown` в оконном тестовом стенде не
   вставляет обычные символы и пары; повтор подтверждает падения
   `testMathPairUsesCurrentEditorAndLocalSkip` и
   `testActualInputSkipDeleteUndoAndGuards`. Проверять состояние первого
   ответчика, делегат и путь `keyDown` без ослабления ожиданий.
2. Полный прогон 3898 тестов остановлен после превышения лимита длительности;
   разбить его на пачки по классам.
3. После исправлений повторить все ранее успешные классы и полный прогон.

## Фактический полный прогон Xcode (2026-11-04)

Из завершённого результата `RunAllTests` извлечены реальные падения через
`xcresulttool`: 3897 тестов, 270 упавших, 7 пропущенных, 0 предупреждений.
Файл `/private/tmp/failed-tests.txt` содержит 275 имён test cases, поскольку
часть тестов имеет несколько failure issues; это не число уникальных падений.
Падения распределены между тремя аналитическими агентами по функциональным
группам; агенты только анализировали причины и не редактировали файлы.

## Журнал изменений

- Исправлена проверка отключённого парсинга в `MarkdownElementPathTests`: тест
  явно отключает `wordCount`, чтобы не оставался скрытый потребитель разбора.
- Удалены попытки пропускать GUI-тесты; GUI-сценарии считаются обязательными.
- В тестовом стенде автопар добавлены явное `isEditable` и показ окна, но это не
  устранило проблему вставки; требуется дальнейшее расследование.
- Уточнено ожидание HTML-адресов в `ManuscriptServiceTests`: cmark уже считает
  HTML-ссылку, отдельный media-проход не должен дублировать её.
- Попытка добавить fallback-вставку для синтетических `keyDown` отклонена:
  она дублировала парные символы в реальном пути AppKit; production-код
  оставлен без этого fallback.
- Исправлен fast-path: `beforeEdit` сохраняет ожидаемую следующую ревизию
  (`currentRevision + 1`), поэтому `edited(revision:)` сохраняет сдвинутую
  презентацию и tooltip-диапазоны вместо преждевременной очистки.
- Проверены три варианта доставки синтетических клавиш в AutoPair-тестах:
  прямой `keyDown`, `interpretKeyEvents` и `window.sendEvent`; все сохраняют
  проблему стенда, поэтому тестовые ожидания и production fallback не
  ослаблялись.
- Повторно проверены шесть ранее успешных классов после текущего состояния
  редактора: 132/132; ошибок и пропусков нет.
- Устранено предупреждение Swift в `MarkdownPresentationParser.swift:3013`:
  trailing closure передан явно; повторная Develop/Debug-сборка — 0 ошибок,
  0 предупреждений.
- Повтор `MarkdownAutoPairTests`: 5/7; 2 падения, 0 пропусков. Полный единый
  прогон остановлен после превышения 30 секунд и не засчитан как результат.
- Дополнительная проверка тестового стенда с активацией `NSApplication` и
  прокруткой `RunLoop` перед синтетическими событиями не изменила результат:
  оба GUI-теста по-прежнему 0/2. Изменение стенда удалено.
- Проверен прямой вызов `LacTextView.keyDown(with:)` в тестовом helper вместо
  `window.sendEvent`: первая пара начинает работать, но ломается группировка
  undo и последующие сценарии (падение остаётся). Helper возвращён к исходному
  `window.sendEvent`.
- В Xcode создан target `LacEditorUITests` (`bundle.ui-testing`). Шаблонные UI-
  тесты проходили 2/2; новый сценарий автопара пока не завершён — UI-тест не
  находит пункт меню создания окна и требует стабилизации локализации/структуры
  меню.
- После точечной миграции `MarkdownAutoPairTests` содержит 5/5 стабильных
  unit-проверок сервиса. Два проблемных сценария реальной доставки клавиш
  проходят в `LacEditorUITests` через `XCUIApplication`/`typeText` (2/2); в UI-
  target проверяется именно доставка ввода, а пары и undo остаются в unit-слое.
- `MarkdownCodeHighlightServiceTests`: после узкого Swift fallback для пустого
  результата Tree-sitter проходят 8/8; Debug-сборка и проверка предупреждений
  проходят (0 ошибок, 0 предупреждений).
- `VaultClientTests.testIDsAreEncodedAsOnePathComponent`: исправлено ожидание
  теста на `URL.absoluteString`; `URL.path` декодирует `%2F`, production-код
  оставлен без двойного кодирования. Targeted-тест проходит.
- Повторные Debug targeted-прогоны `VaultClientTests` (22/22) и
  `MarkdownEmailSourceTests` (6/6) проходят. Их прежние failures из общего
  прогона не воспроизводятся отдельно и требуют дальнейшей проверки изоляции
  общего запуска.
- `MathJaxRenderServiceTests.testMathMLUsesResolvedDocumentMacro` теперь
  проходит 1/1. Исправлено ожидание теста: MathJax корректно сериализует
  Unicode-символ `中` как XML entity `&#x4E2D;`.
- Изолированный Debug-прогон `MarkdownBacklinksServiceTests`,
  `MarkdownBacklinksControllerTests`, `SemanticFontTests` и
  `MarkdownEmailSourceTests` проходит 18/18. `MarkdownTableShortcutTests`
  остаётся с одним воспроизводимым падением `testRowShortcutsUseActiveCellAndUndo`;
  изменения тестового оконного стенда откатаны, так как не устранили причину.
