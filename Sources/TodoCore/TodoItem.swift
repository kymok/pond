import Foundation

public struct TodoItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var title: String
    public var collection: String
    public var assignees: [String]
    public var priority: TodoPriority
    public var status: TodoStatus
    public var createdAt: Date
    public var updatedAt: Date

    private static let versionCharacters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case title
        case collection
        case assignees
        case assignee
        case priority
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
        assignees: [String] = [],
        priority: TodoPriority = .normal,
        status: TodoStatus = .ready,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.collection = collection
        self.assignees = Self.normalizedAssignees(assignees)
        self.priority = priority
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
        if let decodedAssignees = try container.decodeIfPresent([String].self, forKey: .assignees) {
            assignees = Self.normalizedAssignees(decodedAssignees)
        } else if let decodedAssignee = try container.decodeIfPresent(String.self, forKey: .assignee) {
            assignees = Self.normalizedAssignees([decodedAssignee])
        } else {
            assignees = []
        }
        priority = try container.decodeIfPresent(TodoPriority.self, forKey: .priority) ?? .normal
        if let decodedStatus = try container.decodeIfPresent(TodoStatus.self, forKey: .status) {
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
        if !assignees.isEmpty {
            try container.encode(assignees, forKey: .assignees)
        }
        if priority != .normal {
            try container.encode(priority, forKey: .priority)
        }
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private static func normalizedAssignees(_ assignees: [String]) -> [String] {
        var seen: Set<String> = []
        return assignees.compactMap { assignee in
            let clean = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean).inserted else {
                return nil
            }

            return clean
        }
    }
}

public enum TodoPriority: String, Codable, CaseIterable, Sendable {
    case normal
    case prioritized

    public var displayName: String {
        switch self {
        case .normal:
            "normal"
        case .prioritized:
            "Prioritized"
        }
    }
}

public enum TodoStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case ready = "ready"
    case inProgress = "in-progress"
    case completed
    case onHold = "on-hold"
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
        }
    }

    public var isIncomplete: Bool {
        self != .completed
    }
}

public enum TodoCollectionColor: String, Codable, CaseIterable, Identifiable, Sendable {
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

public struct TodoCollectionSummary: Identifiable, Equatable, Sendable {
    public var id: String { name }

    public let name: String
    public let totalCount: Int
    public let incompleteCount: Int
    public let statusIndicator: TodoStatus?
    public let color: TodoCollectionColor
    public let isArchived: Bool

    public init(
        name: String,
        totalCount: Int,
        incompleteCount: Int,
        statusIndicator: TodoStatus? = nil,
        color: TodoCollectionColor = .gray,
        isArchived: Bool = false
    ) {
        self.name = name
        self.totalCount = totalCount
        self.incompleteCount = incompleteCount
        self.statusIndicator = statusIndicator
        self.color = color
        self.isArchived = isArchived
    }
}
