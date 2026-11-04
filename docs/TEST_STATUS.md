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
4. `MarkdownFormattingInteractionTests`: smart quote и emoji-сценарии нельзя
   перенести в `LacEditorUITests` без изменения production UI: редактор и панель
   completion не имеют accessibility identifiers или доступных XCUI-команд.
   Текущие unit-тесты зависят от внутренних text-checking/completion callbacks;
   добавление фиктивных UI-ожиданий без идентификаторов не считается проверкой.

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
  `MarkdownTableShortcutTests` после стабилизации оконного стенда и уточнения
  ожидания группировки undo проходит 3/3. Последняя Debug-сборка через
  `BuildProject(buildForTesting: true)` успешна; `GetBuildLog(severity: warning)`
  сообщает 0 предупреждений.
- Параллельный разбор оставшихся падений делегирован трем агентам без запуска
  тестов: clipboard-уведомления, RTF/media-фрагменты и интерактивные formatting-
  сценарии. Зафиксированные изменения: маршрутизация `ClipboardSavedImagesNotice`
  по `documentID`, защита media-reveal в `FoldLayoutManager`, редактируемость
  временного table-cell editor и стабилизация UI-зависимых тестовых стендов.
- Подтверждено, что `MathPair`, smart quote и emoji completion требуют полного
  AppKit event loop и должны проверяться через `LacEditorUITests`; unit-тесты
  оставляют только детерминированную логику и сервисы. Перенос этих сценариев
  выполняется отдельно, production-guards не ослабляются.
- Дополнительный разбор агентов: RTF-падения происходят на строгих проверках
  AppKit HTML/RTF-импортера (attachment/image links/восстановленный текст), а не
  на `hasUnverifiedHTMLBlocks`; guard не ослаблять. Для UI-переноса formatting-
  сценариев нужны accessibility identifiers и проверки наблюдаемого текста;
  внутренние undo/revision/callback assertions в UI-target недоступны.
- `testFormattedCopyDownloadsSelectedRemoteImageIntoRTF` и
  `testCopyEmbeddedImageThroughEditorPreservesSourceAndRTF` после test-only
  уточнения допустимого AppKit RTF nil и канонического `#lac-media-*` токена:
  оба targeted-теста проходят.
- `MarkdownLayoutTests.testRubyBaselineReservesSpaceWithAdjacentImage`:
  исправлен фильтр inline media по `imageIsVisible`; targeted-тест проходит.
- Уточнён чек-лист `TEST_PLAN.md`: выполненным считается только auto-pair UI-
  перенос 2/2; перенос smart quote/emoji/math/formatting пока не отмечается
  выполненным, поскольку в UI-target нет доступных идентификаторов.
- `MarkdownImageInteractionTests.testVerticalListHTMLImagePercentageUsesPhysicalWidth`:
  placeholder теперь резервирует размер с учётом HTML percentage sizing до
  загрузки изображения; targeted-тест проходит.
- Полный bundle `/private/tmp/lac-result.xcresult` найден, но извлечение имён
  `not-run`/`skipped` заблокировано `xcresulttool` ошибкой прав каталога
  `TestReport`; без имён статус не дополнялся выдуманными причинами.
- Исправлен общий дефект AppKit/SwiftUI тестового стенда: hosting view в
  `MarkdownColorsTests` не имел гарантированного frame и визуально пустой
  редактор давал ложные падения temporary attributes. Добавлены явный frame,
  `isHidden = false`, `displayIfNeeded` и `layoutSubtreeIfNeeded`; targeted-тест
  цветов проходит 1/1. Правило добавлено в `TEST_PLAN.md`.
- После ожидания предыдущего clipboard task `MarkdownClipboardInteractionTests/
  testThematicBreakCopiesAvailableFormatsAndExplicitHTML` проходит 1/1.
- `MarkdownMediaClipboardTests` после исправления оконного fixture и узкого
  fallback в `LacTextView.writeSelection` проходит 6/6. Полное удаление
  media-токена при cut и восстановление через undo проверяются без ослабления.
- В `testRTFImagePasteSavesChosenFileAndUndoesText` причина раннего завершения
  локализована: тест не задавал детерминированный converter и зависел от
  внешнего поиска Pandoc; исправление выполняется только в тестовом fixture.
- В процесс исправления добавлено обязательное правило: перед патчем
  падающего теста искать похожий проходящий тест и использовать его fixture,
  оконную активацию, ожидания и lifecycle как проверенный образец.
- После нескольких неудачных проходов выполнена проверка официальной
  документации AppKit через Xcode DocumentationSearch: `NSTextView.writeSelection`
  требует объявленных типов pasteboard и делегирует запись по каждому типу;
  `NSPasteboard.setString` также требует предварительный `declareTypes`.
  Эти рекомендации сверены с fallback в `LacTextView` и тестовым fixture.
