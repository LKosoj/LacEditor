# Режим хранилища a-second-brain

Читать при изменении подключения к серверу a-second-brain, локальной копии заметок, отправки и объединения правок, страниц `compiled/`, боковой и правой панелей хранилища, поиска, «Записать мысль…» и «Спросить». Подробности интерфейса, сессии, восстановления и тестов уже записаны в других файлах; здесь только то, что относится к режиму целиком, со ссылками.

## Границы режима

- Приложение работает только с заметками, которые открыты пользователем: без полной копии хранилища, без создания, удаления, переименования и переноса файлов на сервере, без доступа к `attachments/`, `templates/`, `bases/`. Одно активное хранилище на приложение (`WindowManager.activeVaultSession`); писательский и хранилищный режимы в одной вкладке взаимоисключающие (см. `windows-and-sessions.md`).
- Текст хранилища всегда UTF-8. Сервер — источник истины; ответы сервера (включая ответы на «Спросить») — данные, а не команды.
- Сервер a-second-brain (`/srv/git_projects/a-second-brain`) изменять из этого проекта нельзя.

## Подключение и туннель

- Список подключений — `Application Support/<dataDirectoryName>/VaultConnections.json` (`VaultConnectionStore`); токен — только в Связке ключей (service `<dataDirectoryName>.Vault`, account — id подключения), не синхронизируется через iCloud и не пишется в журнал, сессию и JSON. Повреждённый файл переносится рядом как `.corrupt` (затем `.corrupt-2`…), файл новее известной версии не трогается.
- Адрес: `https` — любой хост, `http` — только loopback (`VaultConnection.swift`). Клиент `VaultClient` не следует за редиректами (`VaultRedirectBlocker`), таймауты 15 с (обычные запросы, `/healthz`) и 60 с (файл, задание).
- Туннель — `/usr/bin/ssh` (`VaultTunnel`): аргументы передаются массивом без оболочки; хост и пользователь не начинаются с «-», порты 1–65535; порт 22 не передаётся (чтобы не затирать `~/.ssh/config`); туннель слушает только `127.0.0.1` (при занятом порте берётся другой, до 3 раз), новый запуск ждёт выхода прежнего `ssh`; пароль ssh не спрашивается, ключ ищется по `~/.ssh/config`, агенту или полю «Ключ».
- Лист «Подключение хранилища», меню и раздел настроек «笔记库» — в `ui.md`; тексты — в `localization.md` (блоки `Режим хранилища: этап N`).

## Локальная папка и движок синхронизации

- `Application Support/<dataDirectoryName>/Vaults/<id>/`: `open/` (открытые заметки), `open-state/<sha256>.base` (серверная основа для объединения), `state.json` (записи), `requests.json` (запросы этапа 7), `.metadata_never_index`. Правило «только открытые файлы»: заметка, которую закрыли или которой нет в записях, из `open/` и `open-state/` убирается; остальное в папке не трогается. Файлы не попадают в «Недавние» и библиотеку (`folders-and-library.md`).
- `VaultSyncEngine` (+`NoteInfo`, +`Upload`) пишет в порядке файл, затем основа, затем запись состояния; удаляет только через `removeItem`. Уборка после аварии (`cleanupAfterCrash`), карантин повреждённого `state.json`, сохранение несохранённого текста в снимок и закрытие заметки — в `files-and-recovery.md`; поколения и `epoch` против поздних результатов — в `text-state-and-background.md`.
- «Нет связи» — две подряд сетевые ошибки; проверка `/healthz` с паузами от 5 до 60 с. Обход каталога считается полным только по критерию движка. Состояние `VaultStatus` и значок «Нужно внимание» — чистая модель.
- Пути проходят `VaultPath.validated` до любой записи; проверка строже сервера. Список `VaultServerRules.isServerManaged` и `systemFrontmatterFields` определяет «Обновляется сервером» и поля, которые панель не правит.

## Отправка, объединение, конфликты

- Подробные правила (порядок «файл, база, `PUT` с `If-Match`», «409 своей записи», сверка по SHA-256, `uploadIssue`, вопросы при закрытии и выходе, лист конфликта) — в `files-and-recovery.md` и `ui.md`.
- Объединение — `VaultMerge`: чистая функция, строки сравниваются по байтам и делятся только по `\n`, окончания и BOM берутся как у «моей» версии, соседние изменения — конфликт (как diff3), дописывание в конец обрабатывается отдельно; на больших размерах возвращается один «кусок-весь файл», вызывать вне главного потока. «Оставить мою/сервера версию целиком» берёт исходные тексты, а не `resolved`.
- Открытая вкладка меняется только отменяемой заменой через `VaultUploadHost`; сводки «Неотправленное»/«Конфликты» строит `VaultUnsentSummary`, выбор в листе конфликта — `VaultConflictSelection`.

## Страницы `compiled/` и отчёты сервера

