# Падающие тесты macOS — 2026-11-07

## Источники и полнота

- Полный `RunAllTests` завершил тестовый процесс, но Xcode оставил
  незавершённый `.xcresult`. Итоговый отчёт с полным перечнем test cases
  прочитать нельзя.
- Issue Navigator сохранил 481 свежую assertion-ошибку в файлах тестов, но API
  возвращает только первые 100 записей. Повторные assertions одного test case
  объединены ниже.
- `MarkdownRendererTests` после этого выполнен отдельным завершённым запуском:
  103 теста, 78 passed, 25 failed. Поэтому раздел renderer является полным для
  этого targeted-прогона.
- Прерванный запуск `MarkdownDocumentParserHTMLTests` в этот список не входит.

## Полный targeted-прогон `MarkdownRendererTests`: 25 failed

- [ ] `testUnicodeImagePathsAndSelectorsStayByteDistinctInRenderedBody` — два
  `XCTAssertTrue failed` (строки 296–297).
- [ ] `testNamedAnchorConfirmsTabbedSourcePositions` — `XCTAssertTrue failed`
  (строка 450).
- [ ] `testRenderedHTMLImagesUseSafeSizingAndKeepOtherHTMLDisabled` —
  `XCTAssertFalse failed` и три `XCTAssertTrue failed` (557, 585–587).
- [ ] `testLocalSVGIsEmbeddedInRenderedPreview` — `XCTAssertTrue failed` (613).
- [ ] `testExportKeepsConfirmedImageWhenAnotherHasUnmappedTab` —
  `XCTAssertFalse failed` (702).
- [ ] `testExportRendersUnquotedImageAttributes` — четыре `XCTAssertTrue failed`
  и `XCTAssertFalse failed` (714–718).
- [ ] `testExportRendersCaseInsensitiveImageAttributes` — `XCTAssertTrue failed`
  и `XCTAssertFalse failed` (723–724).
- [ ] `testExportPreservesEmptyImageAlt` — `XCTAssertTrue failed` и
  `XCTAssertFalse failed` (729–730).
- [ ] `testExportDecodesHTMLImageAttributeEntities` — три `XCTAssertTrue failed`
  и `XCTAssertFalse failed` (736–739).
- [ ] `testPreviewKeepsConfirmedInlineAndNestedMediaWithSurroundingText` — raw
  HTML заменён на `<!-- raw HTML omitted -->`; число найденных элементов `0`
  вместо `1`; дополнительные `XCTAssertTrue failed` (768–831).
- [ ] `testPlainHTMLPreservesCanonicalMediaAndUnknownRawAttributes` — вместо
  ожидаемого `<audio controls>…</audio>` получены внутренние `LACRAW`-маркеры
  (855–856).
- [ ] `testPlainHTMLKeepsInlineMediaSourceOnce` — массив содержит только
  `<video>` и `</video>`, отсутствует ожидаемый `<source …>` (892).
- [ ] `testMultilineMediaOpeningRendersLikeSingleLineTag` — многострочные
  `video`/`audio` не совпадают с каноническим HTML; raw opening остаётся в
  списке неподтверждённых (905–914).
- [ ] `testMultilineMediaOpeningWithoutProofStaysUnconfirmed` — несколько
  `XCTAssertFalse failed` для quote/template/script-контекстов (928).
- [ ] `testPlainHTMLUsesCanonicalRecognizedWidgets` — Twitter widget заменён
  `LACRAW`-маркером вместо канонического `blockquote` (941–942).
- [ ] `testExportPreservesConfirmedInlineHTMLOutsideScripts` — подтверждённый
  inline HTML не сохранён: `XCTAssertFalse/True failed` (988–991).
- [ ] `testSharedInlineHTMLPairsRenderInPreviewAndExport` —
  `XCTAssertFalse failed` (1007).
- [ ] `testStyledSpansInTableUseCellSourcePositions` — два
  `XCTAssertFalse failed` (1069, 1072).
- [ ] `testUnsupportedMultilineStyleInQuoteAndListKeepsPrefixes` — не
  сохранились ожидаемые префиксы quote/list для LF и CRLF (1132).
- [ ] `testUnsupportedInlineStyleDoesNotFetchImage` — `XCTAssertTrue failed`
  (1177).
- [ ] `testUnstyledExportPreservesPairedInlineHTMLLink` —
  `XCTAssertTrue failed` (1199).
- [ ] `testExportAudioRequiresConfirmedRawHTMLContext` —
  `XCTAssertTrue failed` (1215).
- [ ] `testExportPreservesPairedAudioWithoutFallbackText` — paired audio не
  совпал с ожидаемым экспортом.
- [ ] `testExportPreservesStandaloneVideoOutsideScript` — standalone video не
  сохранён в ожидаемом виде.
