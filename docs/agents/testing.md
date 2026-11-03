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
| Окна, системные вкладки, закрытие и перенос документов | `NativeTabsTests`, `WindowAndSessionTests`, `WindowNavigationTests`, `LaceditURLTests`, `FolderOpeningTests`; отдельные сценарии `Verification/FinderLaunchVerification.swift`, `UIWindowLifecycleVerification.swift`, `ReleaseCandidateVerification.swift` |
| Восстановление после сбоя и сохранение сессии | `DocumentRecoveryStoreTests`, `WindowAndSessionTests`, соответствующие случаи `StabilityTests` |
| Редактирование, диапазоны, строки, подсветка и преобразования | `StabilityTests`, `InteractionPolishTests`; `Verification/main.swift`, `EditorInteractionVerification.swift`, `FoldLayoutVerification.swift` |
| Markdown и жизненный цикл предпросмотра | `MarkdownRendererTests`, `MarkdownPreviewTests` |
| Удалённые картинки Markdown | `MarkdownRemoteImageDownloaderTests` (отказ и разрешение на документ); с включённым разрешением — `MarkdownPreviewTests`, `MarkdownAudioInteractionTests`, `MarkdownPDFExportTests`, `MarkdownClipboardInteractionTests` |
| Избранное, группы, перетаскивание, фокус и подсказки | `SidebarDragTests`, `SidebarMotionTests`, `InteractionPolishTests`, `UIExperimentTests`; отдельно `Verification/SidebarPointerVerification.swift` |
| Ассоциации и экспериментальные примеры | `FileAssociationTests`, `ExperimentSampleLibraryTests` |
| Языки | `LocalizationTests`, проверка трёх каталогов и ручная проверка системных меню и диалогов |
| Режим чтения, статус сохранения, цель письма, фокус на предложении | `ReadingModeTests`, `DocumentSaveStatusTests`, `WritingGoalStoreTests`, `FocusSentenceTests`, `WritingModesTests` |
| Путь элемента, перенос разделов, CriticMarkup, рукопись, ссылки при переименовании | `MarkdownElementPathTests`, `MarkdownSectionMoveTests`, `CriticMarkupServiceTests`, `ContrastTests`, `CriticMarkupRenderTests`, `CriticMarkupExportTests`, `ManuscriptServiceTests`, `ManuscriptSourcesTests`, `ManuscriptControllerTests`, `ManuscriptProjectTests`, `WriterModeTests`, `MarkdownRenameLinkTests` |
| Палитра, строки, версии, окончания строк, кодировка и сниппеты | `CommandPaletteTests`, `NavigationHistoryTests`, `LineEditingServiceTests`, `FileVersionServiceTests`, `VersionHistoryControllerTests`, `TextCompareControllerTests`, `LineEndingTests`, `FileEncodingCommandTests`, `SnippetTests` |
| Wiki-ссылки, обратные ссылки, теги, шаблоны, замена в папке | `MarkdownWikiLinkTests`, `MarkdownWikiLinkResolverTests`, `MarkdownWikiLinkRewriterTests`, `WikiLinkCatalogTests`, `MarkdownBacklinksServiceTests`, `MarkdownBacklinksControllerTests`, `MarkdownInlineTagTests`, `MarkdownTagReaderTests`, `FolderTagSearchTests`, `FolderReplaceBackupTests`, `FolderReplaceBackupControllerTests`, `FolderTagListingTests`, `NoteTemplateTests`, `FolderReplaceTests`, `FolderReplaceDiskTests`, `FolderReplaceControllerTests`, `FolderSearchControllerTests` |
| Оглавление по символам | `SymbolOutlineTests`, `SymbolOutlineControllerTests`, `LocalizationTests` |
| Построение regex через AI | `AIRegexBuilderTests`, `AIRegexControllerTests`, `AIResponseJSONTests`, `LocalizationTests` |
| Слежение за файлом на диске | `OpenFileWatcherTests`, `DocumentSaveStatusTests`, `NativeTabsTests`, `StabilityTests`, `LocalizationTests` |
| Файловый ввод-вывод и большие документы | `Verification/FileServiceVerification.swift`, `LargeFileIOVerification.swift`, `PerformanceVerification.swift` |

