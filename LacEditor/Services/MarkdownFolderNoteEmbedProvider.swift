import Foundation

/// Встраивание из обычной папки: цель разрешает `MarkdownWikiLinkResolver`, файл читается с диска.
struct MarkdownFolderNoteEmbedProvider: MarkdownNoteEmbedProvider {
    let context: MarkdownWikiLinkContext
    var maxBytes = 256 << 10

    /// Только `.file(path)`; файл больше `maxBytes`, не UTF-8 или недоступный (в том числе ссылка за пределы базы) — nil.
    func embeddedNote(for target: String) -> String? {
        guard case let .file(path) = context.resolver.resolve(target: target),
              let url = context.resolver.url(for: path), let base = context.resolver.base,
              isInside(url, base: base),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func openAddress(for target: String, heading: String?) -> String? {
        context.relativeHref(for: MarkdownWikiLink(range: NSRange(location: 0, length: 0), displayRange: NSRange(location: 0, length: 0),
                                                   target: target, heading: heading, alias: nil, markerRanges: []))
    }

    /// Символическая ссылка не должна уводить за пределы базы.
    private func isInside(_ url: URL, base: URL) -> Bool {
        let root = base.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
