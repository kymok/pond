import Darwin
import Foundation

struct TaskFile: Codable {
    var version = 6
    var collections: [String] = []
    var collectionGroups: [TaskCollectionGroup] = []
    var collectionColors: [String: TaskCollectionColor] = [:]
    var collectionPrompts: [String: String] = [:]
    var archivedCollections: Set<String> = []
    var items: [TaskItem] = []
    var needsMigration = false

    enum CodingKeys: String, CodingKey {
        case version
        case collections
        case collectionGroups
        case collectionColors
        case collectionPrompts
        case archivedCollections
        case items
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        let itemVersionProbes = try container.decodeIfPresent([TaskItemVersionProbe].self, forKey: .items) ?? []
        items = try container.decodeIfPresent([TaskItem].self, forKey: .items) ?? []
        needsMigration = itemVersionProbes.contains { $0.version?.isEmpty ?? true }
        let rawCollections = normalizedCollectionList(
            (try container.decodeIfPresent([String].self, forKey: .collections) ?? [])
                + items.map(\.collection)
        )
        let decodedGroups = try container.decodeIfPresent([TaskCollectionGroup].self, forKey: .collectionGroups)
        let migratedCollections = migratedCollectionState(
            collections: rawCollections,
            groups: decodedGroups,
            items: &items,
            usesLegacyGroups: version < 6 || storedGroupsNeedLegacyMigration(decodedGroups)
        )
        collections = migratedCollections.collections
        collectionGroups = migratedCollections.groups
        needsMigration = needsMigration || migratedCollections.changed
        if !container.contains(.collectionGroups) {
            needsMigration = true
        }
        let rawColors = try container.decodeIfPresent([String: String].self, forKey: .collectionColors) ?? [:]
        collectionColors = normalizedCollectionColors(
            migratedCollectionMetadata(
                rawColors.compactMapValues { TaskCollectionColor(rawValue: $0) },
                renameMap: migratedCollections.renameMap
            ),
            collections: collections
        )
        let rawPrompts = try container.decodeIfPresent([String: String].self, forKey: .collectionPrompts) ?? [:]
        collectionPrompts = normalizedCollectionPrompts(
            migratedCollectionMetadata(rawPrompts, renameMap: migratedCollections.renameMap),
            collections: collections
        )
        let rawArchivedCollections = try container.decodeIfPresent([String].self, forKey: .archivedCollections) ?? []
        archivedCollections = Set(
            normalizedCollectionList(rawArchivedCollections.map { migratedCollections.renameMap[$0] ?? $0 })
                .filter { collections.contains($0) }
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let collectionNames = normalizedCollectionList(collections + items.map(\.collection))
        let groups = normalizedCollectionGroups(collectionGroups, collections: collectionNames)
        try container.encode(6, forKey: .version)
        try container.encode(collectionNames, forKey: .collections)
        try container.encode(groups, forKey: .collectionGroups)
        try container.encode(
            normalizedCollectionColors(collectionColors, collections: collectionNames),
            forKey: .collectionColors
        )
        try container.encode(
            normalizedCollectionPrompts(collectionPrompts, collections: collectionNames),
            forKey: .collectionPrompts
        )
        try container.encode(
            sortedCollectionNames(archivedCollections.filter { collectionNames.contains($0) }),
            forKey: .archivedCollections
        )
        try container.encode(items, forKey: .items)
    }
}

struct TaskCollectionGroup: Codable, Equatable {
    var name: String
    var collections: [String]
}

struct TaskItemVersionProbe: Decodable {
    var version: String?

    enum CodingKeys: String, CodingKey {
        case version
    }
}


struct CollectionReference {
    var groupName: String
    var displayName: String

