import Foundation

/// Результат одного разбора Markdown: описывает исходный текст, позиции — UTF-16 исходника.
/// Из модели два адаптера строят HTML предпросмотра и `MarkdownPresentation` редактора.
struct MarkdownDocumentModel: Equatable, Sendable {
    /// Что считать при разборе. Соответствует параметрам `wiki`, `critic`, `embeds` у `MarkdownHTMLRenderer.renderPage`.
    struct Includes: OptionSet, Equatable, Sendable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }
        /// `[[…]]` — узлы wiki-ссылок (`includeWikiLinks`; в предпросмотре — когда есть `wiki`).
        static let wikiLinks = Includes(rawValue: 1 << 0)
        /// `![[…]]` — узлы встраиваний (в предпросмотре — когда есть `embeds` или `wiki`).
        static let noteEmbeds = Includes(rawValue: 1 << 1)
        /// `{++ ++}`, `{-- --}`, `{~~ ~> ~~}`, `{>> <<}`, `{== ==}` (в предпросмотре — когда есть `critic`).
        static let criticMarkup = Includes(rawValue: 1 << 2)
        /// `emoji`: кандидаты `:имя:`, места автодополнения, участки умных замен (`includeEmojiCandidates`).
        static let emoji = Includes(rawValue: 1 << 3)
        /// `uppercaseRuns` у заголовков (`includeUppercaseRuns`).
        static let uppercaseRuns = Includes(rawValue: 1 << 4)
        /// `readableText` (`includeReadableText`).
        static let readableText = Includes(rawValue: 1 << 5)
        /// `elements`: индекс элементов для строки состояния.
        static let elementIndex = Includes(rawValue: 1 << 6)
        /// `blockIndex`: верхнеуровневые блоки для локального разбора (сегодня — колбэк `blocks:`).
        static let blockIndex = Includes(rawValue: 1 << 7)
        /// Данные только для TextKit: `smartReplacements`, `looseIndents`, `fence`.
        static let editorContext = Includes(rawValue: 1 << 8)
    }

    struct Options: Equatable, Sendable {
        /// `strictMode`, `inlineMath`, `legacyInlineMath`, `smartPunctuation` и правила пробелов задаёт `syntax`.
        var syntax: MarkdownSyntaxOptions
        var includes: Includes
        /// Заметка хранилища: `%%…%%` — комментарии (`hidesObsidianComments || appliesTo(documentURL:)`).
        var isVaultNote: Bool
        /// `detectsFrontMatter` у `parse`; у `renderPage` всегда `true`.
        var detectsFrontMatter: Bool
    }

    struct FrontMatter: Equatable, Sendable {
        /// От начала текста до конца закрывающей строки (без перевода строки).
        var range: NSRange
        /// Открывающий и закрывающий разделители (`---`, `---`/`...`).
        var markers: [NSRange]
    }

    /// Контекст для команд «Вставить блок кода»: куда нельзя ставить ограждение (поля `fence*` у `MarkdownPresentation`).
    struct FenceContext: Equatable, Sendable {
        var containerLines: [MarkdownFenceContainerLine]
        var blockedRanges: [NSRange]
        var blockedEOF: Bool
        var isAvailable: Bool
    }

    struct EmojiData: Equatable, Sendable {
        var candidates: [MarkdownEmojiCandidate]
        var completionRanges: [NSRange]
        var smartTextRanges: [NSRange]
        /// `nil` — границы сырого HTML подтвердить не удалось.
        var smartRawHTMLRanges: [NSRange]?
    }

    /// Номер версии текста (`EditorDocument.textRevision`); `nil` — текст не принадлежит документу (экспорт, тесты).
    var revision: UInt?
    /// Длина исходного текста в UTF-16.
    var textLength: Int
    var options: Options
    var blocks: [MarkdownBlockNode]
    var frontMatter: FrontMatter?
    /// Строки, где позиции cmark не подтверждены: отсортированы и слиты.
    var unreliableRanges: [NSRange]
    /// `id` заголовков в порядке документа (без заголовков в таблицах, картинках и определениях сносок).
    var headingIDs: [String]
    var namedAnchors: [MarkdownNamedAnchor]
    var footnotes: [MarkdownFootnote]
    /// Номер сноски cmark по метке определения `[^x]:` (порядок первых ссылок в документе; ссылка в теле определения тоже считается).
    var footnoteNumbers: [NSRange: Int] = [:]
    var looseIndents: [MarkdownLooseIndent]
    var smartReplacements: [MarkdownTextReplacement]
    var fence: FenceContext?
    var emoji: EmojiData?
    var readableText: MarkdownReadableText?
    var blockIndex: MarkdownBlockIndex?
    var elements: MarkdownElementIndex?
    /// Неподтверждённые строчные HTML-теги и ruby (подзадача c): редактор не оформляет их (`MarkdownPresentation.blockedHTML`).
    var blockedHTML: [NSRange] = []
}