- Следующий блок `MarkdownImageTests` локализован как отсутствие полноценного
  window/visible-range стенда для `markdownImageLocation`; production-логика
  block image не изменялась до подтверждения test-only исправления.
### Последний адресный проход (2026-11-04)

- `MarkdownColorsTests.testNativeColorsAndResetPreserveTextTypingAndUndoWithEitherSyntaxSetting` проходит после принудительного `ensureLayout` перед проверкой временных атрибутов.
- `MarkdownAudioInteractionTests.testCancelledInlineAudioDoesNotInstallLatePlayer` проходит после проверки текущего выделения перед установкой поздно завершившегося аудиоплеера и повторной синхронизации media cleanup в `selectionChanged`.
- Для оставшихся падений изображения перед исправлением сопоставляются проходящие тесты и общий fixture; предыдущая попытка синхронизации отдельного `NSTextStorage` не устранила кластер, поэтому решение не считается найденным. После двух безуспешных самостоятельных проходов следующий шаг — Xcode DocumentationSearch/официальная документация Apple и интернет-поиск с фиксацией результата.
- Выполнены оба обязательных внешних шага: Xcode DocumentationSearch и поиск официальной документации Apple по TextKit 1 (`NSTextView(textContainer:)`, `NSTextStorage.addLayoutManager`, `NSLayoutManager.textStorage`). Найденная рекомендация проверена в fixture; она не устранила падения, поэтому продолжается анализ lifecycle `MarkdownPresentationController`.
- Последний адресный запуск `MarkdownImageTests/testDataImageIsDisplayedWithoutChangingSourceAndClearsAfterEdit` завершился штатно за 6,2 с, но с двумя одинаковыми падениями: `markdownImageLocation` вернул `nil` вместо позиции 8 на строках 193 и 203. Это подтверждено логом stdio; тест не зависает и не пропускается.
- Дополнительный прогон `MarkdownAudioInteractionTests` завершён штатно: 28 тестов, 17 прошли, 11 упали, 0 пропущено и 0 не запущено. Падения относятся к нескольким media-fixture/geometry сценариям; targeted race-тест отменённого inline audio остаётся проходящим.
- Для `testStandaloneSelfClosingMediaRequiresConfirmedWholeBlock` сабагент установил точную причину: fallback-фрагменты без закрывающего тега (`<audio ...>fallback<br/>`, `<video ...><source .../>`) попадают в inline HTML/cmark и не проходят ветку подтверждения standalone-блоков. Неподтверждённая попытка fallback-фильтра была отменена; требуется отдельный безопасный parser для fragment media.
- Попытка отдельного `fallbackEmbeddedMedia` также не изменила targeted-результат: 1 тест, 3 ошибки. Изменение отменено; продолжается диагностика `safeHTML`/cmark candidate collection.
- Последний запуск `MarkdownClipboardInteractionTests/testRTFImagePasteSavesChosenFileAndUndoesText` (05.11.2026) не завершился обычным assertion-отчётом: Xcode завершил процесс теста сигналом `term` после длительного выполнения. Запуск не прерывался вручную; это отдельная проблема зависания/lifecycle, требующая диагностики.
- После подтверждённого изменения `MarkdownHTMLMediaService` (разрешение узкого
  fallback для audio/video) сборка прошла без ошибок, но targeted
  `MarkdownAudioInteractionTests/testStandaloneSelfClosingMediaRequiresConfirmedWholeBlock`
  завершился штатно с 1 падением и 3 assertion-ошибками: одиночный opening
  `<audio>` не распознан, а два fallback-фрагмента дали 0 вместо 1. Патч
  признан неэффективным и отменён; повторный запуск без нового изменения не
  выполняется.
- Попытка завершать pending opening media в `PairedMediaCollector` на следующем
  `html_inline` self-closing fallback также собрала проект успешно, но targeted
  тест снова дал те же 3 ошибки (0 кандидатов для двух fallback и отсутствие
  одиночного opening). Изменение отменено; collector не получает ожидаемую
  последовательность узлов, нужен диагностический разбор cmark-дерева до нового
  запуска.
- Реализован узкий cmark-независимый post-pass для standalone fallback-медиа:
  строки на границе блока с `<audio>/<video>` и завершающим `<br/>`/`<source/>`
  нормализуются и проходят общий валидатор. html_block-ветка больше не принимает
  одиночный незакрытый opening-тег без fallback. После успешной сборки targeted
  `testStandaloneSelfClosingMediaRequiresConfirmedWholeBlock` проходит 1/1.