- [ ] `testExportIncludesOnlyConfirmedSandboxedIframe` — набор подтверждённых
  sandboxed iframe не совпал с ожидаемым.

## Другие test cases из Issue Navigator

Ниже перечислены уникальные test cases, видимые в первых 100 из 481 свежих
assertion-ошибок полного прогона. Этот раздел заведомо неполон до получения
нового штатного `RunAllTests` с читаемым `.xcresult`.

### Разбор и модель Markdown

- [ ] `MarkdownDisplayMapTests/testTabsMultilineBackslashAndLinksNeverLoseBothSpanAndFlag` — marker не покрыт ни span, ни `unreliableRanges`.
- [ ] `MarkdownHTMLMediaServiceTests/testInlineAndNestedMediaUseExactSourceRanges` — получен 1 range вместо 2.
- [ ] `MarkdownLocalParseTests/testClosingFrontMatterLineFarFromStartFallsBack` — неверная причина fallback.
- [ ] `MarkdownLocalParseTests/testPlainEditInsideLongDocumentIsLocal` — локальный разбор отвергнут из-за узлов без подтверждённой позиции.
- [ ] `MarkdownLocalParseTests/testRandomEditsMatchFullParse` — 0 локальных правок вместо ожидаемых более 10.
- [ ] `MarkdownLocalParseTests/testRiskyEditsFallBackToFullParse` — неверные причины fallback для HTML и `$$`.
- [ ] `MarkdownLocalParseControllerTests/testFullParseCountGrowsOnlyOnInstalledFullParses` — счётчик 3 вместо 2; база помечена `fenceBlockedEOF`.
- [ ] `MarkdownLocalParseControllerTests/testModelIsPublishedOnlyAfterInstalledFullParse` — перед проверкой получен полный fallback `fenceBlockedEOF`.
- [ ] `MarkdownLocalParseControllerTests/testOptionChangeAndClearResetBase` — база не работает из-за `fenceBlockedEOF`.

### Layout, glyphs и caret

- [ ] `MarkdownCaretInteractionTests/testClickRightOfBoldAtLineEndPlacesCaretAfterClosingMarkers` — range `{8, 0}` вместо `{10, 0}`.
- [ ] `MarkdownHiddenGlyphStressTests/testLinesStartingWithHiddenMarkersKeepGeometryAndSelection` — ошибки hit testing, движения caret, ширины и скрытия glyph для CRLF/LF.
- [ ] `MarkdownHiddenGlyphStressTests/testOneDocumentInTwoWindowsKeepsIndependentGlyphState` — во втором окне скрыты markers.
- [ ] `MarkdownLayoutTests/testCodeFontUpdatesInlineAndBlockWithoutEditingSource` — остался `Menlo-Regular` вместо системного monospaced font.
- [ ] `MarkdownLayoutTests/testGlyphGenerationHidesOnlyVisibleImageRangesInsideBatch` — повторные `XCTAssertFalse failed`.
- [ ] `MarkdownLayoutTests/testHeadingNumberingRestoresSourceAndKeepsSetextUnderline` — координата `40.4578125` вместо `0`.
- [ ] `MarkdownLayoutTests/testListMarkerStylesFollowDeepScrollAndReset` — размер `16.8574` вместо `25.2861 ± 1`.
- [ ] `MarkdownLayoutTests/testPlainMultilineBodyTabUsesConfirmedGlyphAndReveal` — `XCTAssertFalse failed`.
- [ ] `MarkdownLayoutTests/testTableGeometryCacheResetsOnFontSpacingAndRTL` — отсутствует ожидаемый `CGRect`.
- [ ] `MarkdownLayoutTests/testTableGeometryCacheReusesRowForSameInputs` — отсутствует ожидаемый `CGRect`.
- [ ] `MarkdownLayoutTests/testTableOfContentsHitTestingDoesNotLayOutDistantMarkers` — 110023 laid-out positions при лимите 55011.
- [ ] `MarkdownLayoutTests/testUppercaseHeadingProjectionWrapsAndMapsGlyphHits` — неверные source offsets и flags переноса.
- [ ] `MarkdownLayoutTests/testUppercaseHeadingUsesResolvedEmoji` — ожидаемое значение `nil`.
- [ ] `MarkdownLayoutTests/testUppercaseHeadingWaitsForSuccessfulEmojiResolution` — timeout 5 секунд и пустой текст вместо исходного heading.
- [ ] `MarkdownLayoutTests/testVerticalUppercasePrototypeUsesAttachmentAndSourceCoordinates` — range `{0, 34}` вместо `{2, 6}` и неверный projected text.
- [ ] `MarkdownRevealLayoutTests/testRevealedSeparatorLineIsNotLowerThanTextLine` — интервал раскрытой строки равен 0/0.01 вместо ожидаемого.
- [ ] `MarkdownWidthTests/testMultilineHTMLImageWithTabLoadsAndRevealsSource` — image не загрузился; source заменён служебным `AA==#lac-media-…`.
- [ ] `MarkdownWidthTests/testMultilineMappedImageLoadsAndRevealsSource` — аналогичная подмена image source и `XCTAssertTrue failed`.
- [ ] `WritingModesTests/testSentenceFocusRectsSplitLinesAndKeepAttributes` — `XCTAssertFalse failed`.