// MARK: - Блоки

struct MarkdownBlockNode: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case paragraph
        case heading(Heading)
        case quote
        case callout(Callout)
        case alert(Alert)
        case list(ListBlock)
        case listItem(ListItem)
        case codeBlock(CodeBlock)
        case mathBlock(source: String)
        case table(Table)
        case html(HTMLBlock)
        case tableOfContents
        case footnoteDefinition(label: String)
        case frontMatter
        case thematicBreak
        case noteEmbed(NoteEmbed)
        case comment
    }

    struct Heading: Equatable, Sendable {
        enum Style: Equatable, Sendable { case atx, setext }
        var level: Int
        var style: Style
        /// Видимый текст заголовка, как `MarkdownDocumentParser.headingText`.
        var title: String
        /// Якорь `lac-heading-…`; пустой у заголовка в таблице, картинке или определении сноски.
        var id: String
        var slug: String
        /// Текст без маркеров (`MarkdownHeading.plainTextRange`).
        var contentRange: NSRange
        var emoji: [MarkdownHeading.Emoji]
        /// `nil` — не запрошено (`Includes.uppercaseRuns`) или построить не удалось.
        var uppercaseRuns: [MarkdownHeading.UppercaseRun]?
        /// Лежит прямо в документе: не в цитате, списке и не в определении сноски.
        var isTopLevel: Bool
        var inUnsupportedContainer: Bool
    }

    /// Выноска Obsidian `> [!тип]± заголовок`. Заголовок — `inlines` узла, содержимое — `children`.
    struct Callout: Equatable, Sendable {
        enum Fold: Equatable, Sendable { case none, expanded, collapsed }
        /// Тип как написан (`warning`, `tldr`).
        var type: String
        /// `nil` — неизвестный тип; оформляется как `.note` с подписью `type`.
        var kind: MarkdownCalloutKind?
        var fold: Fold
        /// `[!тип]±`.
        var markerRange: NSRange
        /// Заголовок после маркера; `nil` — пустой (подпись берётся из типа).
        var titleRange: NSRange?
    }

    /// Алерт GitHub `> [!NOTE]` (только в документе, без вложения).
    enum Alert: String, Equatable, Sendable {
        case note = "NOTE", tip = "TIP", important = "IMPORTANT", warning = "WARNING", caution = "CAUTION"
    }

    struct ListBlock: Equatable, Sendable {
        enum Marker: Equatable, Sendable {
            case bullet(UInt16)
            case ordered(start: Int, delimiter: UInt16)
        }
        var marker: Marker
        /// Плотный список (без пустых строк между пунктами).
        var isTight: Bool
        /// Вложенность списков от 1.
        var depth: Int
    }

    /// Пункт списка; маркер — `markerRanges[0]`.
    struct ListItem: Equatable, Sendable {
        /// Номер у нумерованного списка.
        var ordinal: Int?
        var task: MarkdownTaskCheckbox?
    }

    struct CodeBlock: Equatable, Sendable {
        var isFenced: Bool
        /// Строка info без обрамления, как `cmark_node_get_fence_info`.
        var info: String
        var infoRange: NSRange?
        /// Есть закрывающее ограждение.
        var isClosed: Bool
        /// Тело по строкам: без префиксов контейнеров и без ограждений, без перевода строки.
        var bodySegments: [NSRange]
        /// Сколько пробелов у каждого отрезка добавлено при раскрытии табов (как `MarkdownCodeBlock.bodyPadding`).
        var bodyPadding: [Int]
        /// Тело как `cmark_node_get_literal`.
        var literal: String
        /// `mermaid`, `flow`, `sequence` у блока верхнего уровня с подтверждённой позицией.
        var diagram: MarkdownDiagram.Kind?
    }

    struct Table: Equatable, Sendable {
        struct Cell: Equatable, Sendable {
            /// Между разделителями `|`, с пробелами по краям.
            var range: NSRange
            /// Без обрамляющих пробелов.
            var contentRange: NSRange
            var column: Int
            /// Сколько `|` ячейка поглотила при слиянии (`CMARK_OPT_TABLE_SPANS`).
            var virtualSeparators: Int
            /// Значения cmark при `CMARK_OPT_TABLE_SPANS`; 0 — ячейка-заполнитель, в HTML не выводится.
            var colspan: Int
            var rowspan: Int
            /// Ячейка, которой cmark добирает короткую строку до числа столбцов (нет данных ячейки): выравнивания и диапазона у неё нет.
            var isPadding: Bool = false
            var inlines: [MarkdownInlineNode]
        }
        struct Row: Equatable, Sendable {
            var range: NSRange
            var isHeader: Bool
            var cells: [Cell]
        }
        var alignments: [MarkdownTableAlignment]
        /// Строка-разделитель `| --- | :-: |`.
        var delimiterRange: NSRange
        var rows: [Row]
    }

    struct HTMLBlock: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Не подтверждён как особый вид: выводится как сырой HTML (с `tagfilter`).
            case raw
            /// Подтверждённый блок: `displayHTML` — то, что редактор показывает как HTML-блок.
            case confirmed(displayHTML: String)
            /// Существующий тип: `range` внутри — диапазон блока.
            case details(MarkdownDetailsBlock)
            case media(MarkdownEmbeddedMedia)
            case iframe(MarkdownEmbeddedFrame, html: String, displayHTML: String)
            case svg(Data)
            case pageBreak(style: String)
            case twitter(MarkdownTwitterWidget)
            case images([MarkdownInlineNode.Image])
        }
        /// Текст блока, как `cmark_node_get_literal`.
        var literal: String
        var kind: Kind
    }

    struct NoteEmbed: Equatable, Sendable {
        var target: String
        var heading: String?
        var alias: String?
        var kind: MarkdownNoteEmbedItem.Kind
    }

    /// Строка блока внутри контейнеров: префикс стоит в начале `line`.
    struct ContainerPrefix: Equatable, Sendable {
        var line: NSRange
        var prefixLength: Int
        /// Чем префикс заменяется на строках продолжения (`>` остаётся, `- ` становится пробелами).
        var continuation: String
    }

    var kind: Kind
    var range: NSRange
    var markerRanges: [NSRange]
    var containerPrefixes: [ContainerPrefix]
    var children: [MarkdownBlockNode]
    var inlines: [MarkdownInlineNode]
    var isUnreliable: Bool
}