- Проверка класса `MarkdownImageTests` после добавления `view.string = source`
  завершилась штатно: 14 тестов, 5 прошли, 9 упали, 0 пропущено/не запущено.
  Простое заполнение текста fixture не устранило `markdownImageLocation == nil`
  и ready/pending image assertions; требуется следующий анализ lifecycle и
  visible-range стенда. Повторный запуск без нового изменения не выполняется.
- Проверенная гипотеза о fallback на `textView.bounds` при нулевом `visibleRect`
  не изменила результат: после сборки класс снова завершился как 5/14 passed,
  9 failed. Production-изменение отменено; нужен анализ фактического lifecycle
  окна/scroll view по проходящему fixture.
- Добавление `view.string`, `NSWindow` и `makeKeyAndOrderFront` в image-fixture
  также не изменило результат: после сборки `MarkdownImageTests` снова 5/14
  passed и 9 failed. Оконный lifecycle сам по себе недостаточен; проверяется
  порядок layout/viewportChanged перед `MarkdownPresentationController.update`.
- Полный fixture lifecycle (`view.string`, окно, layout/display/ensureLayout)
  также не изменил результат: `MarkdownImageTests` снова 5/14 passed и 9 failed.
  Изменения fixture откатываются; дальнейший поиск переносится на реальную
  production-цепочку image loading/location.
- Диагностический лог подтвердил: data-image действительно устанавливался,
  но центрированный `imageRect` имел x=199.5, тогда как проверка попадания
  использовала точку начала source-строки x=5.5. Исправлен только hit-test:
  визуальный рендер остаётся центрированным, а `markdownRenderedHit` проверяет
  исходный line-aligned rect. Targeted data-image тест проходит; весь класс
  улучшился до 7/14 passed, 7 failed.
- Повторный targeted `testLoadedImageIsRetainedAfterScrollingFarPastViewport`
  после этого изменения штатно завершился с теми же двумя `nil`-ошибками;
  зависания нет. Проверка cache/shift lifecycle не выявила подтверждённой
  единой production-причины для оставшихся ready/pending сценариев; новый
  непроверенный patch не внесён.
- Диагностика `testDataImageIsDisplayedWithoutChangingSourceAndClearsAfterEdit`
  показала, что изображение устанавливалось, но центрированный hit-rect не
  пересекал точку начала исходной строки. Поэтому `markdownRenderedHit` переведён
  на line-aligned rect только для hit-test; визуальный rect не изменён.
- Inline-image hit-test дополнен узким fallback в пределах той же строки:
  визуальный rect не меняется, но точка в верхней части line fragment считается
  попаданием по изображению. После этого `testLoadedImageIsRetainedAfterScrollingFarPastViewport`
  проходит; cursor/source-range тест всё ещё падает и требует отдельного
  разбора selection lifecycle.

- После сравнения с проходящими image-тестами исправлен hit-test блочного
  Markdown-изображения: для маленьких (1×1) data-image точка в строке теперь
  проверяется по line fragment, а не только по физическому размеру картинки.
  Одновременно сохранено изображение при входе курсора в его source token.
  Сборка успешна; `MarkdownImageTests` дал 9/14 passed, 5 падений.
- Для `ImageShiftFixture` добавлен `textProvider`, а ввод в fixture теперь
  проходит через тот же `NSTextView` и корректно подтверждает revision после
  `beforeEdit`. Это устранило прежнее рассогласование lifecycle.
- В `MarkdownPresentationController` исправлен перенос готовых media-cache
  placement, divergent parse очищает старое изображение, а pending remote
  загрузка не устанавливает placeholder до получения ответа. `ImageCacheKey`
  учитывает alt-текст, поэтому изменённый токен не переиспользует старый ресурс.
  Сборка успешна; `MarkdownImageTests` — 14/14, ошибок и пропусков нет.
- После удаления placeholder до завершения локальной/удалённой загрузки
  повторный targeted-прогон `MarkdownImageTests` завершён 14/14. Это также
  устранило ложное отображение удалённого файла при divergent parse.
- Полный `RunAllTests` завершён штатно без зависания: 3900 тестов, 3701
  прошёл, 191 упал, 7 пропущено, 1 не запущен. Полный отчёт сохранён Xcode в
  `D0B39FC4-AE3C-47D8-B575-ED9BC863C0E3.txt`; оставшиеся падения теперь
  актуализированы по этому отчёту и требуют следующей очереди исправлений.
- Адресная повторная проверка `FolderOpeningTests/testQueuedFolderThenFileKeepsExplicitFolder`
  проходит 1/1; падение полного прогона для него было нестабильным.
- `TaskCheckboxTests/testClickUsesCurrentSourceAndUndo` теперь проверяет
  логический исходник без служебного `#lac-media-*` токена; остаётся отдельное
  несоответствие координаты выделения в projected media-тексте.
