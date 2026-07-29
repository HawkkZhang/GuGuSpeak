import Foundation

struct TextReplacement: Codable, Identifiable, Equatable, Sendable {
    var id: String { from }
    var from: String
    var to: String
}

struct PersonalTerm: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var aliases: [String]

    init(id: UUID = UUID(), text: String, aliases: [String] = []) {
        self.id = id
        self.text = text
        self.aliases = aliases
    }
}

private struct PersonalLexiconDocument: Codable {
    let version: Int
    let terms: [PersonalTerm]
}

@MainActor
final class HotwordStore: ObservableObject {
    @Published private(set) var terms: [PersonalTerm] = []

    private static let storageKey = "personalLexicon"
    private static let legacyStorageKey = "textReplacements"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    var isEmpty: Bool { terms.isEmpty }

    var replacements: [TextReplacement] {
        terms.flatMap { term in
            term.aliases.map { TextReplacement(from: $0, to: term.text) }
        }
    }

    func addTerm(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !terms.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return
        }

        terms.append(PersonalTerm(text: trimmed))
        sortAndSave()
    }

    func removeTerm(id: UUID) {
        terms.removeAll { $0.id == id }
        save()
    }

    // Kept for migration-compatible callers and exact aliases added by older builds.
    func add(from: String, to: String) {
        let trimmedFrom = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTo = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFrom.isEmpty, !trimmedTo.isEmpty else { return }

        if let index = terms.firstIndex(where: { $0.text.caseInsensitiveCompare(trimmedTo) == .orderedSame }) {
            guard !terms[index].aliases.contains(where: {
                $0.caseInsensitiveCompare(trimmedFrom) == .orderedSame
            }) else { return }
            terms[index].aliases.append(trimmedFrom)
        } else {
            terms.append(PersonalTerm(text: trimmedTo, aliases: [trimmedFrom]))
        }
        sortAndSave()
    }

    func remove(_ from: String) {
        for index in terms.indices {
            terms[index].aliases.removeAll { $0 == from }
        }
        terms.removeAll { $0.aliases.isEmpty && $0.text == from }
        save()
    }

    func applyReplacements(to text: String) -> String {
        var result = text
        let matches = terms.flatMap { term in
            ([term.text] + term.aliases).map { (pattern: $0, replacement: term.text) }
        }.sorted { $0.pattern.count > $1.pattern.count }

        for match in matches where !match.pattern.isEmpty {
            result = result.replacingOccurrences(
                of: match.pattern,
                with: match.replacement,
                options: .caseInsensitive
            )
        }
        return result
    }

    private func load() {
        if let data = defaults.data(forKey: Self.storageKey) {
            if let document = try? JSONDecoder().decode(PersonalLexiconDocument.self, from: data) {
                terms = normalizedTerms(document.terms)
                return
            }
            if let decoded = try? JSONDecoder().decode([PersonalTerm].self, from: data) {
                terms = normalizedTerms(decoded)
                return
            }
        }

        guard let legacyData = defaults.data(forKey: Self.legacyStorageKey),
              let legacy = try? JSONDecoder().decode([TextReplacement].self, from: legacyData) else {
            return
        }

        var migrated: [PersonalTerm] = []
        for replacement in legacy {
            let canonical = replacement.to.trimmingCharacters(in: .whitespacesAndNewlines)
            let alias = replacement.from.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty, !alias.isEmpty else { continue }

            if let index = migrated.firstIndex(where: {
                $0.text.caseInsensitiveCompare(canonical) == .orderedSame
            }) {
                if !migrated[index].aliases.contains(where: {
                    $0.caseInsensitiveCompare(alias) == .orderedSame
                }) {
                    migrated[index].aliases.append(alias)
                }
            } else {
                migrated.append(PersonalTerm(text: canonical, aliases: [alias]))
            }
        }

        terms = normalizedTerms(migrated)
        save()
    }

    private func normalizedTerms(_ input: [PersonalTerm]) -> [PersonalTerm] {
        var result: [PersonalTerm] = []
        for var term in input {
            term.text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.text.isEmpty else { continue }
            term.aliases = Array(Set(term.aliases.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })).sorted()

            if let index = result.firstIndex(where: {
                $0.text.caseInsensitiveCompare(term.text) == .orderedSame
            }) {
                result[index].aliases = Array(Set(result[index].aliases + term.aliases)).sorted()
            } else {
                result.append(term)
            }
        }
        return result.sorted { $0.text.localizedCompare($1.text) == .orderedAscending }
    }

    private func sortAndSave() {
        terms.sort { $0.text.localizedCompare($1.text) == .orderedAscending }
        save()
    }

    private func save() {
        let document = PersonalLexiconDocument(version: 2, terms: terms)
        guard let data = try? JSONEncoder().encode(document) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
