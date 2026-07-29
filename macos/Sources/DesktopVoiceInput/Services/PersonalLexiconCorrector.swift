import Foundation
import os

#if SWIFT_PACKAGE
import SemanticOnnxBridge
#endif

struct PersonalLexiconResources: Sendable {
    let model: URL
    let vocabulary: URL
    let pinyin: URL
    let englishPronunciations: URL
}

enum PersonalLexiconModelManager {
    static let modelDirectoryName = "distilbert-base-multilingual-cased-onnx-int8"

    static func resolveResources() -> PersonalLexiconResources? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["GUGUTALK_SEMANTIC_MODEL_DIR"],
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: NSString(string: override).expandingTildeInPath))
        }
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        candidates.append(
            applicationSupport.appendingPathComponent("GuGuTalk", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(modelDirectoryName, isDirectory: true)
        )
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("models").appendingPathComponent(modelDirectoryName))
        }

        for directory in candidates {
            let model = directory.appendingPathComponent("model.int8.onnx")
            let vocabulary = directory.appendingPathComponent("vocab.txt")
            let pinyin = directory.appendingPathComponent("pinyin.txt")
            let englishPronunciations = directory.appendingPathComponent("cmudict.dict")
            if FileManager.default.fileExists(atPath: model.path),
               FileManager.default.fileExists(atPath: vocabulary.path),
               FileManager.default.fileExists(atPath: pinyin.path),
               FileManager.default.fileExists(atPath: englishPronunciations.path) {
                return PersonalLexiconResources(
                    model: model,
                    vocabulary: vocabulary,
                    pinyin: pinyin,
                    englishPronunciations: englishPronunciations
                )
            }
        }
        return nil
    }
}

struct PhoneticCandidate: Equatable, Sendable {
    let range: Range<Int>
    let original: String
    let replacement: String
    let phoneticDistance: Double
}

final class PhoneticCandidateFinder: @unchecked Sendable {
    private struct PhoneticToken {
        let range: Range<Int>
        let segment: Int
        let pronunciations: [String]
        let estimatedUnits: Int
    }

    private struct PreparedTerm {
        let text: String
        let pronunciations: [String]
        let estimatedUnits: Int
    }

    private let readings: [UInt32: Set<String>]
    private let englishReadings: [String: Set<String>]
    private let cacheLock = NSLock()
    private var cachedTermTexts: [String] = []
    private var cachedTerms: [PreparedTerm] = []

    init(pinyinData: String, englishPronunciationData: String = "") {
        var parsed: [UInt32: Set<String>] = [:]
        for line in pinyinData.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let codeText = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard codeText.hasPrefix("U+"),
                  let scalar = UInt32(codeText.dropFirst(2), radix: 16) else { continue }

            let valueStart = line.index(after: colon)
            let readingText = line[valueStart...].split(separator: "#", maxSplits: 1)[0]
            let values = Set(readingText.split(separator: ",").map {
                Self.pinyinPronunciation(String($0))
            }.filter { !$0.isEmpty })
            if !values.isEmpty {
                parsed[scalar] = values
            }
        }
        readings = parsed