    var apiName: String {
        collectionAPIName(groupName: groupName, displayName: displayName)
    }
}

func normalizedCollection(_ collection: String) throws -> String {
    let clean = collection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else {
        return TaskStore.defaultCollection
    }

    return try normalizedCollectionReference(clean, defaultGroup: TaskStore.defaultCollectionGroup).apiName
}

func normalizedExplicitCollection(_ collection: String) throws -> String {
    let clean = collection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else {
        throw TaskStoreError.invalidCollection
    }

    return try normalizedCollectionReference(clean, defaultGroup: TaskStore.defaultCollectionGroup).apiName
}

func normalizedCollectionOrNil(_ collection: String?) throws -> String? {
    guard let collection else {
        return nil
    }

    return try normalizedCollection(collection)
}

func normalizedCollectionReference(
    _ collection: String,
    defaultGroup: String
) throws -> CollectionReference {
    let cleanDefaultGroup = try normalizedExplicitCollectionGroup(defaultGroup)
    let cleanCollection = collection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanCollection.isEmpty else {
        throw TaskStoreError.invalidCollection
    }

    let parts = cleanCollection.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    switch parts.count {
    case 1:
        let displayName = try normalizedCollectionDisplayName(parts[0])
        return CollectionReference(groupName: cleanDefaultGroup, displayName: displayName)
    case 2:
        let groupName = try normalizedExplicitCollectionGroup(parts[0])
        let displayName = try normalizedCollectionDisplayName(parts[1])
        return CollectionReference(groupName: groupName, displayName: displayName)
    default:
        throw TaskStoreError.invalidCollection
    }
}

func normalizedCollectionDisplayName(_ displayName: String) throws -> String {
    let clean = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, !clean.contains("/") else {
        throw TaskStoreError.invalidCollection
    }

    return clean
}

func collectionReferenceIfValid(_ collection: String) -> CollectionReference? {
    try? normalizedCollectionReference(collection, defaultGroup: TaskStore.defaultCollectionGroup)
}

func collectionAPIName(groupName: String, displayName: String) -> String {
    if groupName == TaskStore.defaultCollectionGroup {
        return displayName == legacyDefaultCollection ? TaskStore.defaultCollection : displayName
    }

    return "\(groupName)/\(displayName)"
}

func collectionDisplayName(_ collection: String) -> String {
    if collection == TaskStore.defaultCollection {
        return legacyDefaultCollection
    }

    return collectionReferenceIfValid(collection)?.displayName ?? collection
}

func collectionGroupName(forCollectionAPIName collection: String) -> String {
    collectionReferenceIfValid(collection)?.groupName ?? TaskStore.defaultCollectionGroup
}

func normalizedCollectionList<S: Sequence>(_ collections: S) -> [String] where S.Element == String {
    var seen: Set<String> = []
    var result: [String] = []

    for collection in collections {
        let clean = (try? normalizedCollection(collection)) ?? TaskStore.defaultCollection
        guard !seen.contains(clean) else {
            continue
        }

        seen.insert(clean)
        result.append(clean)
    }

    return result
}

func normalizedExplicitCollectionGroup(_ group: String) throws -> String {
    let clean = group.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, !clean.contains("/") else {
        throw TaskStoreError.invalidCollectionGroup
    }

    return clean
}

func normalizedStoredCollectionGroup(_ group: String) throws -> String {
    let clean = try normalizedExplicitCollectionGroup(group)
    return clean == legacyDefaultCollectionGroup ? TaskStore.defaultCollectionGroup : clean
}

let legacyDefaultCollectionGroup = "Collections"
let legacyDefaultCollection = "Inbox"

func normalizedCollectionGroups(
    _ groups: [TaskCollectionGroup]?,
    collections: [String]
) -> [TaskCollectionGroup] {
    var seenGroups: Set<String> = []
    var assignedCollections: Set<String> = []
    var result: [TaskCollectionGroup] = []
    let collectionNames = normalizedCollectionList(collections)
    let collectionNameSet = Set(collectionNames)

    for group in groups ?? [] {
        guard let cleanName = try? normalizedStoredCollectionGroup(group.name),
              !seenGroups.contains(cleanName)
        else {
            continue
        }

        let cleanCollections = normalizedCollectionList(
            group.collections.map { collection in
                collectionAPIName(groupName: cleanName, displayName: collectionDisplayName(collection))
            }
        )
        .filter { collectionNameSet.contains($0) && !assignedCollections.contains($0) }
        assignedCollections.formUnion(cleanCollections)
        seenGroups.insert(cleanName)
        result.append(TaskCollectionGroup(name: cleanName, collections: cleanCollections))
    }

    if !seenGroups.contains(TaskStore.defaultCollectionGroup) {
        result.insert(TaskCollectionGroup(name: TaskStore.defaultCollectionGroup, collections: []), at: 0)
        seenGroups.insert(TaskStore.defaultCollectionGroup)
    }

    let unassignedCollections = collectionNames.filter { !assignedCollections.contains($0) }
    for collection in unassignedCollections {
        let groupName = collectionGroupName(forCollectionAPIName: collection)
        if let index = result.firstIndex(where: { $0.name == groupName }) {
            result[index].collections = normalizedCollectionList(result[index].collections + [collection])
        } else {
            result.append(TaskCollectionGroup(name: groupName, collections: [collection]))
        }
    }

    return result.filter { $0.name == TaskStore.defaultCollectionGroup }
        + result.filter { $0.name != TaskStore.defaultCollectionGroup }
}

struct MigratedCollectionState {
    var collections: [String]
    var groups: [TaskCollectionGroup]
    var renameMap: [String: String]
    var changed: Bool
}

func migratedCollectionState(
    collections rawCollections: [String],
    groups rawGroups: [TaskCollectionGroup]?,
    items: inout [TaskItem],
    usesLegacyGroups: Bool
) -> MigratedCollectionState {
    let sourceGroups = usesLegacyGroups
        ? normalizedLegacyCollectionGroups(rawGroups, collections: rawCollections)
        : normalizedCollectionGroups(rawGroups, collections: rawCollections)
    var renameMap: [String: String] = [:]
    var migratedGroups: [TaskCollectionGroup] = []
    var changed = false

    for group in sourceGroups {
        let migratedCollections = normalizedCollectionList(group.collections.map { collection in
            let apiName = collectionAPIName(groupName: group.name, displayName: collectionDisplayName(collection))
            if collection != apiName {
                changed = true
            }
            renameMap[collection] = apiName
            return apiName
        })
        migratedGroups.append(TaskCollectionGroup(name: group.name, collections: migratedCollections))
    }

    for index in items.indices {
        let cleanCollection = (try? normalizedCollection(items[index].collection)) ?? TaskStore.defaultCollection
        let migratedCollection = renameMap[cleanCollection] ?? cleanCollection
        if items[index].collection != migratedCollection {
            items[index].collection = migratedCollection
            changed = true
        }
    }

    let collections = normalizedCollectionList(
        rawCollections.map { renameMap[$0] ?? $0 }
            + items.map(\.collection)
            + migratedGroups.flatMap(\.collections)
    )
    let groups = normalizedCollectionGroups(migratedGroups, collections: collections)
    changed = changed || collections != rawCollections || groups != normalizedCollectionGroups(rawGroups, collections: rawCollections)
    return MigratedCollectionState(
        collections: collections,
        groups: groups,
        renameMap: renameMap,
        changed: changed
    )
}

func normalizedLegacyCollectionGroups(
    _ groups: [TaskCollectionGroup]?,
    collections: [String]
) -> [TaskCollectionGroup] {
    var seenGroups: Set<String> = []
    var assignedCollections: Set<String> = []
    var result: [TaskCollectionGroup] = []
    let collectionNames = normalizedCollectionList(collections)

    for group in groups ?? [] {
        guard let cleanName = try? normalizedStoredCollectionGroup(group.name),
              !seenGroups.contains(cleanName)
        else {
            continue
        }

        let cleanCollections = normalizedCollectionList(group.collections)
            .filter { collectionNames.contains($0) && !assignedCollections.contains($0) }
        assignedCollections.formUnion(cleanCollections)
        seenGroups.insert(cleanName)
        result.append(TaskCollectionGroup(name: cleanName, collections: cleanCollections))
    }

    if !seenGroups.contains(TaskStore.defaultCollectionGroup) {
        result.insert(TaskCollectionGroup(name: TaskStore.defaultCollectionGroup, collections: []), at: 0)
        seenGroups.insert(TaskStore.defaultCollectionGroup)
    }

    let unassignedCollections = collectionNames.filter { !assignedCollections.contains($0) }
    if let defaultIndex = result.firstIndex(where: { $0.name == TaskStore.defaultCollectionGroup }) {
        result[defaultIndex].collections = normalizedCollectionList(result[defaultIndex].collections + unassignedCollections)
    }

    return result.filter { $0.name == TaskStore.defaultCollectionGroup }
        + result.filter { $0.name != TaskStore.defaultCollectionGroup }
}

func storedGroupsNeedLegacyMigration(_ groups: [TaskCollectionGroup]?) -> Bool {
    for group in groups ?? [] {
        guard let cleanGroup = try? normalizedStoredCollectionGroup(group.name) else {
            continue
        }

        if cleanGroup != group.name {
            return true
        }

        for collection in group.collections {
            let cleanCollection = (try? normalizedCollection(collection)) ?? TaskStore.defaultCollection
            if collectionGroupName(forCollectionAPIName: cleanCollection) != cleanGroup {
                return true
            }
        }
    }

    return false
}

func migratedCollectionMetadata<Value>(
    _ metadata: [String: Value],
    renameMap: [String: String]
) -> [String: Value] {
    var result: [String: Value] = [:]

    for (name, value) in metadata {
        let cleanName = (try? normalizedCollection(name)) ?? TaskStore.defaultCollection
        let migratedName = renameMap[cleanName] ?? cleanName
        if result[migratedName] == nil {
            result[migratedName] = value
        }
    }

    return result
}

func sortedCollectionNames<S: Sequence>(_ collections: S) -> [String] where S.Element == String {
    let names = normalizedCollectionList(collections)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    return names.filter { $0 == TaskStore.defaultCollection }
        + names.filter { $0 != TaskStore.defaultCollection }
}

func makeCollectionSummaries(in file: TaskFile) -> [TaskCollectionSummary] {
    let grouped = Dictionary(grouping: file.items, by: \.collection)

    return sortedCollectionNames(file.collections + grouped.keys)
        .map { name in
            collectionSummary(named: name, items: grouped[name] ?? [], in: file)
        }
}

func makeCollectionGroupSummaries(in file: TaskFile) -> [TaskCollectionGroupSummary] {
    let summariesByName = Dictionary(uniqueKeysWithValues: makeCollectionSummaries(in: file).map { ($0.name, $0) })
    return normalizedCollectionGroups(file.collectionGroups, collections: Array(summariesByName.keys))
        .map { group in
            TaskCollectionGroupSummary(
                name: group.name,
                collections: group.collections.compactMap { summariesByName[$0] }
            )
        }
}

func collectionGroupSummary(named name: String, in file: TaskFile) -> TaskCollectionGroupSummary {
    makeCollectionGroupSummaries(in: file).first { $0.name == name }
        ?? TaskCollectionGroupSummary(name: name)
}

func collectionSummary(named name: String, in file: TaskFile) -> TaskCollectionSummary {
    let items = file.items.filter { $0.collection == name }
    return collectionSummary(named: name, items: items, in: file)
}

func collectionSummary(named name: String, items: [TaskItem], in file: TaskFile) -> TaskCollectionSummary {
    let groupName = collectionGroupName(containing: name, in: file)
        ?? collectionGroupName(forCollectionAPIName: name)
    return TaskCollectionSummary(
        name: name,
        displayName: collectionDisplayName(name),
        groupName: groupName,
        totalCount: items.count,
        incompleteCount: items.filter(\.status.isIncomplete).count,
        statusIndicator: collectionStatusIndicator(for: items),
        color: collectionColor(name, in: file),
        isArchived: file.archivedCollections.contains(name),
        promptTemplate: collectionPrompt(name, in: file)
    )
}

func addCollectionIfMissing(
    _ collection: String,
    group: String? = nil,
    to file: inout TaskFile
) throws {
    let cleanCollection = try normalizedCollection(collection)
    let cleanGroup = try group.map(normalizedExplicitCollectionGroup)
        ?? collectionGroupName(forCollectionAPIName: cleanCollection)
    let collectionAlreadyExists = collectionExists(cleanCollection, in: file)
    file.collections = normalizedCollectionList(file.collections + [cleanCollection])
    if file.collectionColors[cleanCollection] == nil {
        file.collectionColors[cleanCollection] = .gray
    }

    if group != nil {
        try moveCollectionInFile(cleanCollection, toGroup: cleanGroup, in: &file)
    } else if !collectionAlreadyExists && collectionGroupName(containing: cleanCollection, in: file) == nil {
        try moveCollectionInFile(cleanCollection, toGroup: cleanGroup, in: &file)
    } else {
        normalizeCollectionGroups(in: &file)
    }
}

func addCollectionGroupIfMissing(_ group: String, to file: inout TaskFile) {
    normalizeCollectionGroups(in: &file)
    if !file.collectionGroups.contains(where: { $0.name == group }) {
        file.collectionGroups.append(TaskCollectionGroup(name: group, collections: []))
    }
}

func normalizeCollectionGroups(in file: inout TaskFile) {
    file.collectionGroups = normalizedCollectionGroups(file.collectionGroups, collections: file.collections + file.items.map(\.collection))
}

func moveCollectionInFile(_ collection: String, toGroup group: String, in file: inout TaskFile) throws {
    addCollectionGroupIfMissing(group, to: &file)
    removeCollectionFromGroups(collection, in: &file)
    guard let groupIndex = file.collectionGroups.firstIndex(where: { $0.name == group }) else {
        return
    }

    file.collectionGroups[groupIndex].collections.append(collection)
    file.collectionGroups[groupIndex].collections = normalizedCollectionList(file.collectionGroups[groupIndex].collections)
    normalizeCollectionGroups(in: &file)
}

func reorderCollectionInFile(
    _ collection: String,
    toGroup group: String,
    after previousName: String?,
    before nextName: String?,
    in file: inout TaskFile
) throws {
    addCollectionGroupIfMissing(group, to: &file)
    removeCollectionFromGroups(collection, in: &file)
    guard let groupIndex = file.collectionGroups.firstIndex(where: { $0.name == group }) else {
        return
    }

    var collections = file.collectionGroups[groupIndex].collections
    if let previousName, previousName != collection {
        guard let previousIndex = collections.firstIndex(of: previousName) else {
            throw TaskStoreError.collectionNotFound(previousName)
        }
        collections.insert(collection, at: previousIndex + 1)
    } else if let nextName, nextName != collection {
        guard let nextIndex = collections.firstIndex(of: nextName) else {
            throw TaskStoreError.collectionNotFound(nextName)
        }
        collections.insert(collection, at: nextIndex)
    } else {
        collections.append(collection)
    }

    file.collectionGroups[groupIndex].collections = normalizedCollectionList(collections)
    normalizeCollectionGroups(in: &file)
}

func assertCanMoveCollections(
    _ collections: [String],
    toGroup group: String,
    in file: TaskFile
) throws {
    let moving = Set(collections)
    let existingDisplayNames = Set(
        normalizedCollectionGroups(file.collectionGroups, collections: file.collections + file.items.map(\.collection))
            .first { $0.name == group }?
            .collections
            .filter { !moving.contains($0) }
            .map(collectionDisplayName) ?? []
    )

    for collection in collections where existingDisplayNames.contains(collectionDisplayName(collection)) {
        throw TaskStoreError.collectionConflict(
            collectionAPIName(groupName: group, displayName: collectionDisplayName(collection))
        )
    }
}

func renameCollectionReference(
    from oldName: String,
    to newName: String,
    in file: inout TaskFile
) throws {
    let cleanOldName = try normalizedExplicitCollection(oldName)
    let cleanNewName = try normalizedExplicitCollection(newName)
    let oldColor = file.collectionColors.removeValue(forKey: cleanOldName)
    let oldPrompt = file.collectionPrompts.removeValue(forKey: cleanOldName)
    let wasArchived = file.archivedCollections.remove(cleanOldName) != nil
    let newGroup = collectionGroupName(forCollectionAPIName: cleanNewName)
    for index in file.items.indices where file.items[index].collection == cleanOldName {
        file.items[index].collection = cleanNewName
    }

    file.collections.removeAll { $0 == cleanOldName }
    file.collections = normalizedCollectionList(file.collections + [cleanNewName])
    removeCollectionFromGroups(cleanOldName, in: &file)
    addCollectionGroupIfMissing(newGroup, to: &file)
    if let groupIndex = file.collectionGroups.firstIndex(where: { $0.name == newGroup }) {
        file.collectionGroups[groupIndex].collections = normalizedCollectionList(
            file.collectionGroups[groupIndex].collections + [cleanNewName]
        )
    }
    if file.collectionColors[cleanNewName] == nil {
        file.collectionColors[cleanNewName] = oldColor ?? .gray
    }
    if file.collectionPrompts[cleanNewName] == nil, let oldPrompt {
        file.collectionPrompts[cleanNewName] = oldPrompt
    }
    if wasArchived {
        file.archivedCollections.insert(cleanNewName)
    }
    normalizeCollectionGroups(in: &file)
}

func removeCollectionFromGroups(_ collection: String, in file: inout TaskFile) {
    for index in file.collectionGroups.indices {
        file.collectionGroups[index].collections.removeAll { $0 == collection }
    }
}

func collectionGroupName(containing collection: String, in file: TaskFile) -> String? {
    normalizedCollectionGroups(file.collectionGroups, collections: file.collections + file.items.map(\.collection))
        .first { $0.collections.contains(collection) }?
        .name
}

func collectionStatusIndicator(for items: [TaskItem]) -> TaskStatus? {
    if items.contains(where: { $0.status == .aborted }) {
        return .aborted
    }

    if items.contains(where: { $0.status == .rejected }) {
        return .rejected
    }

    if items.contains(where: { $0.status == .onHold }) {
        return .onHold
    }

    return nil
}

func collectionExists(_ collection: String, in file: TaskFile) -> Bool {
    file.collections.contains(collection)
        || file.items.contains { $0.collection == collection }
}

func collectionColor(_ collection: String, in file: TaskFile) -> TaskCollectionColor {
    file.collectionColors[collection] ?? .gray
}

func collectionPrompt(_ collection: String, in file: TaskFile) -> String? {
    file.collectionPrompts[collection]
}

func normalizedCollectionMetadata<Value>(
    _ metadata: [String: Value],
    collections: [String],
    keep: (Value) -> Value? = { $0 },
    fill: (String) -> Value? = { _ in nil }
) -> [String: Value] {
    let names = normalizedCollectionList(collections)
    let nameSet = Set(names)
    var result: [String: Value] = [:]

    for (name, value) in metadata {
        let cleanName = (try? normalizedCollection(name)) ?? TaskStore.defaultCollection
        guard nameSet.contains(cleanName), result[cleanName] == nil, let kept = keep(value) else {
            continue
        }

        result[cleanName] = kept
    }

    for name in names where result[name] == nil {
        if let filled = fill(name) {
            result[name] = filled
        }
    }

    return result
}

func normalizedCollectionColors(
    _ colors: [String: TaskCollectionColor],
    collections: [String]
) -> [String: TaskCollectionColor] {
    normalizedCollectionMetadata(colors, collections: collections, fill: { _ in .gray })
}

func normalizedCollectionPrompts(
    _ prompts: [String: String],
    collections: [String]
) -> [String: String] {
    normalizedCollectionMetadata(prompts, collections: collections, keep: normalizedPromptTemplateOrNil)
}

func normalizedPromptTemplateOrNil(_ promptTemplate: String?) -> String? {
    guard let promptTemplate else {
        return nil
    }

    return promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : promptTemplate
}

func normalizedSearchOrNil(_ search: String?) -> String? {
    guard let search else {
        return nil
    }

    let clean = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? nil : clean
}

func currentErrnoMessage() -> String {
    String(cString: strerror(errno))
}
