import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

/// Правило места нового изображения (буфер, Continuity Camera, ИИ), когда нет явных настроек загрузки или копирования.
enum MarkdownImagePlacement {
    /// Хранится в настройках как rawValue.
    enum Choice: String, Sendable { case besideDocument, embedded }

    enum Decision: Equatable {
        /// Документ без файла или заметка хранилища: сразу встроить, без вопроса о месте.
        case embedWithoutQuestion
        case ask(remembered: Choice?)
    }

    static func decision(documentURL: URL?, isVaultNote: Bool, remembered: Choice?) -> Decision {
        guard documentURL != nil, !isVaultNote else { return .embedWithoutQuestion }
        return .ask(remembered: remembered)
    }

    /// `<каталог документа>/<имя без расширения>.assets`
    static func assetsFolder(for documentURL: URL) -> URL {
        let name = documentURL.deletingPathExtension().lastPathComponent
        return documentURL.deletingLastPathComponent().appendingPathComponent(name + ".assets", isDirectory: true)
    }

    /// `image-ГГГГММДД-ЧЧММСС.<ext>`; `jpeg` приводится к `jpg`; при `suffix` добавляется `-N`.
    static func fileName(now: Date, fileExtension: String, suffix: Int?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var ext = fileExtension.lowercased()
        if ext == "jpeg" { ext = "jpg" }
        let number = suffix.map { "-\($0)" } ?? ""
        return "image-\(formatter.string(from: now))\(number).\(ext)"
    }

    /// Создаёт папку и пишет файл без перезаписи; при занятом имени берёт следующий номер.
    static func save(_ data: Data, fileExtension: String, nextTo documentURL: URL,
                     now: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        let folder = assetsFolder(for: documentURL)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for number in 1...1000 {
            let name = fileName(now: now, fileExtension: fileExtension, suffix: number == 1 ? nil : number)
            let destination = folder.appendingPathComponent(name)
            do {
                try data.write(to: destination, options: .withoutOverwriting)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func dataAddress(_ data: Data, mime: String) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }
}

#if canImport(ImageIO)
/// Уменьшение снимка с камеры: длинная сторона не больше 2048 px, без увеличения маленьких.
enum MarkdownImageReducer {
    static let maxLongSide = 2048
    static let jpegQuality = 0.8

    /// nil, если байты не изображение. PNG при реальной прозрачности, иначе JPEG.
    static func reduced(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxLongSide)
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Перерисовка в RGBA: так проверяется прозрачность и снимается лишний альфа-канал у JPEG.
        let hasAlpha = hasTransparentPixel(thumbnail)
        let image = hasAlpha ? thumbnail : (opaqueCopy(of: thumbnail) ?? thumbnail)
        let output = NSMutableData()
        let type = hasAlpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let destinationOptions: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func rgbaContext(width: Int, height: Int, alpha: CGImageAlphaInfo) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue)
    }

    private static func hasTransparentPixel(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        guard let context = rgbaContext(width: image.width, height: image.height, alpha: .premultipliedLast),
              let base = context.data else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        for row in 0..<image.height {
            for column in 0..<image.width where pixels[row * stride + column * 4 + 3] != 255 { return true }
        }
        return false
    }

    private static func opaqueCopy(of image: CGImage) -> CGImage? {
        guard let context = rgbaContext(width: image.width, height: image.height, alpha: .noneSkipLast) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
#endif

#if canImport(AppKit)
/// Блок «Расположение изображения»: два варианта и галочка «запомнить». Общий для окна «图片» и окна ИИ.
@MainActor
final class MarkdownImagePlacementPrompt: NSObject {
    let view: NSView
    private(set) var choice: MarkdownImagePlacement.Choice
    private let besideButton: NSButton
    private let embedButton: NSButton
    private let rememberButton: NSButton

    /// nil: отмечено «рядом», галочка снята. Иначе отмечен запомненный выбор и стоит галочка.
    init(remembered: MarkdownImagePlacement.Choice?) {
        choice = remembered ?? .besideDocument
        besideButton = NSButton(radioButtonWithTitle: L10n.tr("保存在文档旁边"), target: nil, action: nil)
        embedButton = NSButton(radioButtonWithTitle: L10n.tr("嵌入文档"), target: nil, action: nil)
        rememberButton = NSButton(checkboxWithTitle: L10n.tr("记住此文档的选择"), target: nil, action: nil)
        let title = NSTextField(labelWithString: L10n.tr("图片位置"))
        let stack = NSStackView(views: [title, besideButton, embedButton, rememberButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 84)
        view = stack
        super.init()
        for button in [besideButton, embedButton] {
            button.target = self
            button.action = #selector(choose(_:))
            button.setAccessibilityLabel(button.title)
        }
        rememberButton.setAccessibilityLabel(rememberButton.title)
        rememberButton.state = remembered == nil ? .off : .on
        refresh()
    }

    var remember: Bool { rememberButton.state == .on }

    @objc private func choose(_ sender: NSButton) {
        choice = sender === embedButton ? .embedded : .besideDocument
        refresh()
    }

    private func refresh() {
        besideButton.state = choice == .besideDocument ? .on : .off
        embedButton.state = choice == .embedded ? .on : .off
    }

    /// Для ИИ: небольшое окно «图片» с этим блоком; true — нажато «应用».
    func runAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.tr("图片")
        alert.accessoryView = view
        alert.addButton(withTitle: L10n.tr("应用"))
        alert.addButton(withTitle: L10n.tr("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
#endif