        var parsedEnglish: [String: Set<String>] = [:]
        for rawLine in englishPronunciationData.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, !fields[0].hasPrefix(";;;") else { continue }
            var word = String(fields[0]).lowercased()
            if let variantStart = word.firstIndex(of: "(") {
                word = String(word[..<variantStart])
            }
            let pronunciation = fields.dropFirst().map {
                Self.normalizeEnglishPhoneme(String($0))
            }.filter { !$0.isEmpty }.joined(separator: " ")
            if !word.isEmpty, !pronunciation.isEmpty {
                parsedEnglish[word, default: []].insert(pronunciation)
            }
        }
        englishReadings = parsedEnglish
    }

    convenience init(pinyinURL: URL, englishPronunciationsURL: URL) throws {
        try self.init(
            pinyinData: String(contentsOf: pinyinURL, encoding: .utf8),
            englishPronunciationData: String(contentsOf: englishPronunciationsURL, encoding: .utf8)
        )
    }

    func candidates(in text: String, terms: [PersonalTerm], limit: Int = 16) -> [PhoneticCandidate] {
        let characters = Array(text)
        let tokens = tokenize(characters)
        guard !tokens.isEmpty else { return [] }

        var result: [PhoneticCandidate] = []
        var seen: Set<String> = []
        for term in preparedTerms(terms) {
            let maximumTokenCount = min(tokens.count, max(4, term.estimatedUnits + 2))
            for start in tokens.indices {
                for tokenCount in 1...maximumTokenCount {
                    let end = start + tokenCount
                    guard end <= tokens.count else { break }
                    let slice = Array(tokens[start..<end])
                    guard slice.last?.segment == slice.first?.segment else { break }

                    let range = slice[0].range.lowerBound..<slice[slice.count - 1].range.upperBound
                    let original = String(characters[range])
                    guard original.caseInsensitiveCompare(term.text) != .orderedSame else { continue }
                    let sourcePronunciations = Self.combinePronunciations(slice.map(\.pronunciations))
                    guard let distance = Self.minimumDistance(
                        sourcePronunciations,
                        term.pronunciations
                    ) else { continue }

                    let key = "\(range.lowerBound):\(range.upperBound):\(term.text.lowercased())"
                    guard seen.insert(key).inserted else { continue }
                    result.append(PhoneticCandidate(
                        range: range,
                        original: original,
                        replacement: term.text,
                        phoneticDistance: distance
                    ))
                }
            }
        }

        return Array(result.sorted {
            if $0.phoneticDistance != $1.phoneticDistance {
                return $0.phoneticDistance < $1.phoneticDistance
            }
            return $0.range.count > $1.range.count
        }.prefix(limit))
    }

    private func preparedTerms(_ terms: [PersonalTerm]) -> [PreparedTerm] {
        // Personal lists are small; rebuild their bounded pronunciation index only after an edit.
        let texts = terms.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if texts == cachedTermTexts { return cachedTerms }

        cachedTermTexts = texts
        cachedTerms = texts.compactMap { text in
            let tokens = tokenize(Array(text))
            let pronunciations = Self.combinePronunciations(tokens.map(\.pronunciations))
            guard !pronunciations.isEmpty else { return nil }
            return PreparedTerm(
                text: text,
                pronunciations: pronunciations,
                estimatedUnits: tokens.reduce(0) { $0 + $1.estimatedUnits }
            )
        }
        return cachedTerms
    }

    private func tokenize(_ characters: [Character]) -> [PhoneticToken] {
        var tokens: [PhoneticToken] = []
        var index = 0
        var segment = 0
        while index < characters.count {
            let character = characters[index]
            if Self.isASCIIWordCharacter(character) {
                var end = index + 1
                while end < characters.count, Self.isASCIIWordCharacter(characters[end]) {
                    end += 1
                }
                let word = String(characters[index..<end])
                let pronunciations = latinPronunciations(word)
                if !pronunciations.isEmpty {
                    tokens.append(PhoneticToken(
                        range: index..<end,
                        segment: segment,
                        pronunciations: pronunciations,
                        estimatedUnits: max(1, Self.splitLatinWord(word).count)
                    ))
                }
                index = end
                continue
            }

            if let scalar = character.unicodeScalars.count == 1 ? character.unicodeScalars.first : nil {
                if let values = readings[scalar.value] {
                    tokens.append(PhoneticToken(
                        range: index..<(index + 1),
                        segment: segment,
                        pronunciations: values.sorted(),
                        estimatedUnits: 1
                    ))
                } else if Self.isCJK(scalar.value) {
                    tokens.append(PhoneticToken(
                        range: index..<(index + 1),
                        segment: segment,
                        pronunciations: [String(character)],
                        estimatedUnits: 1
                    ))
                } else if let pronunciations = Self.symbolPronunciations[character] {
                    tokens.append(PhoneticToken(
                        range: index..<(index + 1),
                        segment: segment,
                        pronunciations: pronunciations,
                        estimatedUnits: 1
                    ))
                } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    if CharacterSet.punctuationCharacters.contains(scalar)
                        || CharacterSet.symbols.contains(scalar) {
                        segment += 1
                    } else {
                        let value = Self.normalizePhoneticText(String(character))
                        if !value.isEmpty {
                            tokens.append(PhoneticToken(
                                range: index..<(index + 1),
                                segment: segment,
                                pronunciations: [value],
                                estimatedUnits: 1
                            ))
                        }
                    }
                }
            }
            index += 1
        }
        return tokens
    }

    private static func minimumDistance(_ source: [String], _ target: [String]) -> Double? {
        var best = Double.greatestFiniteMagnitude
        for sourceValue in source {
            for targetValue in target {
                let sourcePhonemes = phonemes(sourceValue)
                let targetPhonemes = phonemes(targetValue)
                let longest = max(sourcePhonemes.count, targetPhonemes.count)
                let shortest = min(sourcePhonemes.count, targetPhonemes.count)
                guard longest > 0, Double(shortest) / Double(longest) >= 0.64 else { continue }
                let distance = weightedEditDistance(sourcePhonemes, targetPhonemes)
                let threshold: Double = if longest <= 3 { 0.12 } else if longest <= 5 { 0.28 } else { 0.36 }
                if distance <= threshold {
                    best = min(best, distance)
                }
            }
        }
        return best < Double.greatestFiniteMagnitude ? best : nil
    }

    private static func phonemes(_ value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func weightedEditDistance(_ left: [String], _ right: [String]) -> Double {
        var previous = Array(repeating: 0.0, count: right.count + 1)
        for index in right.indices {
            previous[index + 1] = previous[index] + insertionCost(right[index])
        }
        for leftIndex in left.indices {
            var current = Array(repeating: 0.0, count: right.count + 1)
            current[0] = previous[0] + deletionCost(left[leftIndex])
            for rightIndex in right.indices {
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + deletionCost(left[leftIndex]),
                    current[rightIndex] + insertionCost(right[rightIndex]),
                    previous[rightIndex] + substitutionCost(left[leftIndex], right[rightIndex])
                )
            }
            previous = current
        }
        return previous[right.count] / Double(max(max(left.count, right.count), 1))
    }

    private static func insertionCost(_ value: String) -> Double {
        vowelPhonemes.contains(value) ? 0.75 : 1
    }

    private static func deletionCost(_ value: String) -> Double {
        insertionCost(value)
    }

    private static func substitutionCost(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 0 }
        if vowelPhonemes.contains(lhs), vowelPhonemes.contains(rhs) { return 0.35 }
        for group in confusionGroups where group.contains(lhs) && group.contains(rhs) {
            return 0.45
        }
        return 1
    }

    private static func combinePronunciations(_ groups: [[String]], limit: Int = 48) -> [String] {
        var result = [""]
        for group in groups {
            var next: Set<String> = []
            for prefix in result {
                for pronunciation in group where !pronunciation.isEmpty {
                    next.insert(prefix.isEmpty ? pronunciation : prefix + " " + pronunciation)
                }
            }
            result = Array(next.sorted().prefix(limit))
            if result.isEmpty { break }
        }
        return result
    }

    private static func normalizePhoneticText(_ value: String) -> String {
        value.replacingOccurrences(of: "ü", with: "v")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func normalizeLatinWord(_ value: String) -> String {
        normalizePhoneticText(value).filter { $0.isLetter || $0.isNumber }
    }

    private func latinPronunciations(_ value: String) -> [String] {
        let parts = Self.splitLatinWord(value)
        var result: Set<String> = []
        let partGroups = parts.map(pronunciationsForLatinPart)
        result.formUnion(Self.combinePronunciations(partGroups))

        let key = Self.englishDictionaryKey(value)
        if let pronunciations = englishReadings[key] {
            result.formUnion(pronunciations)
        } else if !key.isEmpty {
            result.insert(Self.fallbackEnglishPronunciation(key))
        }
        return result.filter { !$0.isEmpty }.sorted()
    }

    private func pronunciationsForLatinPart(_ value: String) -> [String] {
        let normalized = Self.normalizeLatinWord(value)
        guard !normalized.isEmpty else { return [] }
        if normalized.allSatisfy(\.isNumber) {
            return Self.combinePronunciations(normalized.map { Self.digitPronunciations[$0] ?? [] })
        }
        if normalized.count == 1, let letter = normalized.first,
           let letterName = Self.letterPronunciations[letter] {
            return [letterName]
        }

        var result: Set<String> = []
        let key = Self.englishDictionaryKey(value)
        if let pronunciations = englishReadings[key] {
            result.formUnion(pronunciations)
        } else if !key.isEmpty {
            result.insert(Self.fallbackEnglishPronunciation(key))
        }
        let characters = Array(value)
        if characters.count > 1,
           characters.allSatisfy({ $0.isLetter && $0.isUppercase }) {
            let spelled = characters.map { character -> [String] in
                let normalized = Character(String(character).lowercased())
                return Self.letterPronunciations[normalized].map { [$0] } ?? []
            }
            result.formUnion(Self.combinePronunciations(spelled))
        }
        return result.filter { !$0.isEmpty }.sorted()
    }

    private static func englishDictionaryKey(_ value: String) -> String {
        normalizePhoneticText(value).filter { $0.isLetter || $0 == "'" }
    }

    private static func normalizeEnglishPhoneme(_ value: String) -> String {
        value.uppercased().filter { !$0.isNumber }
    }

    private static func fallbackEnglishPronunciation(_ value: String) -> String {
        var characters = Array(value)
        if characters.count > 2,
           (String(characters.prefix(2)) == "kn" || String(characters.prefix(2)) == "wr") {
            characters.removeFirst()
        }

        var result: [String] = []
        var index = 0
        while index < characters.count {
            if index == characters.count - 1, characters[index] == "e", characters.count > 2 {
                break
            }
            if index > 0,
               characters[index] == characters[index - 1],
               "bcdfghjklmnpqrstvwxyz".contains(characters[index]) {
                index += 1
                continue
            }

            let remainder = String(characters[index...])
            if let rule = englishDigraphRules.first(where: { remainder.hasPrefix($0.text) }) {
                result.append(contentsOf: rule.phonemes)
                index += rule.text.count
                continue
            }

            let next = index + 1 < characters.count ? characters[index + 1] : nil
            switch characters[index] {
            case "a": result.append("AE")
            case "b": result.append("B")
            case "c": result.append(next.map { "eiy".contains($0) } == true ? "S" : "K")
            case "d": result.append("D")
            case "e": result.append("EH")
            case "f": result.append("F")
            case "g": result.append(next.map { "eiy".contains($0) } == true ? "JH" : "G")
            case "h": result.append("HH")
            case "i": result.append("IH")
            case "j": result.append("JH")
            case "k": result.append("K")
            case "l": result.append("L")
            case "m": result.append("M")
            case "n": result.append("N")
            case "o": result.append("AA")
            case "p": result.append("P")
            case "q": result.append(contentsOf: ["K", "W"])
            case "r": result.append("R")
            case "s": result.append("S")
            case "t": result.append("T")
            case "u": result.append("AH")
            case "v": result.append("V")
            case "w": result.append("W")
            case "x": result.append(contentsOf: ["K", "S"])
            case "y": result.append(index == 0 ? "Y" : "IY")
            case "z": result.append("Z")
            default: break
            }
            index += 1
        }
        return result.joined(separator: " ")
    }

    private static func pinyinPronunciation(_ value: String) -> String {
        let syllable = normalizePhoneticText(value)
        guard !syllable.isEmpty else { return "" }
        if let special = specialPinyinPronunciations[syllable] { return special }

        var initial = ""
        var final = syllable
        for candidate in pinyinInitialOrder where syllable.hasPrefix(candidate) {
            initial = candidate
            final = String(syllable.dropFirst(candidate.count))
            break
        }
        var phonemes: [String] = []
        if let initialPhoneme = pinyinInitials[initial], !initialPhoneme.isEmpty {
            phonemes.append(contentsOf: initialPhoneme.split(separator: " ").map(String.init))
        }
        if final == "i", ["z", "c", "s", "zh", "ch", "sh", "r"].contains(initial) {
            phonemes.append("IH")
        } else if let finalPhonemes = pinyinFinals[final] {
            phonemes.append(contentsOf: finalPhonemes.split(separator: " ").map(String.init))
        } else {
            phonemes.append(contentsOf: fallbackEnglishPronunciation(final).split(separator: " ").map(String.init))
        }
        return phonemes.joined(separator: " ")
    }

    private static func splitLatinWord(_ value: String) -> [String] {
        let characters = Array(value)
        guard !characters.isEmpty else { return [] }
        var result: [String] = []
        var start = 0
        for index in 1..<characters.count {
            let previous = characters[index - 1]
            let current = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let lowerToUpper = previous.isLowercase && current.isUppercase
            let acronymBoundary = previous.isUppercase && current.isUppercase && next?.isLowercase == true
            let digitBoundary = previous.isNumber != current.isNumber
                && (previous.isLetter || current.isLetter)
            if lowerToUpper || acronymBoundary || digitBoundary {
                result.append(String(characters[start..<index]))
                start = index
            }
        }
        result.append(String(characters[start...]))
        return result
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0.value == 39)
        }
    }

    private static func isCJK(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x323AF).contains(value)
    }

    private static let vowelPhonemes: Set<String> = [
        "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY",
        "IH", "IY", "OW", "OY", "UH", "UW"
    ]
    private static let confusionGroups: [Set<String>] = [
        ["G", "K"], ["B", "P"], ["D", "T"], ["N", "L", "R"],
        ["F", "HH"], ["S", "SH", "Z", "ZH"], ["CH", "JH"], ["M", "N"]
    ]
    private static let letterPronunciations: [Character: String] = [
        "a": "EY", "b": "B IY", "c": "S IY", "d": "D IY", "e": "IY", "f": "EH F",
        "g": "JH IY", "h": "EY CH", "i": "AY", "j": "JH EY", "k": "K EY", "l": "EH L",
        "m": "EH M", "n": "EH N", "o": "OW", "p": "P IY", "q": "K Y UW", "r": "AA R",
        "s": "EH S", "t": "T IY", "u": "Y UW", "v": "V IY", "w": "D AH B AH L Y UW",
        "x": "EH K S", "y": "W AY", "z": "Z IY"
    ]
    private static let digitPronunciations: [Character: [String]] = [
        "0": ["L IH NG", "Z IH R OW"], "1": ["IY", "W AH N"],
        "2": ["ER", "T UW"], "3": ["S AA N", "TH R IY"],
        "4": ["F AO R", "S IH"], "5": ["F AY V", "UW"],
        "6": ["L Y OW", "S IH K S"], "7": ["CH IY", "S EH V AH N"],
        "8": ["B AA", "EY T"], "9": ["JH Y OW", "N AY N"]
    ]
    private static let symbolPronunciations: [Character: [String]] = [
        "+": ["JH Y AA", "P L AH S"],
        "#": ["HH AE SH", "JH IH NG HH AW", "SH AA R P"],
        "&": ["AE N D", "HH AH"], "@": ["AE T", "AY T AH"],
        "%": ["B AY F AH N HH AW", "P ER S EH N T"],
        "-": ["D AE SH", "HH AH NG G AA NG", "JH Y EH N", "M AY N AH S"],
        ".": ["D AA T", "D Y EH N"]
    ]
    private static let englishDigraphRules: [(text: String, phonemes: [String])] = [
        ("tion", ["SH", "AH", "N"]), ("sion", ["ZH", "AH", "N"]),
        ("tch", ["CH"]), ("igh", ["AY"]), ("ch", ["CH"]), ("sh", ["SH"]),
        ("th", ["TH"]), ("ph", ["F"]), ("ng", ["NG"]),
        ("qu", ["K", "W"]), ("qw", ["K", "W"]), ("ck", ["K"]),
        ("wh", ["W"]), ("ee", ["IY"]), ("ea", ["IY"]), ("oo", ["UW"]),
        ("ai", ["EY"]), ("ay", ["EY"]), ("oa", ["OW"]),
        ("ou", ["AW"]), ("ow", ["AW"]), ("oi", ["OY"]), ("oy", ["OY"]),
        ("er", ["ER"]), ("ar", ["AA", "R"]), ("or", ["AO", "R"]),
        ("au", ["AO"]), ("aw", ["AO"])
    ]
    private static let pinyinInitialOrder = [
        "zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l",
        "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", "y", "w"
    ]
    private static let pinyinInitials: [String: String] = [
        "": "", "b": "B", "p": "P", "m": "M", "f": "F", "d": "D", "t": "T",
        "n": "N", "l": "L", "g": "G", "k": "K", "h": "HH", "j": "JH",
        "q": "CH", "x": "SH", "zh": "JH", "ch": "CH", "sh": "SH", "r": "R",
        "z": "Z", "c": "T S", "s": "S", "y": "Y", "w": "W"
    ]
    private static let pinyinFinals: [String: String] = [
        "a": "AA", "o": "AO", "e": "AH", "ai": "AY", "ei": "EY", "ao": "AW",
        "ou": "OW", "an": "AE N", "en": "AH N", "ang": "AA NG", "eng": "AH NG",
        "er": "ER", "i": "IY", "ia": "Y AA", "ie": "Y EH", "iao": "Y AW",
        "iu": "Y OW", "ian": "Y EH N", "in": "IY N", "iang": "Y AA NG",
        "ing": "IY NG", "iong": "Y UH NG", "u": "UW", "ua": "W AA",
        "uo": "W AO", "uai": "W AY", "ui": "W EY", "uan": "W AA N",
        "un": "W AH N", "uang": "W AA NG", "ueng": "W AH NG", "ong": "UH NG",
        "v": "Y UW", "ve": "Y EH", "ue": "Y EH", "van": "Y EH N", "vn": "Y UW N"
    ]
    private static let specialPinyinPronunciations: [String: String] = [
        "yi": "IY", "ya": "Y AA", "ye": "Y EH", "yao": "Y AW", "you": "Y OW",
        "yan": "Y AE N", "yang": "Y AA NG", "yin": "IY N", "ying": "IY NG",
        "yong": "Y UH NG", "yu": "Y UW", "yue": "Y EH", "yuan": "Y EH N",
        "yun": "Y UW N", "wu": "UW", "wa": "W AA", "wo": "W AO",
        "wai": "W AY", "wei": "W EY", "wan": "W AA N", "wang": "W AA NG",
        "wen": "W AH N", "weng": "W AH NG"
    ]
}

