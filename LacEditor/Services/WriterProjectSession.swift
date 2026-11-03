import Foundation

/// Привязка вкладки к проекту рукописи для файла сессии; старые сессии читаются без неё.
struct WriterProjectSession: Codable, Equatable, Sendable {
    let rootPath: String
    let projectID: UUID

    init(rootPath: String, projectID: UUID) {
        self.rootPath = rootPath
        self.projectID = projectID
    }

    /// Испорченное поле не ломает восстановление всей сессии: запись становится пустой и отбрасывается через `isValid`.
    init(from decoder: Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self),
              let path = try? values.decode(String.self, forKey: .rootPath), !path.isEmpty,
              let id = try? values.decode(UUID.self, forKey: .projectID) else {
            rootPath = ""
            projectID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            return
        }
        rootPath = path
        projectID = id
    }

    var isValid: Bool { !rootPath.isEmpty }
}