### Редактирование, undo и таблицы

- [ ] `MarkdownBlockSourceTests/testImageEditSourceIsAbsentInReadingModeAndRejectedWhenStale` — не найдена позиция видимой картинки в reading mode.
- [ ] `MarkdownEditRoundTripTests/testRepeatingFormattingCommandRemovesRefusesOrKeepsAndNeverGrows` — разбор не завершён; undo count 1 вместо 2; undo возвращает текст неверной UTF-16 длины.
- [ ] `MarkdownNativeTableInteractionTests/testNestedTableGridClickAndEditingPreserveQuote` — `XCTAssertTrue failed`.
- [ ] `MarkdownNativeTableInteractionTests/testVirtualCellUndoKeepsEnclosingQuoteMarkers` — `XCTAssertTrue failed`.
- [ ] `MarkdownTableNavigationTests/testCommandDoesNotPadOtherCells` — отсутствует ожидаемый `MarkdownFormattingEdit`.
- [ ] `MarkdownTableNavigationTests/testUndoAfterCellEditAndStructuralCommandReturnsCaretToCell` — после undo ячейка остаётся открытой.
- [ ] `MarkdownUndoGroupTests/testEveryFormattingCommandIsOneUndoOnMultiParagraphSelection` — разбор Markdown не завершился.

### Ссылки, clipboard и изображения

- [ ] `MarkdownClipboardInteractionTests/testRTFImagePasteSavesChosenFileAndUndoesText` — после undo `before ` вместо `before user`.
- [ ] `MarkdownClipboardInteractionTests/testSavedImageNoticeFindsDocumentInAnotherWindowOnlyOnce` — status не получил путь `/tmp/image.png`.
- [ ] `MarkdownImageCopyTests/testCopyUsesOneUndoAndRejectsChangedSelectionAfterFolderChoice` — `XCTAssertTrue failed`.
- [ ] `MarkdownImageCopyTests/testMoveAllUsesOneUndoAndKeepsRemoteCopy` — `XCTAssertFalse failed`.
- [ ] `MarkdownLinkNavigationInteractionTests/testCommandClickNavigatesInBothViewsAndOrdinaryClickEdits` — `XCTAssertTrue failed`.
- [ ] `MarkdownLinkNavigationInteractionTests/testFileAnchorUsesExistingOpenDocument` — открыт document с другим UUID.
- [ ] `MarkdownLinkNavigationInteractionTests/testSelectionAwayAndBackRejectsDelayedParse` — отсутствует ожидаемый `Task<(), Never>`.
- [ ] `MarkdownLinkTableTests/testCommandClickInInactiveAndActiveCellNavigatesAndPreservesMarkedText` — неверные selection ranges и `XCTAssertTrue failed`.

### Preview, export, окна и UI

- [ ] `MarkdownPDFExportTests/testNativePDFUsesSnapshotAndLeavesDestinationUntouchedUntilInstall` — `XCTAssertTrue failed`.
- [ ] `MarkdownPDFExportTests/testPDFMathReferenceHasInternalDestinationAndRespectsPageRange` — `XCTAssertTrue failed`.
- [ ] `MarkdownPDFExportTests/testPageBreaksSeparateTopHeadingsAndFootnotes` — число page breaks `0`, ожидалось больше 0.
- [ ] `MarkdownPreviewTests/testPreviewRoutesExternalLinksWithOriginalAddresses` — получен пустой список вместо HTTP и mailto URL.
- [ ] `MarkdownPreviewTests/testScrollToEditorLineInterpolatesBetweenBlocks` — preview не достиг ожидаемой DOM-позиции.
- [ ] `PandocExportTests/testPandocEmbedsRootImageBytesForStandardAndProfileExports` — `XCTUnwrap` получил `nil` вместо `Substring`.
- [ ] `UIExperimentTests/testSettingsPresentationFinishesOriginatingEventAndReleasesClosedHost` — `XCTAssertTrue failed`.
- [ ] `WindowAndSessionTests/testFullHeightSidebarAndTabAccessorySurviveResizeAndNativeCollapse` — document update повторно открыл sidebar.

## Следующее обновление списка

После следующего штатного полного прогона этот файл нужно заменить полным
перечнем из `.xcresult`: один пункт на каждый failed test case, со всеми
сообщениями assertions, без runtime warnings и без дубликатов одного метода.
