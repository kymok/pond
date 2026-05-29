import Foundation

public struct TaskNote: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        version: String = TaskItem.makeVersion(),
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.version = version
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var title: String
    public var collection: String
    public var notes: [TaskNote]
    public var status: TaskStatus
    public var createdAt: Date
    public var updatedAt: Date

    private static let versionCharacters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case title
        case collection
        case note
        case notes
        case status
        case createdAt
        case updatedAt
        case isDone
        case isLocked
    }

    public init(
        id: String,
        version: String = Self.makeVersion(),
        title: String,
        collection: String,
        notes: [TaskNote] = [],
        status: TaskStatus = .ready,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.collection = collection
        self.notes = notes
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func makeVersion(existing: Set<String> = []) -> String {
        var version: String

        repeat {
            version = String((0..<12).map { _ in versionCharacters.randomElement() ?? "0" })
        } while existing.contains(version)

        return version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        if let decodedVersion = try container.decodeIfPresent(String.self, forKey: .version),
           !decodedVersion.isEmpty {
            version = decodedVersion
        } else {
            version = Self.makeVersion()
        }
        title = try container.decode(String.self, forKey: .title)
        collection = try container.decode(String.self, forKey: .collection)
        notes = try container.decodeIfPresent(TaskNote.self, forKey: .note).map { [$0] } ?? []
        if let decodedStatus = try container.decodeIfPresent(TaskStatus.self, forKey: .status) {
            status = decodedStatus
        } else {
            let isDone = try container.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
            let isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
            status = isDone ? .completed : (isLocked ? .inProgress : .ready)
        }
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(title, forKey: .title)
        try container.encode(collection, forKey: .collection)
        if !notes.isEmpty {
            try container.encode(notes[0], forKey: .note)
        }
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case ready = "ready"
    case inProgress = "in-progress"
    case completed
    case onHold = "on-hold"
    case rejected
    case aborted

    public var displayName: String {
        switch self {
        case .ready:
            "Ready"
        case .draft:
            "Draft"
        case .inProgress:
            "In Progress"
        case .completed:
            "Completed"
        case .onHold:
            "On Hold"
        case .aborted:
            "Aborted"
        case .rejected:
            "Rejected"
        }
    }

    public var isIncomplete: Bool {
        self != .completed
    }
}

public enum TaskCollectionColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case gray
    case red
    case orange
    case yellow
    case green
    case blue
    case purple

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gray:
            "Gray"
        case .red:
            "Red"
        case .orange:
            "Orange"
        case .yellow:
            "Yellow"
        case .green:
            "Green"
        case .blue:
            "Blue"
        case .purple:
            "Purple"
        }
    }
}

public struct TaskCollectionSummary: Identifiable, Equatable, Sendable {
    public var id: String { name }

    public let name: String
    public let displayName: String
    public let groupName: String
    public let totalCount: Int
    public let incompleteCount: Int
    public let statusIndicator: TaskStatus?
    public let color: TaskCollectionColor
    public let isArchived: Bool
    public let promptTemplate: String?

    public init(
        name: String,
        displayName: String? = nil,
        groupName: String = "DefaultGroup",
        totalCount: Int,
        incompleteCount: Int,
        statusIndicator: TaskStatus? = nil,
        color: TaskCollectionColor = .gray,
        isArchived: Bool = false,
        promptTemplate: String? = nil
    ) {
        self.name = name
        self.displayName = displayName ?? name
        self.groupName = groupName
        self.totalCount = totalCount
        self.incompleteCount = incompleteCount
        self.statusIndicator = statusIndicator
        self.color = color
        self.isArchived = isArchived
        self.promptTemplate = promptTemplate
    }
}

public struct TaskCollectionGroupSummary: Identifiable, Equatable, Sendable {
    public var id: String { name }

    public let name: String
    public let collections: [TaskCollectionSummary]

    public init(name: String, collections: [TaskCollectionSummary] = []) {
        self.name = name
        self.collections = collections
    }
}
