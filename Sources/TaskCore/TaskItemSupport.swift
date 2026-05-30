import Foundation

func resolveIndex(_ id: String, in items: [TaskItem]) throws -> Int {
    if let exact = items.firstIndex(where: { $0.id == id }) {
        return exact
    }

    let matches = items.enumerated().filter { $0.element.id.hasPrefix(id) }
    guard !matches.isEmpty else {
        throw TaskStoreError.notFound(id)
    }

    guard matches.count == 1, let match = matches.first else {
        throw TaskStoreError.ambiguousID(id, matches.map(\.element.id))
    }

    return match.offset
}

let idCharacters = Set("0123456789abcdef")

func isValidID(_ id: String) -> Bool {
    id.count == 8 && id.allSatisfy(idCharacters.contains)
}

func normalizedNewTitle(_ title: String) -> String {
    normalizedExistingTitle(title).trimmingCharacters(in: .whitespacesAndNewlines)
}

func normalizedExistingTitle(_ title: String) -> String {
    title
}

struct NormalizedNoteInput {
    var body: String
}

struct NormalizedNoteUpdate {
    var body: String?
}

func normalizedNoteInput(body: String) throws -> NormalizedNoteInput {
    let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanBody.isEmpty else {
        throw TaskStoreError.invalidNote
    }

    return NormalizedNoteInput(body: cleanBody)
}

func normalizedNoteUpdate(body: String?) throws -> NormalizedNoteUpdate {
    guard body != nil else {
        throw TaskStoreError.missingNoteUpdate
    }

    let cleanBody = try body.map { try normalizedNoteField($0) }
    return NormalizedNoteUpdate(body: cleanBody)
}

func normalizedNoteField(_ field: String) throws -> String {
    let cleanField = field.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanField.isEmpty else {
        throw TaskStoreError.invalidNote
    }

    return cleanField
}

func appendNote(_ input: NormalizedNoteInput, to item: inout TaskItem, now: Date = Date()) {
    item.notes = [TaskNote(
        id: item.notes.first?.id ?? TaskStore.makeID(),
        version: TaskItem.makeVersion(),
        body: input.body,
        createdAt: now,
        updatedAt: now
    )]
}

func applyNoteUpdate(
    _ input: NormalizedNoteUpdate,
    noteID: String?,
    to item: inout TaskItem
) throws -> Bool {
    let index: Int
    if let noteID {
        index = try resolveNoteIndex(noteID, in: item.notes)
    } else {
        guard !item.notes.isEmpty else {
            return false
        }
        index = 0
    }

    guard let body = input.body, item.notes[index].body != body else {
        return false
    }

    item.notes[index].body = body
    item.notes[index].updatedAt = Date()
    refreshNoteVersion(at: index, in: &item.notes)
    return true
}

func removeNote(noteID: String, from item: inout TaskItem) throws {
    let index = try resolveNoteIndex(noteID, in: item.notes)
    item.notes.remove(at: index)
}

func resolveNoteIndex(_ id: String, in notes: [TaskNote]) throws -> Int {
    guard let index = notes.firstIndex(where: { $0.id == id }) else {
        throw TaskStoreError.noteNotFound(id)
    }

    return index
}

func refreshNoteVersion(at index: Int, in notes: inout [TaskNote]) {
    var existingVersions = Set(notes.map(\.version))
    existingVersions.remove(notes[index].version)
    notes[index].version = TaskItem.makeVersion(existing: existingVersions)
}

