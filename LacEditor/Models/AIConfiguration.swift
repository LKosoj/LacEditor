import Foundation

enum AIRole: String, CaseIterable, Identifiable, Codable {
    case text, decisions, image, ocr, audio
    var id: String { rawValue }
}

enum AIAPIProtocol: String, CaseIterable, Codable {
    case responses, chatCompletions, decisions, images, gatewayPDF, transcriptions
}

struct AIModelProfile: Codable, Equatable {
    var isEnabled = false
    var baseURL = "https://api.openai.com/v1"
    var modelID = ""
    var api: AIAPIProtocol

    static func `default`(for role: AIRole) -> AIModelProfile {
        switch role {
        case .text: AIModelProfile(api: .responses)
        case .decisions: AIModelProfile(api: .decisions)
        case .image: AIModelProfile(api: .images)
        case .ocr: AIModelProfile(api: .gatewayPDF)
        case .audio: AIModelProfile(api: .transcriptions)
        }
    }

    static func normalizedBaseURL(_ value: String) throws -> URL {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw AIError.invalidConfiguration }
        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) { components.port = nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw AIError.invalidConfiguration }
        return url
    }

    func supports(_ role: AIRole) -> Bool {
        switch role {
        case .text: api == .responses || api == .chatCompletions
        case .decisions: api == .decisions || api == .responses || api == .chatCompletions
        case .image: api == .images
        case .ocr: api == .gatewayPDF || api == .responses || api == .chatCompletions
        case .audio: api == .transcriptions
        }
    }
}

struct AIConfiguration: Codable, Equatable {
    var text = AIModelProfile.default(for: .text)
    var decisions = AIModelProfile.default(for: .decisions)
    var image = AIModelProfile.default(for: .image)
    var ocr = AIModelProfile.default(for: .ocr)
    var audio = AIModelProfile.default(for: .audio)

    init() {}

    private enum CodingKeys: String, CodingKey { case text, decisions, image, ocr, audio }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decodeIfPresent(AIModelProfile.self, forKey: .text) ?? .default(for: .text)
        decisions = try values.decodeIfPresent(AIModelProfile.self, forKey: .decisions) ?? .default(for: .decisions)
        image = try values.decodeIfPresent(AIModelProfile.self, forKey: .image) ?? .default(for: .image)
        ocr = try values.decodeIfPresent(AIModelProfile.self, forKey: .ocr) ?? .default(for: .ocr)
        audio = try values.decodeIfPresent(AIModelProfile.self, forKey: .audio) ?? .default(for: .audio)
    }

    subscript(role: AIRole) -> AIModelProfile {
        get {
            switch role {
            case .text: text
            case .decisions: decisions
            case .image: image
            case .ocr: ocr
            case .audio: audio
            }
        }
        set {
            switch role {
            case .text: text = newValue
            case .decisions: decisions = newValue
            case .image: image = newValue
            case .ocr: ocr = newValue
            case .audio: audio = newValue
            }
        }
    }
}
