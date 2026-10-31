# Тесты и проверка результата

Читать перед завершением любой задачи с изменением кода: здесь выбор проверок по затронутой области.

- Для исправления ошибки добавить или обновить тест, воспроизводящий её. Для нового поведения проверить основные сценарии и затронутые границы. Для чисто текстовых правок достаточно подходящих проверок текста, ссылок и ресурсов.
- Не ослаблять проверки ради успешного результата. Ожидания пользовательских сообщений получать через `L10n.tr`; тестовые документы и внутренние идентификаторы оставлять независимыми от языка интерфейса.
- При изменении языка проверять сохранение выбора, автоматическое определение, английский язык при неподдерживаемом системном языке, возврат к системному режиму и применение после перезапуска. На macOS проверять также стандартные меню и системные диалоги.
- Проверять наличие всех ключей, параметры форматирования и смысл переводов на трёх языках. При изменении интерфейса проверять, что русские и английские подписи помещаются в элементы управления.
- Для изменений кода на macOS с Xcode 26+ выполнить сборку и тесты:

  ```sh
  sh Scripts/prepare-pandoc.sh
  swift build
  swift build -c release
  swift test
  ```

- Перед выпуском выполнить существующие проверки проекта:

  ```sh
  ./Scripts/verify-release.sh
  ./Scripts/run-acceptance.sh
  ```

- Перед завершением проверить `git diff --check`, итоговый diff и соответствие исходному заданию. Исправить найденные ошибки в пределах задачи.
- Если среда не позволяет выполнить сборку, тесты или проверку интерфейса, явно указать, что именно не запускалось и почему. Не выдавать статический просмотр кода за успешный запуск тестов.
- В итоговом ответе кратко сообщить, что изменено, какие проверки выполнены и какие ограничения остались; для созданных файлов указывать полный путь.

### Выбор проверок по затронутой области

| Область | Существующие проверки |
| --- | --- |
| Окна, системные вкладки, закрытие и перенос документов | `NativeTabsTests`, `WindowAndSessionTests`; отдельные сценарии `Verification/FinderLaunchVerification.swift`, `UIWindowLifecycleVerification.swift`, `ReleaseCandidateVerification.swift` |
| Восстановление после сбоя и сохранение сессии | `DocumentRecoveryStoreTests`, `WindowAndSessionTests`, соответствующие случаи `StabilityTests` |
| Редактирование, диапазоны, строки, подсветка и преобразования | `StabilityTests`, `InteractionPolishTests`; `Verification/main.swift`, `EditorInteractionVerification.swift`, `FoldLayoutVerification.swift` |
| Markdown и жизненный цикл предпросмотра | `MarkdownRendererTests`, `MarkdownPreviewTests` |
| Удалённые картинки Markdown | `MarkdownRemoteImageDownloaderTests` (отказ и разрешение на документ); с включённым разрешением — `MarkdownPreviewTests`, `MarkdownAudioInteractionTests`, `MarkdownPDFExportTests`, `MarkdownClipboardInteractionTests` |
| Избранное, группы, перетаскивание, фокус и подсказки | `SidebarDragTests`, `SidebarMotionTests`, `InteractionPolishTests`, `UIExperimentTests`; отдельно `Verification/SidebarPointerVerification.swift` |
| Ассоциации и экспериментальные примеры | `FileAssociationTests`, `ExperimentSampleLibraryTests` |
| Языки | `LocalizationTests`, проверка трёх каталогов и ручная проверка системных меню и диалогов |
| Режим чтения, статус сохранения, цель письма, фокус на предложении | `ReadingModeTests`, `DocumentSaveStatusTests`, `WritingGoalStoreTests`, `FocusSentenceTests`, `WritingModesTests` |
| Путь элемента, перенос разделов, CriticMarkup, рукопись, ссылки при переименовании | `MarkdownElementPathTests`, `MarkdownSectionMoveTests`, `CriticMarkupServiceTests`, `ManuscriptServiceTests`, `ManuscriptSourcesTests`, `ManuscriptControllerTests`, `MarkdownRenameLinkTests` |
| Палитра, строки, версии, окончания строк и кодировка | `CommandPaletteTests`, `LineEditingServiceTests`, `FileVersionServiceTests`, `VersionHistoryControllerTests`, `LineEndingTests`, `FileEncodingCommandTests` |
| Wiki-ссылки, обратные ссылки, теги, шаблоны, замена в папке | `MarkdownWikiLinkTests`, `MarkdownWikiLinkResolverTests`, `MarkdownWikiLinkRewriterTests`, `WikiLinkCatalogTests`, `MarkdownBacklinksServiceTests`, `MarkdownBacklinksControllerTests`, `MarkdownInlineTagTests`, `MarkdownTagReaderTests`, `FolderTagSearchTests`, `FolderTagListingTests`, `NoteTemplateTests`, `FolderReplaceTests`, `FolderReplaceDiskTests`, `FolderReplaceControllerTests`, `FolderSearchControllerTests` |
| Файловый ввод-вывод и большие документы | `Verification/FileServiceVerification.swift`, `LargeFileIOVerification.swift`, `PerformanceVerification.swift` |

- Классы тестов находятся в `LacEditorTests/`; выбирать конкретные случаи по изменению, например `swift test --filter LocalizationTests`. Не считать точечный запуск заменой полной проверки перед выпуском.
- `verify-release.sh` проверяет версии, сборки Debug/Release, XCTest, отдельные проверки ядра и Xcode Release. `run-acceptance.sh` включает этот сценарий и дополнительно выполняет анализ Xcode и проверки файлов размером 1/10/20/50/100 MB, платформы и приёмочного приложения. Учитывать уже выполненные проверки и не добавлять повторные ручные запуски без причины; обязательные шаги самих скриптов не отключать ради сокращения проверки.
- Отдельные GUI-сценарии — проверки запущенного интерфейса в `Verification` — не выполняются автоматически все вместе командой `run-acceptance.sh`. Они требуют macOS, подготовленного приложения и, где предусмотрено, системного разрешения на управление интерфейсом. Использовать предусмотренную сценарием тестовую идентичность, не запускать проверку над рабочим пользовательским приложением.
- Изолировать тестовые `UserDefaults` и временные каталоги; после теста восстанавливать изменённое общее состояние и снимать обработчики. Сценарии с фиксированными текстами кнопок должны явно задавать язык тестового приложения, не зависеть от языка машины.
- Длительные проверки, включаемые отдельной переменной окружения, не считать выполненными при пропуске. При изменениях сохранения и ввода проверять сценарии правки во время сохранения, позднего фонового результата, закрытия и отмены.
- Ручную приёмку выполнять по относящимся к изменению пунктам `ACCEPTANCE_TESTS.md`; для выпуска фиксировать результат в `AcceptanceReports/`. Не создавать выпуск при провале обязательных критических сценариев.