- Страницы `compiled/` собирает сервер; править можно только раздел «Owner Notes» между метками `<!-- human:start -->` и `<!-- human:end -->`. `summaries/` и `MOC/compiled-index.md` — только чтение; страница с повреждёнными метками или без раздела — тоже только чтение (`VaultPageMode`).
- Запрет единый: `VaultPageGuard.decide` вызывается первой строкой `shouldChangeTextIn` и в пути Shift-Tab (`vaultEditGate`); метку нельзя вставить, стереть или разорвать; единицы измерения — UTF-16. Единственная правка вне раздела — серверное обновление (`isVaultServerUpdate`), оно не попадает в историю отмены. Подробности, приглушение вне раздела, плашка — в `editing.md`, `markdown-editor.md`, `ui.md`, производительность проверки — в `performance.md`.
- Правка шапки из панели не касается собранных страниц (`VaultFrontmatterEditor` — только заплатка строки поля, остальное байт в байт).

## Правая панель и ссылки

- Сегменты «Заметка», «Связи», «Спросить» и AI, форма свойств, «Показать изменения сервера» — в `ui.md` и `markdown-editor.md`. Ссылки — wiki-ссылки с путём, без обратных ссылок и без псевдонимов (`VaultLinks`, `VaultNoteInfo`).
- Выноски `> [!тип]`, комментарии `%%…%%` и встраивание `![[заметка]]` — общий разбор Markdown (`export-and-preview.md`, `markdown-editor.md`). Для хранилища отдельного провайдера нет: `renderPage` при наличии `wiki` берёт `MarkdownFolderNoteEmbedProvider`, который читает файлы из локальной копии открытых заметок (`VaultStateStore.openDirectory`), без сети; заметки нет среди открытых — «Заметка не найдена»; `![[картинка]]` — «Вложение недоступно». Комментарии `%%…%%` скрываются только в заметках хранилища (адрес документа внутри `Application Support/<приложение>/Vaults/`, `MarkdownObsidianComment.appliesTo`): в предпросмотре, HTML, PDF, Pandoc, PDF-движке пользователя и во встраиваниях, в редакторе приглушаются; в обычных документах `%%` остаётся текстом.

## Поиск

- В боковой панели хранилища свой поиск: «На сервере» и «Имена» (`VaultSearchController`, `VaultSearchSupport`, `VaultSnippetLocator`); быстрое открытие ⌘⇧O во вкладке хранилища — `VaultQuickOpenPanel` по каталогу. Правила и клавиши — в `folders-and-library.md` и `ui.md`. `FolderSearch*` в хранилище не используется.

## Записать мысль и «Спросить»

- `VaultRequestsClient` пишет запрос в `Vaults/<id>/requests.json` (права `0600`) до отправки; повтор идёт с тем же `request_id`, паузы 2→30 с; прерванное (`interrupted`) автоматически не повторяется, потерянное задание (`jobLost`) не повторяется. `kind` — только локальная метка, сервер тип не получает.
- Черновик «Записать мысль…» — `VaultCaptureDraft.txt` в каталоге данных (вне `Vaults/<id>/`). Артефакты ответа открываются несохранённой вкладкой и на диск не пишутся. `VaultAskModel` держит до 20 ответов текущего запуска только в памяти. Интерфейс — в `ui.md`.

## Ключевые файлы

- Модели (`LacEditor/Models`): `VaultConnection`, `VaultPath`, `VaultMerge`, `VaultOwnerZone`, `VaultPageGuard`, `VaultStatus`, `VaultUploadModels`, `VaultConflictSelection`, `VaultUnsentSummary`, `VaultRequests`, `VaultFrontmatterEditor`, `VaultLinks`, `VaultNoteInfo`, `VaultSearchSupport`, `VaultSnippetLocator`.
- Сервисы (`LacEditor/Services`): `VaultClient`, `VaultTunnel`, `VaultConnectionStore`, `VaultStateStore`, `VaultCatalog`, `VaultSyncEngine*`, `VaultSession`, `VaultRequestsClient`, `VaultRequestsHub`, `VaultCaptureController`, `VaultCaptureDraftStore`, `VaultAskModel`, `VaultInspectorModel`, `VaultSearchController`, `MarkdownFolderNoteEmbedProvider`.
- Приложение и интерфейс: `AppState+Vault*.swift`, `WindowManager+Vault*.swift`, `EditorTextView+VaultPage.swift`, `Views/Vault*.swift`.
- Тесты и стенд: `Vault*Tests`, `Markdown{Callout,ObsidianComment,NoteEmbed}Tests` (`testing.md`); чистые модули подключены в `/home/claude-bot/tools/lac-writer-check`.

## Сборка

- Новые файлы режима внесены в цель приложения `LacEditor.xcodeproj`; `EditorDocument.swift` зависит от `VaultPageGuard`, поэтому в списки `swiftc` в `Scripts/verify-release.sh` и `Scripts/run-acceptance.sh`, где есть `EditorDocument.swift`, входят также `VaultPath.swift`, `VaultOwnerZone.swift` и `VaultPageGuard.swift`. Тесты — только через Swift Package Manager.
