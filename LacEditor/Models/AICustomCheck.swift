import Foundation

struct AICustomCheck: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var instructions: String
    var isEnabled: Bool
    var modelID: String

    init(id: UUID = UUID(), name: String = "", instructions: String = "", isEnabled: Bool = false, modelID: String = "") {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.isEnabled = isEnabled
        self.modelID = modelID
    }

    private enum CodingKeys: String, CodingKey { case id, name, instructions, isEnabled, modelID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        instructions = try values.decode(String.self, forKey: .instructions)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        modelID = try values.decodeIfPresent(String.self, forKey: .modelID) ?? ""
    }
}

extension AICustomCheck {
    /// Стабильный id, чтобы шаблон не добавлялся дважды.
    static let styleAndRhythmTemplateID = UUID(uuidString: "5B6A3E0C-7D1F-4E8A-9C2B-0A1D5E7F3B91")!

    /// Готовая проверка «Стиль и ритм». Добавляется кнопкой в настройках и по умолчанию выключена.
    static func styleAndRhythmTemplate() -> AICustomCheck {
        AICustomCheck(
            id: styleAndRhythmTemplateID,
            name: L10n.tr("文风与节奏"),
            instructions: "Check the text for style and rhythm. Point out stock phrases, bureaucratic wording, ambiguity, monotonous or choppy sentence rhythm and inconsistent tense. For each point quote the exact passage, explain the problem in one sentence and suggest a shorter or clearer wording. Do not rewrite the whole text and do not judge whether it was written by a human or by AI.",
            isEnabled: false,
            modelID: ""
        )
    }
}
