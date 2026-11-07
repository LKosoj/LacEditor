# Проверка на сервере Linux

На сервере разработки нет AppKit, SwiftUI, WebKit и NaturalLanguage, поэтому приложение целиком здесь не собирается и `RunAllTests` не запускается. Вместо этого есть синтаксическая проверка и два стенда — отдельные пакеты SwiftPM, где недоступные системные модули заменены почти пустыми заглушками. Стенды берут код проекта через символьные ссылки и ничего в проекте не меняют. Результат стенда — только предварительная проверка: окна, TextKit, ввод, IME, WebKit и скорость подтверждаются только на Mac.

## Компилятор

```sh
export PATH=/home/claude-bot/tools/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:$PATH
```

- Каждый изменённый `.swift` — минимум `swiftc -frontend -parse <файл>`.
- `-parse` не учитывает `#if`, поэтому файлы с `#if compiler(>=6.2)` (например, `EditorCoordinator.swift` с `isolated deinit`) проверять через `swiftc -typecheck -swift-version 5 <файл>`; ошибка `no such module 'AppKit'` ожидаема, других быть не должно.
- `swift build`/`swift test` самого проекта на Linux не работают (AppKit, `Vendor/TreeSitterYAML`); не чинить это и не добавлять Linux-цели в `Package.swift`.

## Стенд `lac-writer-check`: сборка и XCTest

Каталог `/home/claude-bot/tools/lac-writer-check`. Собирает библиотеку из части исходников `LacEditor/` и запускает часть тестов из `LacEditorTests/` (сервисы, модели, разбор и оформление Markdown, копирование, писательский режим, AI без сети).

Запуск (около 2–3 минут):

```sh
/home/claude-bot/tools/lac-writer-check/run-tests.sh [файл_полного_вывода]
```

Скрипт сам: пересоздаёт ссылки (`gen.py`), урезанные копии (`gen_extract.py`), копии тестов с заплатками (`gen_tests.py`) и корпусные тесты (`gen_corpus.py`), собирает пакет, запускает тесты и сверяет падения со списком `linux-only-failures.txt`. Итог в конце вывода:

- `Executed N tests, …` — сколько тестов прошло через XCTest;
- `Только из-за Linux:` — известные падения из-за Foundation на Linux или заглушек (причина записана в `linux-only-failures.txt`), это норма;
- `НАСТОЯЩИЕ ПАДЕНИЯ:` — всё остальное, их нужно разбирать; при ошибке сборки — `СБОРКА НЕ УДАЛАСЬ` и первые ошибки. Полный вывод — в переданном файле (по умолчанию `/tmp/claude-1000/test-out.txt`), подробности падения искать там по имени теста.
- На 07.11.2026 среди настоящих стабильно падают 5 тестов `MarkdownClipboardCopyTestsCorpus` с картинками: заглушка ImageIO не читает изображение. Это ограничение стенда, а не регрессия; любое другое падение — регрессия или ошибка теста.

Подключение файлов:

- новый исходник, нужный тестам, — строкой в `lib-files.txt` (путь от `LacEditor/`, например `Services/MarkdownImageEditingService.swift`);
- новый файл теста — строкой в `test-files.txt` (имя без `.swift`, например `MarkdownImageEditingTests`);
- если исходник тянет AppKit/WebKit, в стенд он не берётся целиком: нужное выносится урезанной копией (`extract_specs.py`, список `SPECS`), а не правкой проекта;
- тест, который на Linux не может работать (окно, `EditorTextView`, `NSPasteboard`, SwiftUI), вырезается в `gen_tests.py` (`SPECIAL`, `cuts`) с комментарием о причине; тест, падающий только из-за Linux Foundation, — строкой в `linux-only-failures.txt` с причиной. Ослаблять сам тест в проекте ради стенда нельзя.
- Вспомогательные скрипты при ошибках сборки: `build.sh` и `build-tests.sh` (выжимка ошибок по файлам), `whohas.sh` (в каком файле проекта объявлено недостающее имя), `corpus-prune.py` (по выводу сборки дописывает в `corpus-drop-*.txt` методы корпусных тестов, которые не собираются на Linux).

## Стенд `lac-check`: сверка разбора Markdown

Каталог `/home/claude-bot/tools/lac-check`, полная инструкция — `check-howto.md` там же. Сравнивает быстрые пути редактора (сдвиг оформления после правки, карта текста, локальный разбор) с полным разбором `MarkdownPresentationBuilder.parse` на корпусе документов со случайными правками.

```sh
cd /home/claude-bot/tools/lac-check && swift build && .build/debug/LacCheck | grep -E "^документов|расхождений"
LOCALCHECK=1 .build/debug/LacCheck | grep -i расхожден
```

Норма — «расхождений 0» (для `LOCALCHECK` — «расхождений 0, расхождений индекса 0»), код выхода 0. Обычный прогон занимает до 8 минут. Запускать при изменении ядра разбора, `MarkdownSourcePositions`, адаптера оформления, сдвига или локального разбора. Если в урезанные копии (`MarkdownHTMLMediaService`, `MarkdownImageUploadService`, `MarkdownNoteEmbed`, `MarkdownObsidianComment`) пришла новая зависимость от AppKit, пересоздать копию по `check-howto.md`.

## Параллельные запуски

Стенд собирается в своём `.build`, поэтому два одновременных запуска мешают друг другу. Если стенд могут запускать несколько агентов, оборачивать запуск в общую блокировку:

```sh
flock /tmp/claude-1000/lwc.lock /home/claude-bot/tools/lac-writer-check/run-tests.sh /tmp/claude-1000/out.txt
flock /tmp/claude-1000/lc.lock bash -c 'cd /home/claude-bot/tools/lac-check && swift build && .build/debug/LacCheck'
```

## Что записывать

В `docs/TEST_STATUS.md` указывать, какие стенды запускались, число тестов и итог («настоящих падений нет, кроме …»), а для новых и изменённых тестов — что на Mac они ещё не запускались.
