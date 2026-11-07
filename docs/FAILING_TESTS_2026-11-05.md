# Падающие тесты LacEditor

Последний полный прогон Xcode: **3904 теста, 3727 passed, 165 failed, 11 skipped, 1 not run**.
Источник полного отчёта: временный `RunAllTests` summary от 2026-11-05.

## Текущий targeted-чек-лист

Обновление 2026-11-07:

- [x] Устранить ошибки Mac-компиляции новых тестов и конфликт двух ресурсов
  `tables.md`; `BuildProject(buildForTesting: true)` проходит.
- [x] Устранить предупреждения компиляции; актуальный `GetBuildLog` — 0.
- [x] Выполнить один непрерывный полный `RunAllTests` без прерывания.
- [ ] Получить закрытый итоговый `.xcresult`: последний запуск завершил
  тестовый процесс, но bundle остался неполным; Issue Navigator содержит 519
  свежих test issues без общей сводки.
- [ ] Разобрать `MarkdownRendererTests` как первый крупный кластер после
  завершённого полного запуска: targeted-прогон — 78/103 passed, 25 failed;
  локализована общая группа raw HTML/media/source ranges, исправление ещё не
  внесено.
- [ ] Устранить runtime warnings UI-тестов (блокирующий вызов на main thread)
  и AVKit constraints.
- [ ] Повторить полный прогон после устранения известных кластеров.

Последняя проверка `MarkdownAudioInteractionTests`: **25/28 passed, 3 failed**.

- [ ] `MarkdownAudioInteractionTests/testLocalAndRemoteSVGUseImageContextWithoutEditingSource()` — remote SVG callback не завершает ожидание.
- [ ] `MarkdownAudioInteractionTests/testQuoteAndListMediaUseConfirmedContainerLines()` — quote/list media не подтверждается parser-ом.
- [ ] `MarkdownAudioInteractionTests/testVerticalIframeKeepsPhysicalSizeAndRevealsSource()` — физическая ширина `160` вместо `180`; раскрытие источника также требует проверки после исправления геометрии.

## Полный прогон: список по наборам

Ниже перечислены все наборы, содержащие падения в последнем полном прогоне. Точные идентификаторы сохранены в исходном Xcode summary; после каждого исправления набор нужно запускать targeted-прогоном.

- `FolderOpeningTests`: `testCancelledExtremeFileDoesNotSetParentFolder()`
- `MarkdownAudioInteractionTests`: 8 падений в исходном полном прогоне; часть уже исправлена, актуальный список см. выше.
- `MarkdownClipboardInteractionTests`: 3 падения (сохранение изображения, RTF paste/undo и отмена paste).
- `MarkdownFootnoteTests`: `testReferencePositionsAndDefinitionAssociation()`
- `MarkdownImageCopyTests`: 3 падения (undo/selection, deduplication, partial copy).
- `MarkdownImageEditingTests`: `testRootPathEditPreservesYAMLSourceAndAnchorSemantics()`
- `MarkdownImageInteractionTests`: 2 падения (HTML percentage resize, zero-sized HTML image in table).
- `MarkdownImageUploadTests`: `testSharedReferenceUploadUsesOneEditorUndo()`
- `MarkdownLayoutTests`: 37 падений (continuation tabs, math pair, tasks, headings, tables, RTL, alignment, details, images, links и layout cache).
- `MarkdownLinkNavigationInteractionTests`: 4 падения.
- `MarkdownLinkNavigationOpenTests`: `testNamedAnchorNavigationUsesCurrentSourceAndHeadingPriority()`
- `MarkdownListStyleTests`: `testDecimalAndAlphabeticStyles()`
- `MarkdownMathExtensionTests`: `testSmartPunctuationUsesSnapshotWithoutChangingSource()`
- `MarkdownMediaIntegrationTests`: 3 падения.
- `MarkdownNativeGeneratedBlockTests`: 6 падений.
- `MarkdownNativeTableInteractionTests`: 5 падений.
- `MarkdownPDFExportTests`: 13 падений.
- `MarkdownPresentationParserTests`: 1 падение.
- `MarkdownPresentationTests`: 7 падений.
- `MarkdownPreviewTests`: 4 падения.
- `MarkdownRendererTests`: 18 падений.
- `MarkdownRubyOutputTests`: 1 падение.
- `MarkdownRubyRenderServiceTests`: 1 падение.
- `MarkdownWidthTests`: 31 падение.
- `MarkdownWikiLinkResolverTests`: 1 падение.
- `NativeTabsTests`: 1 падение.
- `PandocExportTests`: 6 падений.
- `PandocImportTests`: 2 падения.
- `UIAuditTests`: 1 падение.
- `UIExperimentTests`: 1 падение.
- `WindowAndSessionTests`: 3 падения.
- `WritingModesTests`: 1 падение.
- `MarkdownFormattingUITests`: 2 падения.

## Правило обновления

После каждого полного прогона обновлять числа в этом файле и переносить исправленные тесты из чек-листа в раздел «Исправлено». Не считать тест исправленным по одному успешному запуску, если полный прогон ещё не подтверждён.
