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
