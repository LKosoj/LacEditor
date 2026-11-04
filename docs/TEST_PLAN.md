# План доведения тестов до чистого прогона

## Цель

Добиться полного прохода тестов LacEditor в конфигурации Develop/Debug на
macOS: 0 ошибок, 0 предупреждений, 0 пропусков GUI-тестов.

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
- [ ] Установить причины всех `not run` и `skipped`, устранить их или явно
  обосновать в статусе; не оставлять необъяснимых пропусков.
- [x] Проверить 0 предупреждений и выполнить `git diff --check`.
- [ ] Обновить итоговый статус и отметить цель выполненной после общего прогона.

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
- [x] Итог: настоящих падений нет; остаются только падения из-за Linux
  (`linux-only-failures.txt`: ImageIO, FSEvents, `NLTokenizer`, CRLF).

Осталось:

- [ ] Собрать на Mac и прогнать изменённые классы, прежде всего
  `MarkdownPresentationParserTests`, `MarkdownEmojiCandidate*`,
  `MarkdownHTMLMedia*`, `SyntaxParser`/Tree-sitter, `FolderSearchView`.
- [ ] Проверить на Mac тесты, которые на Linux не запускаются: AppKit/AppState,
  JavaScriptCore, Keychain, `FocusSentenceTests` (`.bySentences`) и тесты из
  `linux-only-failures.txt`.
- [ ] Затем выполнить общий итоговый прогон из чек-листа выше.

## Текущее состояние (Mac)

- `MarkdownElementPathTests`: 22/22.
- `MarkdownFootnoteTests`: 9/9.
- `ManuscriptServiceTests`: 17/17.
- `MarkdownAutoPairTests`: 5/5 unit-тестов проходят; 2 проблемных сценария
  реальной доставки ввода проходят в `LacEditorUITests` (2/2).
- Develop/Debug build: 0 ошибок, 0 предупреждений.
- Повторная пачка успешных классов: 132/132.