- Классы тестов находятся в `LacEditorTests/`; выбирать конкретные случаи по изменению, например `swift test --filter LocalizationTests`. Не считать точечный запуск заменой полной проверки перед выпуском.
- `verify-release.sh` проверяет версии, сборки Debug/Release, XCTest, отдельные проверки ядра и Xcode Release. `run-acceptance.sh` включает этот сценарий и дополнительно выполняет анализ Xcode и проверки файлов размером 1/10/20/50/100 MB, платформы и приёмочного приложения. Учитывать уже выполненные проверки и не добавлять повторные ручные запуски без причины; обязательные шаги самих скриптов не отключать ради сокращения проверки.
- Отдельные GUI-сценарии — проверки запущенного интерфейса в `Verification` — не выполняются автоматически все вместе командой `run-acceptance.sh`. Они требуют macOS, подготовленного приложения и, где предусмотрено, системного разрешения на управление интерфейсом. Использовать предусмотренную сценарием тестовую идентичность, не запускать проверку над рабочим пользовательским приложением.
- Изолировать тестовые `UserDefaults` и временные каталоги; после теста восстанавливать изменённое общее состояние и снимать обработчики. Сценарии с фиксированными текстами кнопок должны явно задавать язык тестового приложения, не зависеть от языка машины.
- Длительные проверки, включаемые отдельной переменной окружения, не считать выполненными при пропуске. При изменениях сохранения и ввода проверять сценарии правки во время сохранения, позднего фонового результата, закрытия и отмены.
- Ручную приёмку выполнять по относящимся к изменению пунктам `ACCEPTANCE_TESTS.md`; для выпуска фиксировать результат в `AcceptanceReports/`. Не создавать выпуск при провале обязательных критических сценариев.
- Слова, предложения, стемминг, стоп-слова: `TextSegmentationTests`, `WordNormalizerTests`, `StopWordsTests`. Результаты `NLTokenizer`/`NLLanguageRecognizer` проверяются только на Mac; инварианты диапазонов не подгонять под результат.
- Доступность AI, подсказка, функции писательских панелей, правая панель: `AIAvailabilityTests`, `AIWriterFeaturesTests`, `InspectorPanelTests`, `WriterComponentsTests`, `ContrastTests`, `LocalizationTests`, `SettingsUXTests`.
- `LacEditorTests/SearchIndexTests.swift` — индекс слов: формы слов en/ru/zh, удаление и изменение файлов, симлинки, порядок bm25, открытые документы, поздняя запись (отбрасывается по времени начала чтения, а не по дате файла; файл с более старой датой обновляется), экранирование `MATCH`, расширение запроса, нарезка, отрывок с подсветкой, отсутствие FTS5 (`unavailable`), `WordSearchController` без `AppState` (поздний результат отбрасывается, `select` вызывает reveal), нарезка с `\r\n` и китайским без пробелов, ключи локализации. Тесты работают во временном каталоге и пропускаются, если FTS5 недоступен.
- Проверка стиля: `StyleCheckTests` (правила, маска прозы, настройки, номера строк), `StyleReviewParsingTests` (разбор ответа AI, строгая привязка цитат), `ContrastTests` (цвета подчёркиваний), `LocalizationTests` (ключи стиля во всех каталогах).
- Экспорт в Fountain: `FountainLintTests` (классификатор, заметки, ошибки проверки), `FountainExportTests` (структурное преобразование en/ru/zh, защита `!`, заметки и предупреждения, части проекта, чистая часть адаптации, параметры строк) и `FountainExportControllerTests` (внедряемый `generate`: успех, повтор, откат, сетевая ошибка, отмена и поздний ответ, подтверждение большого запроса).
- Снимки и автосохранение: `DocumentSnapshotStoreTests` (формат, sha256, лимит, перенос, повреждение, более новая версия, симлинки), `AutosaveTests` (`tick(now:)`, интервал, внешнее изменение и пауза, ошибка записи, версии не чаще 5 минут, снимок не меняет файл; тесты снимков удаляют свои каталоги в `defer`), `DocumentSnapshotStoreTests.testAddAfterCorruptIndexQuarantinesAndStartsClean, `VersionHistoryControllerTests` (режим «快照»), `LocalizationTests.testSnapshotAndAutosaveTextsExistInAllCatalogs`. Проверка вручную на Mac: автосохранение не пишет при marked text (ввод иероглифов), не пишет под открытым вопросом «Сохранить изменения?» и после подтверждённого выхода (`terminationApproved` в тестах не проверяется), ⌃⌘S и пункты меню, объявления VoiceOver («快照已保存», пауза и ошибка автосохранения), секция снимков в инспекторе на тёмной теме и крупном шрифте.
- Доска и сводный просмотр: `SceneSynopsisDrafterTests`, `WriterBoardModelTests`, `WriterBoardControllerTests`, `WriterCombinedPageTests`, `WriterCombinedViewControllerTests`, `testWriterBoardTextsExistInAllCatalogs`. Вручную на Mac: окна доски и просмотра, перенос карточек, кнопки, клики по подписям частей, тёмная тема, AI-описание.
- Карточки мира: `StoryCardTests`, `StoryCardHeaderEditorTests`, `StoryCardMatcherTests`, `StoryCardCatalogTests`, `StoryCardMentionTests` (индекс, совместные упоминания, кандидаты), `StoryCardAIServiceTests`, `StoryCardTemplateTests`, `LocalizationTests.testWorldTextsExistInAllCatalogs`.

- Ментальные карты: `MindMapModelTests`, `MindMapLayoutTests`, `MindMapLinksTests`, `MindMapAIParsingTests`, `ContrastTests.testMindMapColorsMeetContrast`, `LocalizationTests.testMindMapTextsExistInAllCatalogs`. Вручную на Mac: окно карты, перетаскивание, ⌘+/⌘−/⌘0, Tab/Return/стрелки, ⌘Z из окна карты, VoiceOver в «Схеме» и «Списке», экспорт PNG/SVG, тёмная тема, подписи ru/en в панели, документ на 1500 узлов.
