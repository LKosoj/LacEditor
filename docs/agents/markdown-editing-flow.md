# Жизненный цикл правки текста в оформленном Markdown

Этот файл описывает фактический путь данных и состояний при редактировании Markdown в оформленном представлении. Он нужен как рабочая карта для диагностики ухудшений. Исправления поведения в этой области сначала описываются здесь, а затем проверяются по коду и тестам.

## Границы описания

Один и тот же текст существует в нескольких слоях:

1. `EditorDocument` хранит исходную строку документа и её ревизию (`textRevision`).
2. `NSTextStorage` внутри `LacTextView` содержит живой текст редактора. Пока пользователь печатает, он может опережать модель документа: `hasPendingLiveEdits` становится `true`.
3. В оформленном Markdown часть исходных символов скрыта, а часть заменена отображаемыми глифами, картинками и временными атрибутами. Саму строку это не меняет.
4. `MarkdownPresentation` — результат разбора исходной строки. В нём находятся диапазоны элементов Markdown, таблиц, изображений, формул, медиа и других объектов.
5. `FoldLayoutManager` применяет результат к TextKit 1: скрывает маркеры, меняет геометрию и устанавливает временные атрибуты.

Диапазоны находятся в координатах UTF-16 (`NSRange`). Нельзя сравнивать их с `String.count` или числом байтов UTF-8.

## Создание редактора и включение оформления