private struct MaskedLanguageModelInput {
    let inputIDs: [Int64]
    let attentionMask: [Int64]
    let targetPositions: [Int64]
    let targetTokenIDs: [Int64]
}

private struct WordPieceTokenizer {
    private let vocabulary: [String: Int64]
    private let unknownTokenID: Int64
    private let classificationTokenID: Int64
    private let separatorTokenID: Int64
    private let maskTokenID: Int64

    init(vocabularyURL: URL) throws {
        let contents = try String(contentsOf: vocabularyURL, encoding: .utf8)
        var parsed: [String: Int64] = [:]
        for (index, token) in contents.components(separatedBy: .newlines).enumerated() where !token.isEmpty {
            parsed[token] = Int64(index)
        }
        guard let unknown = parsed["[UNK]"],
              let classification = parsed["[CLS]"],
              let separator = parsed["[SEP]"],
              let mask = parsed["[MASK]"] else {
            throw PersonalLexiconError.invalidVocabulary
        }
        vocabulary = parsed
        unknownTokenID = unknown
        classificationTokenID = classification
        separatorTokenID = separator
        maskTokenID = mask
    }

    func makeMaskedInput(prefix: String, target: String, suffix: String) -> MaskedLanguageModelInput? {
        let targetIDs = tokenize(target)
        guard !targetIDs.isEmpty, targetIDs.count <= 16 else { return nil }
        let prefixIDs = tokenize(prefix)
        let suffixIDs = tokenize(suffix)
        let contextBudget = 96 - 2 - targetIDs.count
        guard contextBudget >= 0 else { return nil }

        var leftCount = min(prefixIDs.count, contextBudget / 2)
        var rightCount = min(suffixIDs.count, contextBudget - leftCount)
        var remaining = contextBudget - leftCount - rightCount
        if remaining > 0 {
            let extraLeft = min(prefixIDs.count - leftCount, remaining)
            leftCount += extraLeft
            remaining -= extraLeft
        }
        if remaining > 0 {
            rightCount += min(suffixIDs.count - rightCount, remaining)
        }

        var ids = [classificationTokenID]
        ids.append(contentsOf: prefixIDs.suffix(leftCount))
        let firstTargetPosition = ids.count
        ids.append(contentsOf: repeatElement(maskTokenID, count: targetIDs.count))
        ids.append(contentsOf: suffixIDs.prefix(rightCount))
        ids.append(separatorTokenID)

        return MaskedLanguageModelInput(
            inputIDs: ids,
            attentionMask: Array(repeating: 1, count: ids.count),
            targetPositions: (0..<targetIDs.count).map { Int64(firstTargetPosition + $0) },
            targetTokenIDs: targetIDs
        )
    }

