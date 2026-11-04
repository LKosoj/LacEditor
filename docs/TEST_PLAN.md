# План доведения тестов до чистого прогона

## Цель

Добиться полного прохода тестов LacEditor в конфигурации Develop/Debug на
macOS: 0 ошибок, 0 предупреждений, 0 пропусков GUI-тестов.

## Правила

1. Перед изменениями проверять `git status` и сохранять чужие изменения.
2. Собирать через Xcode `BuildProject(buildForTesting: true)`.
3. После сборки проверять `GetBuildLog(severity: warning)`.
4. Запускать тесты небольшими пачками; если пачка длится более 30 секунд,
   считать её зависшей и делить на меньшие наборы.
5. GUI-тесты на macOS не пропускать. Исправлять production-код, тестовый
   стенд или ошибочное ожидание — по причине конкретного падения.
6. После каждого исправления запускать затронутый класс и фиксировать результат
   в `docs/TEST_STATUS.md`.
7. Не использовать Production-сборку для проверки тестов и не изменять
   production-окружение.
8. Перед завершением выполнить `git diff --check`, чистую сборку и итоговый
   прогон всех тестов.

## Рабочие этапы

1. Закрыть оставшиеся падения `MarkdownAutoPairTests`.
   Проверить путь `NSEvent → LacTextView.keyDown → insertText →
   MarkdownAutoPairService`; отдельно проверить тестовый оконный стенд и
   первого ответчика.
2. Повторно запустить `MarkdownFootnoteTests`, `ManuscriptServiceTests` и
   `MarkdownElementPathTests` после изменений контроллера.
3. Повторить ранее успешные классы небольшими пачками.
4. Запустить полный набор тестов, деля его на пачки менее 30 секунд.
5. Проверить предупреждения сборки и `git diff --check`.
6. Обновить `docs/TEST_STATUS.md` итоговыми цифрами и оставшимися ограничениями.

## Чек-лист выполнения

- [x] Зафиксировать правила и статус в Markdown-файлах.
- [x] Добиться чистой Develop/Debug-сборки.
- [x] Исправить fast-path ревизии и закрыть `MarkdownFootnoteTests`.
- [x] Закрыть `ManuscriptServiceTests`.
- [x] Закрыть `MarkdownElementPathTests`.
- [ ] Исправить два падения `MarkdownAutoPairTests` через корректный оконный
  тестовый стенд, без production fallback и без `skip`.
- [x] Запустить ранее успешные классы короткими пачками (132/132).
- [ ] Запустить полный набор тестов пачками до 30 секунд.
- [ ] Проверить 0 предупреждений и выполнить `git diff --check`.
- [ ] Обновить итоговый статус и отметить цель выполненной.

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
- `MarkdownAutoPairTests`: 5/7, два GUI-теста ещё падают.
- Develop/Debug build: 0 ошибок, 0 предупреждений.
- Повторная пачка успешных классов: 132/132.
