import Foundation

public struct TodoItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var collection: String
    public var isDone: Bool
    public var isLocked: Bool
    public var createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case collection
        case isDone
        case isLocked
        case createdAt
        case updatedAt
    }

    public init(
        id: String,
        title: String,
        collection: String,
        isDone: Bool = false,
        isLocked: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.collection = collection
        self.isDone = isDone
        self.isLocked = isLocked
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        collection = try container.decode(String.self, forKey: .collection)
        isDone = try container.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

public enum TodoCompletionFilter: String, CaseIterable, Sendable {
    case done
    case undone

    public var isDone: Bool {
        self == .done
    }
}

public struct TodoCollectionSummary: Identifiable, Equatable, Sendable {
    public var id: String { name }

    public let name: String
    public let totalCount: Int
    public let undoneCount: Int

    public init(name: String, totalCount: Int, undoneCount: Int) {
        self.name = name
        self.totalCount = totalCount
        self.undoneCount = undoneCount
    }
}