    private func tokenize(_ text: String) -> [Int64] {
        basicTokens(text).flatMap(wordPiece)
    }

    private func basicTokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }

        for character in text {
            guard let scalar = character.unicodeScalars.count == 1 ? character.unicodeScalars.first : nil else {
                flush()
                result.append(String(character))
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                flush()
            } else if isCJK(scalar.value)
                        || CharacterSet.punctuationCharacters.contains(scalar)
                        || CharacterSet.symbols.contains(scalar) {
                flush()
                result.append(String(character))
            } else {
                current.append(character)
            }
        }
        flush()
        return result
    }

    private func wordPiece(_ token: String) -> [Int64] {
        if let exact = vocabulary[token] { return [exact] }
        let characters = Array(token)
        guard characters.count <= 100 else { return [unknownTokenID] }

        var result: [Int64] = []
        var start = 0
        while start < characters.count {
            var end = characters.count
            var match: Int64?
            while start < end {
                var piece = String(characters[start..<end])
                if start > 0 { piece = "##" + piece }
                if let tokenID = vocabulary[piece] {
                    match = tokenID
                    break
                }
                end -= 1
            }
            guard let match else { return [unknownTokenID] }
            result.append(match)
            start = end
        }
        return result
    }

    private func isCJK(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x323AF).contains(value)
    }
}