// MARK: - Строчные элементы

struct MarkdownInlineNode: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text(String)
        case code(String)
        case strong, emphasis, strikethrough
        case underline, keyboard, highlight, subscriptText, superscriptText
        case inlineStyle(MarkdownInlineStyle)
        case link(Link)
        case image(Image)
        case media(MarkdownEmbeddedMedia)
        case iframe(MarkdownEmbeddedFrame, html: String, displayHTML: String)
        case svg(Data)
        case ruby(Ruby)
        case wikiLink(WikiLink)
        case noteEmbed(MarkdownBlockNode.NoteEmbed)
        case formula(source: String)
        case footnoteReference(label: String)
        case emoji(name: String)
        case critic(CriticMarkupKind)
        case softBreak, hardBreak
        case rawHTML(String)
        case comment
    }

    struct Link: Equatable, Sendable {
        enum Form: Equatable, Sendable { case inline, reference, autolink, html }
        var url: String
        var title: String?
        var form: Form
        /// Адрес как написан; `nil` у ссылочной формы и автоссылки.
        var destinationRange: NSRange?
    }

    struct Image: Equatable, Sendable {
        enum Syntax: Equatable, Sendable { case markdown, reference, html }
        var url: String
        var alt: String
        var title: String?
        var syntax: Syntax
        var addressRange: NSRange?
        /// `width`, `height`, `style` у `<img>`.
        var sizing: MarkdownImageSizing?
        /// Единственный элемент абзаца верхнего уровня.
        var isBlock: Bool
        /// Диапазон тега `<img>` в тексте; `nil` у Markdown-форм (там диапазон узла).
        var tagRange: NSRange? = nil
    }

    struct Ruby: Equatable, Sendable {
        var base: String
        var reading: String
        var baseRange: NSRange
        var readingRange: NSRange
        var baseRuns: [MarkdownRubyBaseRun]
        /// Скобки `<rp>` до и после чтения.
        var openingParenthesis: String?
        var closingParenthesis: String?
        /// HTML основания с оформлением (nil — основание без оформления) и текст после `</rt>`/`<rp>` до `</ruby>`.
        var baseHTML: String? = nil
        var trailing: String? = nil
    }

    /// `[[цель#заголовок|текст]]`; разделители — `markerRanges` узла (как `MarkdownWikiLink.markerRanges`).
    struct WikiLink: Equatable, Sendable {
        var target: String
        var heading: String?
        var alias: String?
        var displayRange: NSRange
    }

    var kind: Kind
    var range: NSRange
    var markerRanges: [NSRange]
    var children: [MarkdownInlineNode]
    var isUnreliable: Bool
}

extension MarkdownInlineNode {
    /// Пара тегов `<b>…</b>`: первый маркер — открывающий тег (начинается с `<`), а не `**`/`_`/`~~`.
    func hasHTMLTagMarker(in text: NSString) -> Bool {
        guard let marker = markerRanges.first, marker.location >= 0, marker.location < text.length else { return false }
        return text.character(at: marker.location) == 60
    }
}
