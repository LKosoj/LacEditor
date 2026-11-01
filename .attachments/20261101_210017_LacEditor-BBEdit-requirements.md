# LacEditor: требования к полезным доработкам по мотивам BBEdit

**Статус:** предложение к планированию, не описание уже реализованного функционала  
**Дата аудита:** 1 ноября 2026 года  
**Проект:** [`LKosoj/LacEditor`](https://github.com/LKosoj/LacEditor)  
**Проверенный commit:** `ee882e3520d6d617637244da0d95020eb69e0442`  
**Источник возможностей:** предоставленный `BBEdit User Manual.pdf`, BBEdit 14.6.3, 440 страниц

## 1. Краткий вывод

LacEditor не стоит превращать в полный клон BBEdit. Наибольшую практическую пользу дадут функции, которые усиливают уже существующий локальный редактор и не требуют облака, Git или AI:

1. явный выбор области поиска и безопасные повторяемые поисковые рецепты;
2. извлечение результатов поиска в новый документ;
3. безопасный откат пакетной замены закрытых файлов;
4. split-view, column selection, markers и локальная навигация по символам;
5. EditorConfig, независимое сравнение двух буферов и Tail Mode;
6. небольшой CLI-helper, локальные text filters и сохранённые коллекции файлов.

Уже существующие функции не предлагаются повторно: обычный поиск/замена с regex, поиск по папке, предпросмотр массовой замены, кодировки и окончания строк, системные версии, Markdown outline, command palette, рабочая папка, шаблоны, wiki-ссылки, обратные ссылки, теги, сборка рукописи, восстановление сессии и экспорт.

## 2. Как читать документ

- **P1** — полезная ближайшая доработка; **P2** — следующая очередь; **P3** — только после стабилизации базовых механизмов.
- `partial` означает: часть механизма уже есть, но пользовательский сценарий BBEdit не покрыт.
- `not_found` означает: в статически просмотренном коде аналог не найден. Runtime и GUI-проверка не выполнялись.
- Формулировки **«система должна»** — требования к будущей реализации, а не утверждение о текущем поведении.

## 3. Требования к доработкам

### R-01. Явные области поиска и наборы источников — P1

**Пользовательская ценность.** Один и тот же поиск можно повторить по текущему документу, выделению, всем открытым документам или выбранным файлам/папкам, не опасаясь случайно заменить лишнее.

**Текущее состояние LacEditor.** Поиск текущего документа и папки уже есть; `TextSearchService` поддерживает plain/regex/whole-word, а `FolderReplaceService` строит preview. Но Replace All для текущего документа работает с полным snapshot, а набор «все открытые документы», включая несохранённые, не оформлен как пользовательская область.

**Требования.**
- Предлагать области: текущий документ, зафиксированное выделение, все открытые документы, выбранные файлы и папки.
- Для выделения хранить исходный UTF-16 range и revision; переход по совпадениям не должен сужать исходную область.
- «Все открытые» должно включать untitled/несохранённые документы и объединять одинаковую file identity. Разные snapshots одного файла должны давать конфликт, а не произвольный выбор.
- Перед заменой показывать область, число совпадений и число документов. Изменение состава или revision после preview инвалидирует план.
- Сохранённый набор источников хранить локально; недоступный путь показывать как проблему, не подменяя его другой папкой.

**Критерии приёмки.** В `cat | cat | cat` выбор среднего фрагмента изменяет только его; несохранённая вкладка участвует в «всех открытых» без чтения диска; emoji до совпадения не ломает range; устаревший preview не записывает файлы.

**Основание:** BBEdit PDF pp. 163, 170, 173; код LacEditor: `TextSearchService.swift`, `FolderReplaceService.swift`, `WindowManager.swift`.

### R-02. Пользовательские фильтры и сохраняемые поисковые рецепты — P1

**Пользовательская ценность.** Повторяемые операции вроде «все Markdown в notes, кроме archive» не требуют каждый раз вручную выбирать файлы.

**Требования.**
- Фильтровать по имени, расширению и относительному пути; поддержать AND/OR и include/exclude.
- Применять фильтр до чтения содержимого; исключение каталога должно исключать всё поддерево и не обходить symlink/hidden-file policy.
- Для известного расширения показывать язык из `EditorLanguage`; неизвестный язык не угадывать.
- Рецепт хранит версию схемы, query/replacement, case/regex/whole-word/escape options, scope и фильтры.
- Загрузка рецепта только заполняет форму; новый preview и подтверждение обязательны перед заменой. Невалидный JSON/regex не запускает операцию.

**Критерии приёмки.** `AND(extension=md, path contains notes)` не читает JSON/PNG; `OR(md,json)` включает оба типа; `exclude node_modules` исключает поддерево; повреждённый рецепт не удаляет исправные рецепты.

**Основание:** BBEdit PDF pp. 174–176; существующая точка расширения — `FolderSearchService.include(File)`.

### R-03. Regex playground с live-проверкой и preview replacement — P2

**Пользовательская ценность.** Сложное регулярное выражение можно проверить на небольшом тексте до запуска по папке.

**Требования.**
- Дать scratch-текст и read-only snapshot выбранного документа; playground не меняет исходник.
- Проверять regex отложенно через существующий `NSRegularExpression`, показывать ошибку рядом с полем.
- Для выбранного совпадения показывать full match, numbered/named captures и результат replacement. Optional unmatched group отличать от пустой строки.
- Справка должна описывать именно поддерживаемый ICU engine и `$1/$2`; не обещать совместимость с BBEdit/PCRE расширениями.
- «Использовать в поиске» переносит настройки без выполнения замены.
- Ограничить размер scratch и обеспечить отмену/защиту от устаревшего preview; возможность прерывать один патологический match должна быть отдельно проверена на macOS.

**Критерии приёмки.** `'(\\w+)@(\\w+)'` с `$2:$1` даёт ожидаемый preview; `(` блокирует применение; zero-length policy совпадает с основным поиском; emoji сохраняет точные ranges.

**Основание:** BBEdit PDF pp. 219–221; LacEditor `TextSearchService.swift`, `FolderReplaceService.swift`.

### R-04. Извлечение совпадений в новый документ — P1

**Пользовательская ценность.** Результаты поиска можно превратить в список ID, адресов, строк или преобразованных значений без ручного копирования.

**Требования.**
- Создавать новую несохранённую вкладку; источники и clipboard не менять.
- Режимы: exact match, replacement template с captures, целая строка, строки без совпадения.
- В whole-line режиме строку с несколькими совпадениями выдавать один раз.
- Сохранять порядок источников; опционально добавлять `path:line` и offsets. Разделитель результата задаётся явно.
- Использовать тот же evaluator, что и основной поиск, включая regex, data:-исключения и UTF-16 ranges.
- Ошибка чтения/отмена создаёт только явно помеченный partial result; zero matches не оставляет старый результат.

**Критерии приёмки.** Для `_TAG_(.+?)\s` exact выдаёт match, template `$1` — `NAME`, whole-line — исходную строку; два совпадения в одной строке дают два exact и одну whole-line запись.

**Основание:** BBEdit PDF pp. 139, 156, 181; LacEditor `FolderSearchService` и команды поиска.

### R-05. Безопасная пакетная замена и восстановление — P1

**Пользовательская ценность.** Atomic write защищает отдельный файл, но не позволяет понять и откатить частично выполненную замену по папке.

**Текущее состояние.** `FolderReplaceService` повторно проверяет revision и пишет закрытый UTF-8-файл атомарно; обычный Undo закрытые файлы не возвращает.

**Требования.**
- До первой записи сформировать manifest с before fingerprint/bytes, списком правок и политикой хранения.
- Перед каждой записью повторно проверять snapshot; изменившийся файл пропускать с причиной.
- Вести журнал `planned/completed/skipped/failed`, включая cancel/crash и частичный успех.
- Дать явную команду Restore Batch. Она проверяет, что файл всё ещё соответствует результату операции; внешние последующие изменения автоматически не затираются.
- Ошибка создания recovery-снимка до записи должна блокировать запись соответствующего файла.
- Сохранить существующие ограничения BOM/non-UTF8/symlink.

**Критерии приёмки.** После замены A и внешнего изменения B восстановление возвращает before bytes только A, а B помечает conflict; cancel между файлами показывает выполненные и нетронутые; crash после записи восстанавливается по fingerprints.

**Основание:** BBEdit PDF p. 178 (без утверждения о наличии в BBEdit автоматического batch backup); LacEditor `FolderReplaceService.swift`, `FileService.swift`.

### R-06. Независимые split-view одного документа — P1

**Требования.**
- Разделять один `NSTextStorage` минимум вертикально на два представления.
- Дать независимые scroll offset, caret и selection при общем тексте, dirty/revision и undo.
- Изменение в одном view сразу видно в другом и создаёт один undo.
- Безопасно закрывать split, не оставляя observers и не теряя viewport/selection.
- Учесть Markdown source/display coordinates, folded/media ranges и IME: marked text принадлежит только focused view.

**Критерии приёмки.** Верхний и нижний view сохраняют независимую прокрутку после вставки; одна отмена отменяет вставку; IME/emoji не сбрасывает состояние второго view; reading mode нельзя обойти через второй view.

**Основание:** BBEdit PDF pp. 94–95; текущий `EditorTextView.swift` создаёт один scroll/text view на сессию.

### R-07. Прямоугольное (column) выделение — P1

**Требования.**
- Представлять column selection как набор диапазонов строк с anchor/focus visual columns, а не как произвольный multi-cursor.
- Поддержать Option-drag и расширение вверх/вниз; учитывать tab width и soft wrap.
- Copy/cut/paste и line operations выполнять одной undo-группой.
- Явно определить короткие строки, padding, CRLF, emoji и surrogate pairs.
- Завершать режим на marked text, table-cell editor, reading mode и media-token boundary.

**Критерии приёмки.** Один и тот же прямоугольник даёт одинаковый результат для ASCII, CJK, tabs и emoji; soft wrap не создаёт ложную колонку; обычный multi-selection не появляется.

**Основание:** BBEdit PDF pp. 105–108; в LacEditor текущие edit paths ориентированы на один `selectedRange` (`LacTextView.swift`).

### R-08. Named markers и история переходов — P1

**Требования.**
- Хранить именованные markers как revision-aware ranges, отдельно от Markdown outline/folds.
- Дать Set/Clear/Clear All, список, фильтр и переход с восстановлением viewport/selection.
- Реализовать Jump Back/Forward с bounded history и устранением соседних дублей.
- После edit/undo/external reload range должен переводиться или помечаться stale; нельзя прыгать в неверный UTF-16 offset.
- Поведение восстановления markers после перезапуска описать явно: либо не восстанавливать, либо проверять URL+revision.

**Критерии приёмки.** Marker после вставки перед ним остаётся на прежнем тексте; удалённый диапазон виден как stale; Jump Back возвращает selection и viewport; Clear All не трогает outline.

**Основание:** BBEdit PDF pp. 90, 126–128, 186–187; отдельного marker API в проверенном коде не найдено.

### R-09. Локальный outline по символам — P1

**Требования.**
- Создать `SymbolIndex` поверх tree-sitter tree, не извлекая символы из подсветочных tokens.
- Минимум поддержать declarations/functions/types для JavaScript/TypeScript, Python, Swift, C-family, HTML и Markdown headings.
- Показать outline, фильтр, текущий символ и переход к точному range.
- Индексировать асинхронно с cancellation и revision/document guards; не блокировать набор текста.
- Для неподдержанного языка показывать пустой/ограниченный результат, не выдумывать symbols. LSP declaration/definition/rename в это требование не включать.

**Критерии приёмки.** Fixture с emoji/CJK до функции даёт корректный UTF-16 range; новый revision отменяет старый индекс; файл свыше лимита использует документированный fallback.

**Основание:** BBEdit PDF pp. 89–90, 186–187, 367–368; LacEditor `SyntaxParser.swift` содержит syntax tokens/tree-sitter backend, но не symbol index.

### R-10. Offline clippings/snippets с placeholders — P1

**Требования.**
- Добавить локальный JSON/text store: folders, title, trigger, body, shortcut и language applicability.
- Поддержать selected-text placeholder, named tabstops, date/time и final caret; вставка — одна undo-транзакция.
- Дать palette search, completion и create-from-selection; не запускать скрипты в первой версии.
- Дать import/export, duplicate/delete и безопасное восстановление после повреждения store.
- Не перехватывать Tab/Esc/IME/table actions без явного контекста.

**Критерии приёмки.** Выделение подставляется один раз, Tab проходит два placeholders, timezone/locale указаны в тесте, duplicate trigger не теряет старый clipping, stale revision отменяет вставку.

**Основание:** BBEdit PDF pp. 111–112, 317–329; LacEditor `NoteTemplateService.swift` покрывает создание заметки с `title/date/time`, но не каталог вставляемых snippets.

### R-11. Show Invisibles и Unicode inspector — P2

**Требования.**
- Ввести временный display layer для tab, spaces, NBSP, line endings и control characters без изменения source/dirty/undo.
- Не рисовать markers внутри media tokens, marked text и экспортируемого/печатного вывода.
- Inspector должен показывать code point(s), grapheme, UTF-16 range, normalization и escaped representation.
- Отдельно обработать CR/LF/CRLF, U+2028/U+2029, combining marks и astral emoji.

**Критерии приёмки.** Включение/выключение меняет только layout attributes; CRLF показан как один перенос; inspector верно сообщает `U+1F...` и UTF-16 range; копирование остаётся исходным.

**Основание:** BBEdit PDF pp. 115, 261–262; текущий `EditorTextView.swift` отключает автоматические подстановки, но toggle invisibles/inspector не найден.

### R-12. Стабильные command IDs и пользовательские shortcuts — P2

**Требования.**
- Заменить зависимость pinned/recent от локализованного menu path на immutable command IDs с миграцией.
- Дать настройки переназначения, конфликтов, сброса и сохранения shortcut.
- Palette и меню должны показывать один и тот же shortcut и не становиться второй системой команд.
- Настройки языка должны иметь глобальный fallback; unknown/deprecated IDs не должны запускать другой command.

**Критерии приёмки.** Смена языка и перестановка меню не теряют pin/shortcut; конфликт нельзя сохранить молча; Esc/Tab/IME-priority keys не перехватываются.

**Основание:** BBEdit PDF pp. 111, 243, 250–254; LacEditor `CommandPaletteService.swift` хранит index paths/localized titles.

### R-13. EditorConfig и безопасная политика сохранения — P1

**Требования.**
- Читать `.editorconfig` от каталога файла до root/home boundary; поддержать `root`, charset, indent_style, indent_size, tab_width, insert_final_newline, trim_trailing_whitespace и glob sections.
- Показывать effective settings и разрешать явный document/language override.
- Не удалять Markdown hard-break spaces без явно применимого правила; сохранять CR/LF/CRLF и legacy encoding без неявной нормализации.
- Перед save проверять представимость, atomic write и внешнюю revision.

**Критерии приёмки.** Ближайшая секция побеждает общую, `root=true` останавливает поиск, malformed key даёт notice; два пробела перед LF в Markdown сохраняются; внешнее изменение приводит к выбору, не к silent overwrite.

**Основание:** BBEdit PDF pp. 53–54; LacEditor `AppPreferences.swift`, `FileService.swift` уже имеют глобальные indentation/whitespace settings и atomic write.

### R-14. Немодельное сравнение произвольных буферов/файлов — P1

**Требования.**
- Принимать два URL, два unsaved buffer или смешанную пару; явно показывать identity и unsaved status.
- Показывать line hunks с настройками case, blank lines и whitespace.
- Применять выбранный hunk в одну сторону только после base snapshot check; stale source блокирует apply.
- Реализовать это как deterministic diff, не как AI-функцию и не как сетевой запрос.

**Критерии приёмки.** Два unsaved buffer сравниваются без временных файлов; identical texts показывают no differences; whitespace-only changes управляются настройкой; CRLF, duplicate lines и combining text не ломают line numbers.

**Основание:** BBEdit PDF pp. 122–124; LacEditor имеет `VersionHistoryController` и `AITextComparison`, но не отдельный произвольный non-AI diff workflow.

### R-15. Tail Mode для локальных логов — P1

**Требования.**
- Открывать локальный файл read-only и читать только дописанный byte range с корректной обработкой частичного UTF-8.
- При truncate/rotation/replacement по file identity сбрасывать offset или переходить к новому inode с notice.
- Автопрокрутка действует только если пользователь уже находится у конца; ручная прокрутка сохраняется.
- Дать pause/stop/refresh, ограничить память и частоту событий; не поддерживать directory, symlink replacement и удалённый URL.

**Критерии приёмки.** Несколько chunks и split UTF-8 отображаются без replacement characters; log rotation не дублирует хвост; Save/edit disabled только в Tail Mode; удаление файла безопасно останавливает watcher.

**Основание:** BBEdit PDF p. 80; в LacEditor есть наблюдение изменений рабочей папки, но отдельный offset-based tail reader не найден.

### R-16. CLI helper: stdin, line/column и wait — P1

**Требования.**
- Поддержать paths, `--line`, `--column`, `--wait` и `-`; относительные paths разрешать относительно cwd.
- При stdin создавать bounded UTF-8 untitled buffer; EOF не должен зависать, binary/oversize input — завершаться ошибкой.
- `--wait` возвращается после закрытия конкретного документа или явного completion event; timeout/app-unavailable имеют ненулевой status.
- Установку helper отделить от Launch Services; development/acceptance builds не должны самопроизвольно становиться default handler.

**Критерии приёмки.** `echo text | lacedit -` создаёт unsaved document; line/column попадает в правильный UTF-16 offset; `--wait` ждёт именно нужный документ и не создаёт duplicate window.

**Основание:** BBEdit PDF pp. 71–72, 371–373; LacEditor `WindowManager.openFilesFromCommandLine`, `LacEditorApp.swift`.

### R-17. Безопасные локальные text filters — P2

**Требования.**
- Передавать selected text или весь документ в UTF-8 stdin и заменять только после exit code 0.
- stderr показывать отдельно, stdout для диагностических команд не смешивать с результатом.
- Дать process group, cancel, timeout/resource bounds и revision check перед применением.
- Показывать command/cwd/environment и trust warning; не выполнять автоматически обнаруженные plugin packages.

**Критерии приёмки.** Non-zero exit оставляет текст неизменным; empty stdout считается допустимой заменой только по явной политике; cancel убивает descendants; late output не применяется к новой revision.

**Основание:** BBEdit PDF pp. 378–380; в LacEditor безопасные аргументы и отмена уже частично реализованы в `CustomMarkdownExportService.swift`, но общего text-filter API нет.

### R-18. Небольшие локальные коллекции рабочего набора — P2

**Требования.**
- Хранить именованную коллекцию ссылок на files/folders с порядком и необязательными группами, без копирования содержимого.
- Открывать элементы через существующие file identity/root checks.
- Missing/moved entry показывать явно; Reveal/Remove/Relink не должны молча создавать или перезаписывать файл.
- Коллекция локальная и offline, без Git/cloud sync и полного content index.

**Критерии приёмки.** После перезапуска сохраняются порядок и группы; duplicate identity явно устраняется или помечается; пропавший файл не исчезает из списка; большая коллекция загружает metadata без чтения всех тел.

**Основание:** BBEdit PDF pp. 73–77; `FolderWorkspaceStore` и session/workspace в LacEditor уже дают часть похожей инфраструктуры, поэтому это не должен быть второй полноценный project model.

## 4. Что сознательно не переносить сейчас

- Полный клон BBEdit Projects: LacEditor уже имеет рабочую папку, библиотеку, сессию и отдельные писательские функции; нужен только лёгкий слой коллекций (R-18).
- LSP declaration/definition/rename: в проведённом аудите подтверждён только локальный tree-sitter/syntax слой, поэтому это отдельный проект.
- Git-интеграцию, облачную синхронизацию и plugin marketplace: они не соответствуют зафиксированному локальному направлению LacEditor.
- Автоматические backups/batch Undo BBEdit как якобы доказанную функцию: на проверенной странице 178 такой гарантии не найдено. R-05 — самостоятельное требование безопасности LacEditor, а не утверждение о BBEdit.
- Повторно реализовывать уже имеющиеся поиск/замену, folder replace preview, версии, кодировки, Markdown outline, command palette, templates, tags, wiki/backlinks и export.

## 5. Рекомендуемый порядок реализации

1. **P1-основа:** R-01, R-02, R-04, R-05, R-13, R-14.
2. **P1-редактор:** R-06, R-07, R-08, R-09, R-10, R-15, R-16.
3. **P2:** R-03, R-11, R-12, R-17, R-18.
4. После каждой группы — unit tests для ranges/revisions и macOS acceptance tests с IME, emoji, CRLF, внешним изменением файла, отменой и partial failure.

Порядок выбран так, чтобы сначала укрепить общие механизмы snapshot/revision/diff/recovery. Без них split-view, batch replace, extract и filters будут давать красивый интерфейс, но небезопасное поведение.

## 6. Ограничения исследования

- Выводы о LacEditor основаны на статическом чтении только указанного репозитория и commit `ee882e3520d6d617637244da0d95020eb69e0442`; исходники не менялись и не запускались.
- PDF извлечён и проверен по тематическим разделам, а не прочитан постранично как самостоятельная реализация BBEdit.
- Статус `not_found` означает «не найдено в просмотренном коде», а не математическое доказательство отсутствия во всём проекте.
- GUI, runtime, IME, performance и фактическая сборка LacEditor в рамках этого аудита не проверялись.

## 7. Реестр источников

- BBEdit User Manual 14.6.3: пользовательский PDF, 440 страниц; страницы указаны в каждом требовании.
- LacEditor remote: <https://github.com/LKosoj/LacEditor>.
- LacEditor pinned commit: `ee882e3520d6d617637244da0d95020eb69e0442`.
- Детальные статические аудиты: `evidence/search-audit.md`, `evidence/editor-audit.md`, `evidence/files-audit.md` в рабочем каталоге аудита.
