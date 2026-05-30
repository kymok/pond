import Foundation

public enum TaskStoreError: LocalizedError, Equatable {
    case invalidTitle
    case invalidCollection
    case invalidCollectionGroup
    case defaultCollection
    case defaultCollectionGroup
    case invalidID(String)
    case missingTarget
    case missingUpdate
    case missingNoteUpdate
    case targetConflict
    case noMatchingTasks
    case notFound(String)
    case noteNotFound(String)
    case collectionNotFound(String)
    case collectionGroupNotFound(String)
    case collectionConflict(String)
    case ambiguousID(String, [String])
    case duplicateID(String)
    case invalidNote
    case fileLockFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTitle:
            "Task title cannot be empty."
        case .invalidCollection:
            "Collection name cannot be empty."
        case .invalidCollectionGroup:
            "Collection group name cannot be empty."
        case .defaultCollection:
            "Default collection cannot be renamed, deleted, or moved."
        case .defaultCollectionGroup:
            "Default collection group cannot be renamed or deleted."
        case .invalidID(let id):
            "Task id '\(id)' is invalid."
        case .missingTarget:
            "Command requires --collection or at least one id."
        case .missingUpdate:
            "Update requires a title, --collection, or --status/-s."
        case .missingNoteUpdate:
            "Note update requires --body."
        case .targetConflict:
            "Use either --collection or ids, not both."
        case .noMatchingTasks:
            "No matching tasks."
        case .notFound(let id):
            "No task matches '\(id)'."
        case .noteNotFound(let id):
            "No note matches '\(id)'."
        case .collectionNotFound(let name):
            "No collection matches '\(name)'."
        case .collectionGroupNotFound(let name):
            "No collection group matches '\(name)'."
        case .collectionConflict(let name):
            "Collection '\(name)' already exists."
        case .ambiguousID(let id, let matches):
            "Task id '\(id)' is ambiguous: \(matches.joined(separator: ", "))."
        case .duplicateID(let id):
            "Task id '\(id)' already exists."
        case .invalidNote:
            "Note body cannot be empty."
        case .fileLockFailed(let reason):
            "Could not lock task store: \(reason)"
        }
    }
}