`EditorTextView.makeNSView` создаёт `NSTextStorage`, `NSLayoutManager`, `FoldLayoutManager`, `LacTextView` и `EditorCoordinator` ([EditorTextView.swift:71](../../LacEditor/Editor/EditorTextView.swift#L71), [EditorTextView.swift:117](../../LacEditor/Editor/EditorTextView.swift#L117)). Координатор связывает TextKit, документ и фоновые задачи.

`EditorTextView.updateNSView` обновляет документ, язык, доступность редактирования, настройки Markdown и ревизию ([EditorTextView.swift:277](../../LacEditor/Editor/EditorTextView.swift#L277)). После этого вызываются `updateMarkdownPresentation`, синхронизация выделения, восстановление viewport и планирование подсветки.

`EditorCoordinator.updateMarkdownPresentation` создаёт один `MarkdownPresentationController`, подключает обратные вызовы для геометрии, изображений, emoji/wiki completion и восстановления цветов, затем передаёт контроллеру `enabled = language == .markdown && isMarkdownFormatted` ([EditorCoordinator.swift:3372](../../LacEditor/Editor/EditorCoordinator.swift#L3372)). В исходном режиме `enabled == false`, поэтому оформленные диапазоны постепенно снимаются.

## Обычная клавиатурная правка

### До изменения строки

AppKit вызывает `EditorCoordinator.textView(_:shouldChangeTextIn:replacementString:)` ([EditorCoordinator.swift:4091](../../LacEditor/Editor/EditorCoordinator.swift#L4091)). Последовательность внутри метода:

1. Завершается активное редактирование ячейки таблицы, очищаются fold и подсветка поиска.
2. Диапазон ограничивается длиной текущего `NSTextStorage`; вычисляется длина замены в UTF-16.
3. Увеличивается `contentRevision`, создаётся `DocumentEditDelta`, инвалидируются подсветка синтаксиса, индекс разделителей и фоновые нормализации списков.
4. Вызывается `MarkdownPresentationController.beforeEdit`.
5. Для Markdown проверяется автоматическая нормализация нумерованного списка. Если она нужна, координатор выполняет составную замену через повторный `insertText` и возвращает `false` для исходной операции.

`beforeEdit` сбрасывает разобранный результат, оглавление и читаемый текст, отменяет устаревшие операции. Если правка безопасна для быстрого пути, контроллер вызывает `presentationAfterEdit`, затем `shiftPresentation`: диапазоны презентации, подсветка кода, медиа и геометрия сдвигаются без полного разбора ([MarkdownPresentationController.swift:918](../../LacEditor/Editor/MarkdownPresentationController.swift#L918), [MarkdownPresentationController.swift:1822](../../LacEditor/Editor/MarkdownPresentationController.swift#L1822)). Правка, которую быстрый путь не пропустил, идёт через `shiftAroundEdit`: снимается только задетое, остальное сдвигается. Всё оформление снимается (`clear`), только если нет текста правки, открыта таблица или в документе есть заглавные либо нумерованные заголовки.

### Фактическая замена

После `true` от делегата AppKit меняет `NSTextStorage`, затем вызывает `LacTextView.didChangeText`. Внутри `LacTextView` дополнительно живут автоматические пары скобок/кавычек и Markdown-знаков; при `marked text` они не применяются ([LacTextView.swift:1000](../../LacEditor/Editor/LacTextView.swift#L1000), [LacTextView.swift:1016](../../LacEditor/Editor/LacTextView.swift#L1016), [LacTextView.swift:1063](../../LacEditor/Editor/LacTextView.swift#L1063)).

`EditorCoordinator.textDidChange` обновляет индекс строк, отмечает живую правку в документе, вызывает `markdownPresentation.edited(revision:)`, ставит задержанную синхронизацию модели, подсветку, линейку, completion и проверку позиции ([EditorCoordinator.swift:3865](../../LacEditor/Editor/EditorCoordinator.swift#L3865)).

`edited` сверяет сохранённую в `keptEdit` ревизию, длину и отсутствие `marked text`. При совпадении применяется стиль соседнего символа, возвращаются сдвинутые медиа и запускается новый разбор. При несовпадении старая презентация очищается ([MarkdownPresentationController.swift:996](../../LacEditor/Editor/MarkdownPresentationController.swift#L996)).

Через 0,35 секунды `flushModelText` переносит живую строку в `EditorDocument`, сбрасывает `hasPendingLiveEdits` и пересчитывает dirty state ([EditorCoordinator.swift:3923](../../LacEditor/Editor/EditorCoordinator.swift#L3923)). До этого фоновый результат не должен считать модель окончательно синхронизированной.

## Быстрый путь сдвига оформления

Он действует только для разрешённых простых правок внутри обычного текста. `MarkdownPresentation.allowsTypingEdit`, `canShift` и `paragraphBreakEdit` проверяют границы Markdown ([MarkdownPresentation.swift:1099](../../LacEditor/Models/MarkdownPresentation.swift#L1099), [MarkdownPresentation.swift:1314](../../LacEditor/Models/MarkdownPresentation.swift#L1314), [MarkdownPresentation.swift:1379](../../LacEditor/Models/MarkdownPresentation.swift#L1379)).

При успешной проверке:

- `MarkdownPresentation.shift` переносит диапазоны всех элементов правее правки;
- `FoldLayoutManager.shiftMarkdownPresentation` переносит установленное оформление TextKit ([FoldLayoutManager.swift:1800](../../LacEditor/Editor/FoldLayoutManager.swift#L1800));
- контроллер переносит словари готовых изображений, формул, диаграмм и медиа;
- `keptEdit` запоминает ревизию, длину и вставленный диапазон до следующего подтверждения.

Следующая клавиша до нового разбора идёт тем же порядком: подтверждённая правка продолжает сдвиг. Если `keptEdit` не подтверждён текущим `edited`, старое оформление снимается: так ошибочные диапазоны не накапливаются.

Правка разметки (`localEdit` → `shiftAroundEdit`) убирает задетые элементы (`removeTouched`) до сдвига: задетый диапазон `shift` оставляет на месте, и новый символ иначе попал бы в старый нулевой glyph маркера или замены. После такой правки `install` при расхождении `spans` один раз вызывает полный `restoreStyles`: стили вне экрана могли устареть.

## Разбор и асинхронное применение

`MarkdownPresentationController.schedule` берёт снимок `textView.string`, запускает `MarkdownPresentationParser.parse` в `OperationQueue`, а затем принимает результат только при одновременном совпадении документа, URL, поколения, `contentRevision`, поколения `TaskCoordinator` и отсутствии `marked text` ([MarkdownPresentationController.swift:1599](../../LacEditor/Editor/MarkdownPresentationController.swift#L1599)). Для полного оформления используется задержка около 0,6 секунды; для одного пути элемента — около 0,4 секунды.

После принятия результата `install` вызывает `prepareForEditing`, передаёт модель в `FoldLayoutManager.setMarkdownPresentation`, восстанавливает видимые стили и запускает загрузку видимых ресурсов ([MarkdownPresentationController.swift:1738](../../LacEditor/Editor/MarkdownPresentationController.swift#L1738), [FoldLayoutManager.swift:1706](../../LacEditor/Editor/FoldLayoutManager.swift#L1706)). Поздний результат, не прошедший проверки, молча отбрасывается.

## Особые случаи

### IME и `marked text`

`setMarkedText`, `unmarkText` и `insertText` в `LacTextView` откладывают метрики и повторный разбор до завершения композиции. `MarkdownPresentationController` во время композиции очищает готовые временные атрибуты, но не принимает новый фоновой результат. После завершения вызывается `compositionFinished` ([MarkdownPresentationController.swift:1034](../../LacEditor/Editor/MarkdownPresentationController.swift#L1034)). Любая новая логика должна повторно проверять `hasMarkedText` перед применением.

### Data URI изображений

В оформленном режиме `EditorCoordinator.displayedText` может включать отдельную проекцию больших `data:`-изображений, а `synchronizeMarkdownImageProjection` заменяет отображаемую строку при переключении режима ([EditorCoordinator.swift:2221](../../LacEditor/Editor/EditorCoordinator.swift#L2221), [EditorCoordinator.swift:2238](../../LacEditor/Editor/EditorCoordinator.swift#L2238)). Для такой замены выделение переводится между исходными и отображаемыми диапазонами. Это внешний путь изменения `NSTextStorage`, поэтому он использует `projectionChanged`, а не обычный `beforeEdit`.

### Таблицы

Редактор ячейки может быть дочерним `NSTextView`. До правки родительский координатор завершает child editor; после этого изменение проходит через тот же `shouldChangeText` родителя. Отдельные команды таблицы используют `MarkdownTableEditingService` в `applyMarkdownFormatting` ([EditorCoordinator.swift:1368](../../LacEditor/Editor/EditorCoordinator.swift#L1368)).

У дочернего редактора есть собственные исходный текст ячейки, проекция, диапазон и ревизия. При возврате в родительский редактор callback сначала сверяет ревизию и идентичность исходного текста, затем переводит display-range обратно в source-range. При несовпадении callback прекращается без изменения родительского текста; это нужно отличать от потери ввода.

### Форматирование командами

Команды жирного, списков, таблиц и других элементов не меняют модель напрямую. `AppState.formatMarkdown` публикует уведомление, координатор строит `MarkdownFormattingEdit`, проверяет ревизию и выделение, затем выполняет `shouldChangeText` → `replaceCharacters` → `didChangeText` с одной группой undo.

## Что проверять при расследовании ухудшения

1. Сначала записать исходную строку, отображаемую строку, `contentRevision`, `EditorDocument.textRevision`, `hasPendingLiveEdits`, `isMarkdownFormatted` и `hasMarkedText` до и после одной правки.
2. Проверить, какой путь выбран: `presentationAfterEdit`/`shiftPresentation` или полный `clear`/`schedule`.
3. Для фонового результата сверить документ, ревизию, generation и `TaskCoordinator`.
4. Для ошибки отображения сравнить диапазоны `MarkdownPresentation`, диапазоны `FoldLayoutManager` и реальную длину `NSTextStorage` после правки.
5. Для таблицы отдельно записать состояние parent и child editor до передачи правки.
6. Для data URI проверить преобразование исходного диапазона в отображаемый и обратный диапазон.
7. Отдельно воспроизвести второй символ до нового разбора, границу Markdown-маркера, Enter, data URI и IME в ячейке.
8. Только после фиксации расхождения менять поведение. Каждое исправление добавлять ниже в журнал.

## Журнал изменений поведения

### 2026-10-31 — расследование тормозов, изображений, пробела и фона диаграмм

Код не менялся. Ниже зафиксированы причины, подтверждённые двумя независимыми проходами, и места, которые перед исправлением нужно проверить коротким воспроизведением.

#### 1. Тормоза при вводе

До вставки символа `EditorCoordinator.textView(_:shouldChangeTextIn:replacementString:)` инвалидирует подсветку от изменённой строки до конца документа, контекст парных разделителей и нормализацию списка ([EditorCoordinator.swift:4091](../../LacEditor/Editor/EditorCoordinator.swift#L4091)). После вставки `textDidChange` ставит несколько независимых задач: синхронизацию модели, подсветку, delimiter matching, раскладку строки каретки, линейку, typewriter, codec suggestion, AI completion, fold и автоматические media folds ([EditorCoordinator.swift:3865](../../LacEditor/Editor/EditorCoordinator.swift#L3865)).

Безопасная первая правка дополнительно сдвигает хвост `MarkdownPresentation`, `FoldLayoutManager` и готовых медиа; стоимость растёт с количеством элементов правее каретки. При второй клавише до разбора контроллер входит в `deferredReadyClear` и вызывает `clear()`, который снимает оформление целиком ([MarkdownPresentationController.swift:918](../../LacEditor/Editor/MarkdownPresentationController.swift#L918), [MarkdownPresentationController.swift:1768](../../LacEditor/Editor/MarkdownPresentationController.swift#L1768)). После этого `applyVisible` снова запускает загрузку картинок, диаграмм, формул и кода, а затем сортирует `styledRanges` для поиска неоформленного участка ([MarkdownPresentationController.swift:1979](../../LacEditor/Editor/MarkdownPresentationController.swift#L1979), [MarkdownPresentationController.swift:2135](../../LacEditor/Editor/MarkdownPresentationController.swift#L2135)).

Пауза полного разбора — около 0,6 секунды; каждая следующая клавиша её отменяет. Поэтому есть два разных провала: тяжёлая первая безопасная правка из-за сдвига хвоста и тяжёлая следующая правка из-за полного снятия и повторной подготовки TextKit.

#### 2. Исходный текст вместо уже готового изображения

При безопасной правке изображение действительно умеет сохраняться: `shiftPresentation` сдвигает диапазоны, `shiftInstalledMedia` меняет ключи готовых картинок, а `FoldLayoutManager.shiftMarkdownPresentation` переносит их отображение ([MarkdownPresentationController.swift:1822](../../LacEditor/Editor/MarkdownPresentationController.swift#L1822), [MarkdownPresentationController.swift:2934](../../LacEditor/Editor/MarkdownPresentationController.swift#L2934)).

При небезопасной правке или второй клавише до нового разбора `clear()` удаляет `markdownImages`, `markdownBlockImages`, `markdownInlineImages` и анимированные view. Байты могут оставаться в кэше, но скрывающие диапазоны TextKit уже сняты, поэтому снова рисуется исходная строка `![...](...)`. Placeholder устанавливается только позже, в `loadVisibleImages`, после нового `presentation` и `applyVisible` ([MarkdownPresentationController.swift:3561](../../LacEditor/Editor/MarkdownPresentationController.swift#L3561)).

Это объясняет оба наблюдения: короткую вспышку текста при второй клавише и более раннюю вспышку при правке, для которой `canShift` отказал (таблица, граница Markdown, оглавление, якорь, нумерованный заголовок и другие элементы структуры). Это не потеря файла изображения, а преждевременное снятие его отображения.

#### 3. Пропавший пробел

Первоначальная гипотеза про `.softBreak` не подтверждена для текущих настроек. Парсер создаёт `.softBreak` с текстом `" "` только при выключенной `preserveEditingSoftBreaks` ([MarkdownPresentationParser.swift:2996](../../LacEditor/Preview/MarkdownPresentationParser.swift#L2996)); текущая конфигурация включает эту настройку. Даже при создании replacement `FoldLayoutManager` рассчитывает для него ширину, поэтому одного условия `drawGlyphs` недостаточно для объяснения симптома.

Подтверждён другой путь: нулевую ширину получают `.spaces` с пустым текстом для ведущих и хвостовых пробелов ([MarkdownPresentationParser.swift:3016](../../LacEditor/Preview/MarkdownPresentationParser.swift#L3016), [MarkdownPresentationParser.swift:3156](../../LacEditor/Preview/MarkdownPresentationParser.swift#L3156)). Такие диапазоны не проходят быстрый сдвиг рядом с разметкой и в конце строки ([MarkdownPresentation.swift:1414](../../LacEditor/Models/MarkdownPresentation.swift#L1414)). Но это объясняет исчезновение после нового разбора, а не обязательно короткое исчезновение до него.

Причина именно наблюдаемого краткого исчезновения пока не установлена. Нужно сравнить текущий код с изменением `2163d6d`, проверить четыре сценария (пробел внутри строки, в конце строки, после `**`, в абзаце с картинкой) и снять ширину глифа до и после паузы разбора. Не считать `.softBreak` установленной причиной до этой проверки.

#### 4. Светлый фон диаграммы в тёмной теме

Для flow/sequence причина подтверждена: `loadVisibleDiagrams` создаёт `LegacyDiagramRenderService` без признака темы ([MarkdownPresentationController.swift:3223](../../LacEditor/Editor/MarkdownPresentationController.swift#L3223), [MarkdownPresentationController.swift:3271](../../LacEditor/Editor/MarkdownPresentationController.swift#L3271)). У сервиса нет dark-параметра, а `LegacyDiagrams/host.html` задаёт белый фон. Снимок всего `WKWebView` поэтому содержит белый холст.

Для Mermaid признак `dark` передаётся в `MermaidRenderService`, но HTML-страница сервиса не задаёт фон и не получает цвет фона редактора ([MermaidRenderService.swift:39](../../LacEditor/Preview/MermaidRenderService.swift#L39)). Снимок всего web view может включать светлый холст даже при тёмных цветах линий. Это нужно подтвердить отдельным снимком углов изображения; текущая проверка Mermaid сверяет цвета элементов, но не цвет холста.

#### Минимальные воспроизведения перед исправлением

1. Набрать две буквы до паузы разбора в обычном абзаце перед картинкой; повторить в документе с оглавлением или у границы Markdown.
2. Для картинки проверить, что первая безопасная правка переносит готовый объект и не запускает повторную загрузку, а вторая клавиша вызывает `clear()` и возвращает исходный текст.
3. Вставить пробел внутри слова, в конце строки и после `**`; сравнить глиф и ширину до и после паузы 0,6 секунды.
4. Проверить отдельно Mermaid и flow/sequence в тёмном окне, измерив цвет угла готовой `NSImage`.

Будущие исправления добавлять в этот журнал только после такой проверки причины; кодовые изменения в текущем расследовании не выполнялись.

### Уточнение после CLI Claude

CLI Claude, запущенный от `claude-bot`, подтвердил цепочку `clear()` → снятие готовых картинок → видимый исходный Markdown до нового разбора и отсутствие темы у legacy flow/sequence. Для тормозов он выделил `clear()`/`install` как тяжёлые участки, но отметил, что главный вклад нужно подтвердить Instruments. По пробелу причина оставлена открытой; прежнее объяснение через `.softBreak` признано недостаточным.

### 2026-10-31 — ввод без сброса оформления, пробел и фон диаграмм

- Симптом: ввод тормозит, а готовая картинка вспыхивает исходным Markdown при двух быстрых клавишах и при правке, не прошедшей быстрый путь (например, пробел в конце строки). Пробел рядом со строчной картинкой пропадает. Flow, sequence и Mermaid в тёмной теме дают светлый фон.
- Причина вспышки: `beforeEdit` вызывал `clear()` на второй клавише до разбора (ветка `isContinuation` из 2163d6d) и на любой правке, отклонённой `canShift`/`allowsTypingEdit`. Причина пробела: замены `.spaces` показываются только при касании `markdownInlineSelection` (`FoldLayoutManager.textReplacement`), а `inlineSelection()` возвращал nil при каретке у картинки. Причина фона: legacy-сервис не получал тему, WebView рисовал белый холст. Постоянные расходы: снимки всего текста в `scheduleDelimiterMatch` и `scheduleAutomaticMediaFolds`, двойное планирование разделителей и курсора, лишние `DispatchQueue.main.async`, сортировка `styledRanges` в каждом `unstyledRange`.
- Изменено: `MarkdownPresentationController.swift` (`shiftAroundEdit`, `dropTouched`, `localEdit`, `selectionTouchesSpaces`, упорядоченная вставка в `styledRanges`), `MarkdownPresentation.swift` (`removeTouched`), `EditorCoordinator.swift`, `LegacyDiagramRenderService.swift`, `MermaidRenderService.swift`, `LegacyDiagrams/host.js`, тесты `MarkdownPresentationTests`, `MarkdownImageTests`, `LegacyDiagramRenderServiceTests`, `MermaidRenderServiceTests`. Правила быстрого пути, разбор, формат файлов и настройки не менялись; `.softBreak` не затрагивался.
- Проверки Claude: `git diff --check`, `node --check` для `host.js` и чтение кода. Дополнительно выполнены независимые `git diff --check`, `node --check` и Swift parse изменённых файлов (кроме `EditorCoordinator.swift`, где текущий Linux-компилятор не понимает уже существующий Swift 6.2 `isolated deinit`). `swift build` и `swift test` запускались, но остановились на уже существующем Vendor/TreeSitterYAML C-исходнике без `int8_t`/`int32_t`; XCTest, GUI и Instruments не выполнены, замеров «после» нет. Ветка пробела подтверждена чтением кода, а не воспроизведением.
- Ограничения: до паузы разбора (0,6 с) дальние последствия правки разметки (например, открытие ограждения) видны со старым оформлением. Пробел внутри абзаца блочной картинки закрыт самой картинкой. Инвалидация подсветки до конца документа в `shouldChangeTextIn` оставлена: она нужна многострочным конструкциям.

## План исправления

1. **Зафиксировать базовую точку.** Замеры уже подтвердили оба симптома: ввод тормозит, а готовое изображение временно заменяется исходным Markdown. Сохранить эти результаты и использовать их как критерий «до/после».
2. **Сохранить готовые изображения.** Вернуть быстрый путь через существующие media-only операции: при правке, не затрагивающей изображение, переносить его диапазон, view и ключ кэша. Не запускать повторную загрузку неизменившегося ресурса.
3. **Убрать полный `clear` из обычного продолжения ввода.** Вторая клавиша до нового разбора не должна снимать всё оформление. Полный сброс оставить только для правки, которая действительно меняет структуру элемента или делает старые диапазоны недействительными.
4. **Пересчитывать только изменённый участок.** После правки инвалидировать видимый изменённый диапазон и минимальный структурный контекст вокруг него. Стили, изображения и геометрию вне этого диапазона сохранять. Не вызывать восстановление и полную `invalidateMarkdownLayout` для всего документа без доказанной необходимости.
5. **Убрать постоянные расходы на каждой клавише.** Считать их высокими по результатам замеров. Объединить или отложить независимые задачи ввода (подсветка, delimiter matching, линейка, подсказки, AI и синхронизация), сохранив отмену и проверки ревизии. Не отключать функции постоянно и не вводить новый режим документа.
6. **Оптимизировать `applyVisible` и закрыть два визуальных дефекта.** Ограничить `unstyledRange`, сортировку `styledRanges`, восстановление стилей и `ensureLayout` локальным диапазоном. В том же цикле исправить подтверждённую ветку пропадающего пробела и фон диаграмм в тёмной теме: отдельно проверить flow/sequence и Mermaid, передать тему legacy-сервису и задать согласованный фон Mermaid.

После каждого пункта повторять контрольные сценарии: две быстрые клавиши перед картинкой, правка у границы Markdown, четыре варианта пробела, flow/sequence и Mermaid в тёмной теме. Результаты и новые ограничения заносить в журнал ниже.

### Уточнение — отключённое оформление

При `isMarkdownFormatted == false` `EditorCoordinator` больше не включает `elementPathEnabled`. Это предотвращает отдельный полный Markdown-разбор на каждую правку в исходном режиме. Путь элемента в строке состояния теперь обновляется только в оформленном представлении.

### Сравнение тормозов source mode и formatted mode

Два независимых прохода Claude и Grok подтвердили разницу архитектуры. Правая панель `MarkdownPreview` получает уже синхронизированный `document.text`, ждёт ревизию и задержку 0,18 секунды, разбирает Markdown в `MarkdownRenderActor` вне главного потока и передаёт готовую HTML-страницу WebKit ([MainWindowView.swift:451](../../LacEditor/Views/MainWindowView.swift#L451), [MarkdownPreview.swift:485](../../LacEditor/Preview/MarkdownPreview.swift#L485), [MarkdownPreview.swift:528](../../LacEditor/Preview/MarkdownPreview.swift#L528)). Она не меняет глифы и диапазоны того же `NSTextStorage`, куда приходит клавиатурный ввод.

В обоих режимах остаются общие расходы главного потока: `LogicalLineIndex.applyEdit`, публикация `selectionRange`/`cursorColumn` с последующим `updateNSView`, повторная раскладка строки каретки в `scheduleSelectionVisibilitySync`, подсветка, синхронизация модели и линейка ([EditorCoordinator.swift:3865](../../LacEditor/Editor/EditorCoordinator.swift#L3865), [EditorCoordinator.swift:3967](../../LacEditor/Editor/EditorCoordinator.swift#L3967), [LogicalLineIndex.swift:68](../../LacEditor/Editor/LogicalLineIndex.swift#L68)).

В formatted-режиме добавляются подтверждённые чтением расходы:

- копия всего `NSTextStorage` при проверке проекции изображений до вставки и ещё одна при переводе диапазона после смены выделения ([EditorCoordinator.swift:4131](../../LacEditor/Editor/EditorCoordinator.swift#L4131), [EditorCoordinator.swift:4902](../../LacEditor/Editor/EditorCoordinator.swift#L4902));
- сдвиг диапазонов `MarkdownPresentation` и `FoldLayoutManager` правее правки ([MarkdownPresentation.swift:1191](../../LacEditor/Models/MarkdownPresentation.swift#L1191), [FoldLayoutManager.swift:1800](../../LacEditor/Editor/FoldLayoutManager.swift#L1800));
- повторная проверка скрытых маркеров, replacements, изображений и контейнеров при генерации глифов и обновлении inline selection ([FoldLayoutManager.swift:1958](../../LacEditor/Editor/FoldLayoutManager.swift#L1958), [FoldLayoutManager.swift:2240](../../LacEditor/Editor/FoldLayoutManager.swift#L2240)).

Отдельно нужно измерить конец документа и середину длинного документа: в конце хвост сдвига мал, а в середине цена сдвига растёт с числом элементов справа. Полный cmark-разбор через 0,6 секунды и WebKit-предпросмотр не считать причиной задержки каждой буквы, пока замер не покажет обратное.

Следующий минимальный замер: один и тот же документ, оформление OFF/ON, курсор в конце и в середине; отдельно измерить `shouldChangeText`, `beforeEdit`, `textViewDidChangeSelection`, `scheduleSelectionVisibilitySync`, `updateNSView`, копии `as String`, `shouldGenerateGlyphs` и оба сдвига диапазонов. Только после этого менять код.

### Исследование вспышки полного текста изображения при OFF

Claude и Grok независимо подтвердили порядок:

1. `synchronizeMarkdownImageProjection` восстанавливает полный исходный Markdown в `NSTextStorage` при переходе из formatted mode в source mode ([EditorCoordinator.swift:2241](../../LacEditor/Editor/EditorCoordinator.swift#L2241)).
2. `MarkdownPresentationController.update(enabled: false)` синхронно вызывает `clear()`, снимая скрытые глифы и оформленные изображения ([MarkdownPresentationController.swift:517](../../LacEditor/Editor/MarkdownPresentationController.swift#L517), [MarkdownPresentationController.swift:1771](../../LacEditor/Editor/MarkdownPresentationController.swift#L1771)).
3. `scheduleAutomaticMediaFolds` только ставит задачу с паузой 80 мс, после чего в фоне ищет Base64 и возвращает диапазоны ([EditorCoordinator.swift:5233](../../LacEditor/Editor/EditorCoordinator.swift#L5233)).
4. До завершения этой задачи `automaticMediaFoldedRanges` пуст, поэтому первая отрисовка показывает полный `![...](data:image...;base64,...)`. После установки диапазонов вызывается полная раскладка, и строка сворачивается.

Это отличается от обычного открытия source mode тем, что при OFF окно уже отображается: сначала виден старый оформленный вид, затем полный исходник, затем позднее свёрнутый исходник. Текст, dirty state и undo при этом не меняются.

Минимальная точка исправления — переход из projection в source mode: применить media-fold диапазоны до первой отрисовки, не меняя текст и не трогая IME, каретку внутри payload, `DocumentFeatureOverrides.folding == false` и большой профиль. Нельзя просто убрать задержку для всех вводов: 80 мс нужна для обычного набора. Перед исправлением добавить тесты «сразу после OFF» и «после задачи», а также отдельно проверить payload 300 и 20 000 символов.

### Исследование хранения изображений и тормозов набора

Claude и Grok проверили текущую архитектуру. Правая `MarkdownPreview` не является доказательством того, что изображения можно без риска убрать из редактора: она получает синхронизированный `document.text`, разбирает его вне главного потока и рисует отдельный WebKit-документ. Редактор же должен одновременно поддерживать живой `NSTextStorage`, UTF-16-выделение, undo, IME, таблицы, поиск, копирование и сохранение.

Подтверждённые причины остающейся медленной клавиши:

- общие для source и formatted расходы: публикация `cursorColumn`/`selectionRange` с повторным `updateNSView`, `LogicalLineIndex.applyEdit`, TextKit-раскладка строки, `scrollRangeToVisible`, подсветка, модель и линейка;
- дополнительные для formatted: копии строки при проверке projection, сдвиг диапазонов `MarkdownPresentation`/`FoldLayoutManager`, поиск скрытых глифов и локальная раскладка оформленного блока;
- дополнительные для source: поиск и раскладка больших `data:image` через `FoldService`, включая полный `ensureLayout` после изменения списка folds.

Полную замену текста изображения на идентификатор во всех режимах вводить нельзя: source mode редактирует исходный Markdown, а десятки путей используют его реальные UTF-16 диапазоны. Уже существующая `MarkdownDataImageProjection` в formatted mode показывает риски: замена идёт мимо обычной undo-операции, выделение и поиск переводятся по позиционным токенам, таблицы и copy требуют восстановления, а IME должен никогда не получить токен вместо исходника.

Безопасный порядок исправлений:

1. На Mac измерить одинаковый документ с картинками и без них в source/formatted, в начале/середине/конце; отдельно поставить signpost вокруг `updateNSView`, `applyWritingChecks`, `updateCursor`, снимков текста, `ensureLayout`, `shouldGenerateGlyphs` и установки оформления.
2. Закрыть корректность существующей projection: undo, IME, copy, таблицы, дубликаты токенов и восстановление исходника. Не снижать порог и не расширять projection до этого.
3. Исправить source → formatted по аналогии с OFF → source: не оставлять окно между снятием старого слоя и установкой нового оформления; применять готовую presentation/проекцию до первой отрисовки, сохраняя условия IME и большого профиля.
4. Убрать общие расходы source mode: не запускать поиск `data:image` без изменения текста, не делать лишние копии и не публиковать состояние курсора чаще одного раза за клавишу.
5. Уменьшить formatted-specific расходы: копировать текст для projection только при непустых токенах, сдвигать только необходимый хвост и ограничивать глифы/раскладку изменённым окном.
6. Только если измерения покажут, что размер изображения остаётся главным фактором, рассмотреть стабильные идентификаторы внутри formatted projection. Они должны иметь карту позиций, безопасный undo/restore и отдельные проверки для IME, таблиц, копирования и повторяющихся изображений. Исходный файл и его формат не менять.

До этих измерений не считать замену изображений идентификаторами решением: по текущему коду большая часть общей задержки не связана с картинками.

## План ускорения обоих режимов

Цель — уменьшить задержку на главном потоке в исходном и оформленном редакторе, сохранив поведение документов, отмену, подсветку и фоновые проверки.

1. **Зафиксировать четыре базовых сценария.** Один и тот же документ без картинок и с картинками; курсор в конце и в середине; оформление OFF и ON. Для каждого снять время одной клавиши и отдельно отметить `shouldChangeText`, `textDidChange`, `textViewDidChangeSelection`, `updateNSView`, `scheduleSelectionVisibilitySync`, `updateCursor`, `LogicalLineIndex.applyEdit` и `refreshFoldLayout`.

2. **Сначала убрать общий тормоз source mode.** Проверить синхронную публикацию `cursorColumn`/`selectionRange` и повторный `updateNSView`; объединить обновление состояния курсора с уже существующей отложенной синхронизацией, если это не меняет видимое поведение. Проверить двойную TextKit-раскладку строки и линейку. `LogicalLineIndex` менять только после замера его доли.

3. **Отложить работу, которую следующая клавиша отменит.** Снимки текста для delimiter matching, автоматических media folds и других подсказок должны создаваться после паузы, а не до неё. Для каждого задания сохранить отмену и проверку ревизии. Не отключать функции навсегда и не вводить новый режим.

4. **Сократить дополнительную цену formatted mode.** Не делать копию всего `NSTextStorage`, если проекция больших `data:image` не содержит токенов. Для обычной правки сдвигать только нужные диапазоны; `removeTouched` и локальный `invalidateMarkdownLayout` не должны проходить весь документ без подтверждённой зависимости.

5. **Разделить конец и середину документа.** Исправить и проверить отдельный путь правки в конце документа, затем измерить сдвиг хвоста в середине длинного документа. Не считать одну оптимизацию достаточной для обоих случаев: у них разные расходы.

6. **Ограничить TextKit-перерасчёт.** `updateMarkdownInlineSelection`, `shouldGenerateGlyphs`, `applyVisible`, `unstyledRange`, восстановление стилей и `ensureLayout` должны работать только с изменённой строкой, видимой областью или минимальным структурным окном. Полную раскладку оставлять только для доказанной смены геометрии всего документа.

7. **Проверить отложенные подсистемы после горячего пути.** После ускорения главного потока отдельно измерить подсветку, синхронизацию модели, автосворачивание и Markdown-разбор. Они не должны блокировать ввод; если задержка появляется после паузы, исправлять её отдельным этапом.

8. **Приёмка.** После каждого пункта сравнивать OFF/ON, конец/середину, короткий/длинный документ, документ с картинками и без них. Отдельно убедиться, что правая `MarkdownPreview` остаётся независимой, изображения не перезагружаются, пробелы и диаграммы не регрессируют. Результаты каждого изменения заносить в журнал.

### Интернет-сравнение редакторов: изображения и диаграммы

Claude и Grok по очереди проверили официальные документы и исходники Typora, Obsidian, MarkText/Muya, VS Code, Zettlr и FSNotes. Ниже отделены подтверждённые приёмы от вывода для LacEditor.

**Что делают другие редакторы.**

- **Obsidian и Zettlr** оставляют Markdown источником истины, а оформление показывают декорацией или виджетом поверх диапазона. Неизменённый текст не заменяется HTML-картинкой.
- **VS Code** держит текстовый документ отдельно от HTML-просмотра. Preview обновляется с задержкой, одинаковые DOM-узлы сохраняются, размеры изображений кэшируются. Для диаграмм старый результат остаётся до готовности нового, устаревший рендер отменяется.
- **Zettlr** кэширует высоту уже показанных изображений. Mermaid-виджет повторно рисуется только при изменении текста схемы, границ блока или темы; сам рендер асинхронный.
- **FSNotes** ближе всего к TextKit 1: подсветка ограничивается абзацем вокруг правки, изображения загружаются только в затронутом диапазоне, а раскладка допускает непрерывную обработку только нужных участков. Предпросмотр диаграмм находится в отдельном `WKWebView`.
- **MarkText/Muya** использует дерево блоков и отдельную историю. Это даёт локальные блоковые обновления, но меняет модель документа и может нормализовать исходный Markdown. Такой переход для LacEditor не является малой оптимизацией.
- В проверенных источниках **Graphviz/DOT не выделен как отдельный встроенный путь**. Ближайшие аналоги — Mermaid, а у Muya ещё Vega и PlantUML. Для Graphviz, если он будет добавлен, подходит тот же ключ кэша: текст блока плюс тема.

Источники: [Obsidian decorations](https://docs.obsidian.md/Plugins/Editor/Decorations), [Obsidian viewport](https://docs.obsidian.md/Plugins/Editor/Viewport), [VS Code Markdown preview](https://github.com/microsoft/vscode/blob/main/extensions/markdown-language-features/src/preview/preview.ts), [VS Code preview DOM](https://github.com/microsoft/vscode/blob/main/extensions/markdown-language-features/preview-src/index.ts), [Zettlr image renderer](https://github.com/Zettlr/Zettlr/blob/develop/source/common/modules/markdown-editor/renderers/render-images.ts), [Zettlr Mermaid renderer](https://github.com/Zettlr/Zettlr/blob/develop/source/common/modules/markdown-editor/renderers/render-mermaid.ts), [FSNotes text processing](https://github.com/glushchenko/fsnotes/blob/master/FSNotesCore/TextStorageProcessor.swift), [Muya architecture](https://github.com/marktext/muya).

**Решение, добавляемое в текущий план.**

9. **Сохранить исходный Markdown единственным источником истины.** Не заменять изображения, диаграммы или их длинные `data:image` в общем `NSTextStorage` идентификаторами и не переносить документ в DOM/дерево блоков. В оформленном режиме продолжать использовать существующий слой проекции поверх текста; исходный режим, undo, IME, поиск, копирование, таблицы и сохранение должны видеть исходный Markdown.
10. **Сделать медиа локальными видимыми объектами.** Для изображения хранить вне строки кэш «стабильный ключ ресурса → декодированная картинка и размеры». Пересчитывать и менять вид только для изменённого или видимого диапазона. Неизменённая картинка должна оставаться на экране и только сдвигаться вместе с диапазоном.
11. **Сделать диаграммы асинхронными и повторяемыми по ключу.** Ключ — текст блока, границы блока и тема. Пока рендер идёт, сохранять старую диаграмму или заглушку с прежней высотой; новый результат применять только если его ревизия ещё актуальна. Устаревшие задания отменять. Для тёмной темы передавать тему в каждый рендерер и задавать фон диаграммы явно, а не полагаться на белый фон WebView.
12. **Не расширять пересчёт из-за самого наличия картинки.** В source mode не запускать поиск и раскладку `data:image`, если текст не менялся или правка не затронула соответствующий диапазон. В formatted mode не пересобирать все изображения и диаграммы при обычной правке; сдвигать только упорядоченный хвост и инвалидировать минимальное структурное окно.
13. **Оставить замену длинных изображений идентификатором условной оптимизацией.** Сначала выполнить замеры и проверки существующей `MarkdownDataImageProjection` для undo, IME, копирования, таблиц, дубликатов и восстановления исходника. Только если после локального кэша и ограничения раскладки размер `data:image` остаётся главным расходом, рассмотреть стабильную карту токенов внутри formatted projection. Это не должно менять сохранённый файл и не должно появляться в source mode.
14. **Добавить приёмку для медиа и диаграмм.** Проверять OFF/ON, начало/середину/конец документа, неизменённую картинку перед курсором, две быстрые клавиши, пробелы, переключение темы, Mermaid и legacy flow/sequence. Отдельно проверить, что до завершения рендера нет вспышки исходного текста изображения и что после переключения режима картинка не раскрывается на время.

Это дополнение уточняет пункты 2, 3, 4, 6 и 8 текущего плана. Большая смена на DOM, Muya-подобное дерево или новый редактор остаётся за пределами согласованной доработки.

## План доработки кода с учётом Linux

Цель — выполнять безопасную часть разработки и автоматических проверок в Linux, не выдавая её за проверку macOS-интерфейса. Кодовые изменения начинаются только после отдельного согласования этого плана.

### Этап 1. Зафиксировать базу и границы

1. Проверить `git status` и сохранить все чужие незакоммиченные изменения.
2. Перед изменением прочитать правила областей `editing.md`, `markdown-editor.md`, `markdown-html-media.md`, `performance.md` и `testing.md`.
3. Подготовить матрицу замеров на macOS: source/formatted × картинка есть/нет × курсор в начале/середине/конце × короткий/длинный документ. До этих замеров не считать вклад отдельных расходов подтверждённым.
4. Не менять модель TextKit 1, формат сохранения и содержимое `EditorDocument`; существующую отображаемую проекцию не расширять без отдельной проверки undo, IME, поиска, копирования и таблиц.

**Проверка в Linux:** `git diff --check`, чтение diff и доступные синтаксические проверки. XCTest проекта и тесты, импортирующие AppKit/WebKit, на Linux не обещать: Mac-профилирование и GUI-приёмка здесь недоступны.

### Этап 2. Убрать лишнюю работу в source mode

1. Не запускать поиск `data:image` и полный `ensureLayout` на каждую клавишу. Однократный поиск готовых media-fold при переходе formatted → source сохранять; смена каретки, активности вкладки и настроек должна переиспользовать уже найденные диапазоны.
2. Проверить, что отключённое оформление не вызывает пересчёт оформления или публикацию `elementPath`.
3. Объединить только уже существующие обновления курсора, линейки и состояния, если это не меняет видимое поведение.
4. Сохранять отмену, проверку версии и защиту marked text.

**Проверка в Linux:** только доступные чистые проверки и чтение путей; XCTest, зависящие от приложения, запускать только на macOS. Фактическую задержку клавиши и отсутствие повторного оформления подтвердить профилированием на macOS.

### Этап 3. Сократить formatted mode локальными изменениями

1. Проверить уже сделанный быстрый путь: при правке вне медиа переносить существующие диапазоны и объекты изображений, не пересоздавая их.
2. Не сужать подсветку и структурную инвалидацию механически до абзаца: многострочная конструкция может затронуть хвост документа. Сохранять `clear()` только в документированных случаях, а полную `restoreStyles()` менять только после замера.
3. Проверить уже сделанную проверку `entries.isEmpty` перед копированием текста для `MarkdownDataImageProjection`; не объявлять её новой до Mac-проверки.
4. Не заменять длинный `data:image` идентификатором во всём редакторе. Возможность стабильной карты токенов оставить только как отдельный этап после замеров и проверок undo/IME/copy/таблиц.

**Проверка в Linux:** чтение и синтаксическая проверка чистых участков, если они доступны без AppKit. Корректность существующей проекции, реальный курсор, выделение, undo и IME проверять на macOS; перенос приватной проекции в новый модуль для Linux без отдельного разрешения не делать.

### Этап 4. Изображения и диаграммы

1. Проверить существующие кэши изображения и диаграмм: ключ ресурса хранить отдельно от позиции в тексте, а неизменённый объект только сдвигать. Новый внешний кэш не добавлять без замера.
2. Для диаграмм сохранять существующий ключ `вид + текст + ширина + тема`; диапазон символов в ключ не включать. Устаревшие результаты отбрасывать проверками документа, ревизии, поколения и видимости.
3. Если старая диаграмма уже была, оставлять её до готовности новой; для первой отрисовки использовать существующую заглушку, не выдумывая высоту.
4. Исправить только подтверждённые пути Mermaid и legacy flow/sequence: передавать тему и явно согласовать фон со светлой и тёмной палитрой.
5. Для formatted → source применять готовые media-fold до первой отрисовки. Для source → formatted не выполнять синхронный полный разбор на главном потоке: сохранять предыдущий вид до готового разбора либо отдельно зафиксировать принятое краткое ограничение.

**Проверка в Linux:** `node --check` и чтение ключей/проверок ревизий; это не подтверждает отображение. WebKit, TextKit, цвет фона и отсутствие вспышки подтвердить только на macOS.

### Этап 5. Приёмка и порядок запуска

1. После каждого изменения запускать доступные Linux-проверки затронутой области и `git diff --check`.
2. `swift build` и `swift test` на Linux запускать не как обязательный зелёный критерий: в текущем проекте цель связана с AppKit/WebKit, а ранее уже была ошибка `Vendor/TreeSitterYAML`. Зафиксировать фактический отказ один раз; не менять Vendor, Package.swift или добавлять Linux-цель в рамках этой задачи.
3. На macOS выполнить `sh Scripts/prepare-pandoc.sh`, `swift build`, `swift build -c release`, `swift test`, затем относящиеся к задаче GUI/acceptance-проверки.
4. На macOS повторить матрицу замеров и сценарии: две быстрые клавиши перед изображением, удаление, Enter, ввод вне видимой области, четыре варианта пробела, две одинаковые картинки, каретка внутри Base64, переключение OFF/ON в обе стороны, IME, Mermaid, flow/sequence, ширина и светлая/тёмная тема.
5. Каждое изменение и результат проверки заносить в этот файл. До успешной macOS-приёмки считать Linux-результат только предварительной проверкой.

### Ограничения Linux

Linux используется для чтения кода, изменения чистых компонентов и синтаксических проверок. В этом проекте XCTest приложения импортируют AppKit/WebKit, а приватная проекция находится внутри `EditorCoordinator`; отдельный Linux-тестовый модуль или перенос кода для этого плана не добавлять. Отказ `swift build`/`swift test` фиксировать как ограничение среды, а не как успешную проверку. Linux не подтверждает работу `NSTextView`, `NSTextStorage`, `NSLayoutManager`, системного IME, `WKWebView`, реального отображения диаграмм и задержку клавиатурного ввода.

### Ревью плана Claude и Grok — 2026-11-01

Оба ревьюера независимо указали, что первоначальный Linux-план нельзя было брать в реализацию без уточнений. Основные исправления внесены выше.

- Уже сделанные изменения не считаются новыми этапами: отложенный media-fold, отложенное обновление курсора, проверка пустой проекции, перенос готовых медиа и локальный быстрый путь нужно проверить на macOS, а не реализовывать повторно.
- Linux не является рабочей платформой для XCTest приложения: тестовая цель и большая часть исходников зависят от AppKit/WebKit, а `MarkdownDataImageProjection` приватна внутри `EditorCoordinator.swift`. Новый Linux-модуль, перенос приватного кода и правка Vendor в этот план не входят.
- Ключ диаграммы не должен включать диапазон символов: положение хранится отдельно и меняется при сдвиге. Сохраняется ключ `вид + текст + ширина + тема`.
- Переход formatted → source и переход source → formatted разделены. Для первого используется готовый media-fold до первой отрисовки; для второго нельзя добавлять синхронный полный разбор на главном потоке.
- Перед реализацией обязательны macOS-проверки существующей проекции: undo/redo после OFF/ON, IME, UTF-16 с emoji, копирование, поиск, таблицы, повторяющиеся картинки и сохранение исходного Markdown.
- Открытыми остаются фактическая цена сдвига хвоста, правки в начале/середине/конце, удаление, Enter, ввод вне видимой области, четыре варианта пробела, режим чтения и смена темы/ширины диаграмм.

Ревью Claude: `/tmp/laceditor-plan-review-claude.txt`. Ревью Grok: `/tmp/laceditor-plan-review-grok.txt`. Оба прохода завершены штатно; файлы проекта ревьюеры не изменяли.

### 2026-11-01 — первый этап ускорения обоих режимов

- Claude изменил общий путь обновления курсора и линейки для набора, отложил лишнюю раскладку автосворачивания, сократил копии `data:image` без токенов, добавил локальные окна для упорядоченных диапазонов и двоичный поиск рядом с правкой.
- Самостоятельная проверка: `git diff --check`, `node --check` для ранее изменённого `host.js`, Swift parse изменённых Swift-файлов кроме уже существующего Swift 6.2 `isolated deinit` в `EditorCoordinator.swift`.
- `swift build` в Linux остановился на существующей ошибке `Vendor/TreeSitterYAML` (`int8_t`/`int32_t` без определения). XCTest, macOS GUI и Instruments не запускались.
- При проверке исправлена ошибка сравнения автосворачивания: полная раскладка сравнивает сами диапазоны, а не только их длины.
- До Mac-проверки остаются риски вокруг удаления, Enter, ввода вне видимой области и фактической цены сдвига длинного хвоста.

Для каждого будущего изменения добавлять запись:

```text
### YYYY-MM-DD — краткое название
- Симптом и минимальный воспроизводимый сценарий.
- Найденная причина с файлами и строками.
- Изменённый путь и почему он не затрагивает остальные пути.
- Проверки и их результат.
- Оставшиеся ограничения.
```

