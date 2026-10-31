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

`beforeEdit` сбрасывает разобранный результат, оглавление и читаемый текст, отменяет устаревшие операции. Если правка безопасна для быстрого пути, контроллер вызывает `presentationAfterEdit`, затем `shiftPresentation`: диапазоны презентации, подсветка кода, медиа и геометрия сдвигаются без полного разбора ([MarkdownPresentationController.swift:918](../../LacEditor/Editor/MarkdownPresentationController.swift#L918), [MarkdownPresentationController.swift:1822](../../LacEditor/Editor/MarkdownPresentationController.swift#L1822)). Небезопасная правка сразу снимает старое оформление.

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

Следующая клавиша не считается автоматически безопасной: если `keptEdit` не подтверждён текущим `edited`, старое оформление снимается. Это предотвращает накопление ошибочных диапазонов.

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

## План исправления

1. **Зафиксировать базовую точку.** Замеры уже подтвердили оба симптома: ввод тормозит, а готовое изображение временно заменяется исходным Markdown. Сохранить эти результаты и использовать их как критерий «до/после».
2. **Сохранить готовые изображения.** Вернуть быстрый путь через существующие media-only операции: при правке, не затрагивающей изображение, переносить его диапазон, view и ключ кэша. Не запускать повторную загрузку неизменившегося ресурса.
3. **Убрать полный `clear` из обычного продолжения ввода.** Вторая клавиша до нового разбора не должна снимать всё оформление. Полный сброс оставить только для правки, которая действительно меняет структуру элемента или делает старые диапазоны недействительными.
4. **Пересчитывать только изменённый участок.** После правки инвалидировать видимый изменённый диапазон и минимальный структурный контекст вокруг него. Стили, изображения и геометрию вне этого диапазона сохранять. Не вызывать восстановление и полную `invalidateMarkdownLayout` для всего документа без доказанной необходимости.
5. **Убрать постоянные расходы на каждой клавише.** Считать их высокими по результатам замеров. Объединить или отложить независимые задачи ввода (подсветка, delimiter matching, линейка, подсказки, AI и синхронизация), сохранив отмену и проверки ревизии. Не отключать функции постоянно и не вводить новый режим документа.
6. **Оптимизировать `applyVisible` и закрыть два визуальных дефекта.** Ограничить `unstyledRange`, сортировку `styledRanges`, восстановление стилей и `ensureLayout` локальным диапазоном. В том же цикле исправить подтверждённую ветку пропадающего пробела и фон диаграмм в тёмной теме: отдельно проверить flow/sequence и Mermaid, передать тему legacy-сервису и задать согласованный фон Mermaid.

После каждого пункта повторять контрольные сценарии: две быстрые клавиши перед картинкой, правка у границы Markdown, четыре варианта пробела, flow/sequence и Mermaid в тёмной теме. Результаты и новые ограничения заносить в журнал ниже.

Для каждого будущего изменения добавлять запись:

```text
### YYYY-MM-DD — краткое название
- Симптом и минимальный воспроизводимый сценарий.
- Найденная причина с файлами и строками.
- Изменённый путь и почему он не затрагивает остальные пути.
- Проверки и их результат.
- Оставшиеся ограничения.
```

