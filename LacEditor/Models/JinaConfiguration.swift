import Foundation

enum JinaServiceKind: String, CaseIterable, Identifiable {
    case search, reader
    var id: String { rawValue }
}

struct JinaConfiguration: Codable, Equatable {
    var searchEnabled = false
    var readerEnabled = false
    var searchEndpoint = "https://s.jina.ai/search"
    var readerEndpoint = "https://r.jina.ai/"

    func endpoint(for kind: JinaServiceKind) -> String {
        switch kind {
        case .search: searchEndpoint
        case .reader: readerEndpoint
        }
    }

    func isEnabled(for kind: JinaServiceKind) -> Bool {
        switch kind {
        case .search: searchEnabled
        case .reader: readerEnabled
        }
    }
}