private final class SemanticOnnxSession {
    private let handle: OpaquePointer

    init(modelURL: URL) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let created = modelURL.path.withCString {
            gugu_semantic_session_create($0, &errorPointer)
        }
        guard let created else {
            throw PersonalLexiconError.onnx(Self.consumeError(&errorPointer))
        }
        if let errorPointer { gugu_semantic_error_free(errorPointer) }
        handle = created
    }

    deinit {
        gugu_semantic_session_destroy(handle)
    }

    func score(_ input: MaskedLanguageModelInput) throws -> Double {
        var result = 0.0
        var errorPointer: UnsafeMutablePointer<CChar>?
        let succeeded = input.inputIDs.withUnsafeBufferPointer { inputIDs in
            input.attentionMask.withUnsafeBufferPointer { attentionMask in
                input.targetPositions.withUnsafeBufferPointer { positions in
                    input.targetTokenIDs.withUnsafeBufferPointer { tokenIDs in
                        gugu_semantic_score_masked_tokens(
                            handle,
                            inputIDs.baseAddress,
                            attentionMask.baseAddress,
                            Int64(input.inputIDs.count),
                            positions.baseAddress,
                            tokenIDs.baseAddress,
                            Int64(input.targetTokenIDs.count),
                            &result,
                            &errorPointer
                        )
                    }
                }
            }
        }
        guard succeeded != 0 else {
            throw PersonalLexiconError.onnx(Self.consumeError(&errorPointer))
        }
        if let errorPointer { gugu_semantic_error_free(errorPointer) }
        return result
    }

    private static func consumeError(_ pointer: inout UnsafeMutablePointer<CChar>?) -> String {
        guard let value = pointer else { return "Unknown ONNX Runtime error" }
        let message = String(cString: value)
        gugu_semantic_error_free(value)
        pointer = nil
        return message
    }
}

private enum PersonalLexiconError: LocalizedError {
    case invalidVocabulary
    case onnx(String)

    var errorDescription: String? {
        switch self {
        case .invalidVocabulary: "个性词语义模型的词表无效。"
        case .onnx(let message): "个性词语义评分失败：\(message)"
        }
    }
}

actor PersonalLexiconCorrector {
    private static let logger = Logger(subsystem: "com.end.DesktopVoiceInput", category: "PersonalLexicon")
    private var resources: PersonalLexiconResources?
    private var candidateFinder: PhoneticCandidateFinder?
    private var tokenizer: WordPieceTokenizer?
    private var session: SemanticOnnxSession?
    private var didAttemptResourceLoad = false

    func correct(_ text: String, terms: [PersonalTerm]) async -> String {
        guard !text.isEmpty, !terms.isEmpty else { return text }
        do {
            guard let resources = try loadLightweightResources() else { return text }
            guard let candidateFinder else { return text }
            let candidates = candidateFinder.candidates(in: text, terms: terms)
            guard !candidates.isEmpty else { return text }

            let characters = Array(text)
            var accepted: [(candidate: PhoneticCandidate, combinedScore: Double)] = []

            for candidate in candidates {
                if Task.isCancelled { return text }
                if Self.shouldHonorPersonalSpelling(candidate) {
                    accepted.append((candidate, 3.2 - candidate.phoneticDistance * 3.0))
                    continue
                }

                let tokenizer = try loadTokenizer(resources: resources)
                let session = try loadSession(resources: resources)
                let prefix = String(characters[..<candidate.range.lowerBound])
                let suffix = String(characters[candidate.range.upperBound...])
                guard let originalInput = tokenizer.makeMaskedInput(
                    prefix: prefix, target: candidate.original, suffix: suffix
                ), let replacementInput = tokenizer.makeMaskedInput(
                    prefix: prefix, target: candidate.replacement, suffix: suffix
                ) else { continue }

                let originalScore = try session.score(originalInput)
                let replacementScore = try session.score(replacementInput)
                let semanticDelta = replacementScore - originalScore
                let personalTermPrior = 2.6 - candidate.phoneticDistance * 3.0
                let combined = semanticDelta + personalTermPrior
                if semanticDelta >= -4.5, combined >= 0 {
                    accepted.append((candidate, combined))
                }
            }

            let selected = selectNonOverlapping(accepted)
            guard !selected.isEmpty else { return text }
            var output = characters
            for item in selected.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                output.replaceSubrange(item.range, with: Array(item.replacement))
            }
            return String(output)
        } catch {
            Self.logger.error("Personal lexicon correction skipped. error=\(error.localizedDescription, privacy: .public)")
            return text
        }
    }

    private static func shouldHonorPersonalSpelling(_ candidate: PhoneticCandidate) -> Bool {
        // A masked LM often underrates rare names and code-like spellings even when pronunciation is strong.
        guard candidate.phoneticDistance <= 0.30 else { return false }
        let replacement = candidate.replacement.lowercased().filter { !$0.isWhitespace }
        let original = candidate.original.lowercased().filter { !$0.isWhitespace }
        let hasFormattingSensitiveCharacter = replacement.unicodeScalars.contains {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0)
                || CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0))
        }
        if hasFormattingSensitiveCharacter { return true }
        if !Set(replacement).isDisjoint(with: Set(original)) { return true }
        return candidate.phoneticDistance <= 0.08
            && replacement.count >= 3
            && original.count >= 3
    }

    private func loadLightweightResources() throws -> PersonalLexiconResources? {
        if let resources, candidateFinder != nil { return resources }
        guard !didAttemptResourceLoad else { return nil }
        didAttemptResourceLoad = true
        guard let resolved = PersonalLexiconModelManager.resolveResources() else {
            Self.logger.warning("Personal lexicon resources are unavailable; semantic correction is disabled")
            return nil
        }
        resources = resolved
        candidateFinder = try PhoneticCandidateFinder(
            pinyinURL: resolved.pinyin,
            englishPronunciationsURL: resolved.englishPronunciations
        )
        return resolved
    }

    private func loadTokenizer(resources: PersonalLexiconResources) throws -> WordPieceTokenizer {
        if let tokenizer { return tokenizer }
        let loaded = try WordPieceTokenizer(vocabularyURL: resources.vocabulary)
        tokenizer = loaded
        return loaded
    }

    private func loadSession(resources: PersonalLexiconResources) throws -> SemanticOnnxSession {
        if let session { return session }
        let loaded = try SemanticOnnxSession(modelURL: resources.model)
        session = loaded
        return loaded
    }

    private func selectNonOverlapping(
        _ candidates: [(candidate: PhoneticCandidate, combinedScore: Double)]
    ) -> [PhoneticCandidate] {
        var selected: [PhoneticCandidate] = []
        for item in candidates.sorted(by: {
            if $0.candidate.phoneticDistance != $1.candidate.phoneticDistance {
                return $0.candidate.phoneticDistance < $1.candidate.phoneticDistance
            }
            if $0.combinedScore != $1.combinedScore { return $0.combinedScore > $1.combinedScore }
            return $0.candidate.range.count > $1.candidate.range.count
        }) {
            if selected.allSatisfy({ !$0.range.overlaps(item.candidate.range) }) {
                selected.append(item.candidate)
            }
        }
        return selected
    }
}
