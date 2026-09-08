import Foundation

struct NineKeyPinyinResult {
    let candidates: [String]
    let fixedText: String
    let remainingDigits: String
    let isComplete: Bool
    let commitText: String
    let spellingOptions: [String]
    let displayPinyin: String
}

/// Real T9 decoding: a bounded graph of spellings from the AOSP dictionary,
/// reranked using that decoder's native candidate costs. No phrase shortcuts.
@MainActor
final class NineKeyPinyinDecoder {
    static let maximumInputLength = 64
    static let maximumCandidateCount = 40
    private static let segmentLength = 24
    private static let beamWidth = 48
    private static let maximumProbes = 64

    private struct Spelling {
        let text: String
        let code: String
        let cost: Double
    }
    private struct Path {
        let pinyin: String
        let firstSpelling: String
        let syllables: Int
        let prior: Double
        let offsets: [Int] // pinyin byte offset -> original suffix byte offset
        let rawEnd: Int
    }
    private struct Choice {
        let text: String
        let display: String
        let pinyin: String
        let consumed: Int
        let offsets: [Int]
        let cost: Double
        let whole: Bool
    }
    private enum SpellingConstraint {
        case initial(String)
        case syllable(String)

        func accepts(_ spelling: String) -> Bool {
            switch self {
            case .initial(let prefix): return spelling.hasPrefix(prefix)
            case .syllable(let text): return spelling == text
            }
        }
    }

    private let decoder: PinyinDecoder
    private var fullByCode: [String: [Spelling]] = [:]
    private var prefixByCode: [String: [Spelling]] = [:]
    private var fullSpellings = Set<String>()
    private var digits = ""
    private var fixedDigits = ""
    private var fixedText = ""
    private var lockedSpelling: SpellingConstraint?
    private var lockedInputPrefix = ""
    private var choices: [Choice] = []
    private var result: NineKeyPinyinResult?
    private var probes: [String: PinyinProbeResult] = [:]
    private var probeOrder: [String] = []

    init(pinyinDecoder: PinyinDecoder) {
        decoder = pinyinDecoder
        var prefixes: [String: [String: Spelling]] = [:]
        for item in decoder.spellingTable() {
            let text = item.text.lowercased()
            guard let code = Self.code(for: text) else { continue }
            let spelling = Spelling(text: text, code: code, cost: item.score)
            fullByCode[code, default: []].append(spelling)
            fullSpellings.insert(text)
            for length in 1...text.count {
                let prefix = String(text.prefix(length))
                let prefixCode = String(code.prefix(length))
                let value = Spelling(text: prefix, code: prefixCode,
                                     cost: item.score + (length == text.count ? 0 : 35))
                if value.cost < (prefixes[prefixCode]?[prefix]?.cost ?? .infinity) {
                    prefixes[prefixCode, default: [:]][prefix] = value
                }
            }
        }
        for (code, values) in prefixes {
            prefixByCode[code] = values.values.sorted { ($0.cost, $0.text) < ($1.cost, $1.text) }
        }
        for code in Array(fullByCode.keys) {
            fullByCode[code]?.sort { ($0.cost, $0.text) < ($1.cost, $1.text) }
        }
    }

    func reset() {
        digits = ""
        fixedDigits = ""
        fixedText = ""
        lockedSpelling = nil
        lockedInputPrefix = ""
        choices = []
        result = nil
        // The wrapped decoder can also serve QWERTY after a mode switch.
        decoder.reset()
    }

    func update(digits input: String) -> NineKeyPinyinResult {
        digits = input
        guard input.utf8.count <= Self.maximumInputLength,
              input.utf8.allSatisfy({ (50...57).contains($0) || $0 == 39 }) else {
            fixedDigits = ""
            fixedText = ""
            lockedSpelling = nil
            choices = []
            return publish(remaining: input)
        }
        if !input.hasPrefix(fixedDigits) {
            fixedDigits = ""
            fixedText = ""
            lockedSpelling = nil
        }
        if !lockedInputPrefix.isEmpty && !input.hasPrefix(lockedInputPrefix) {
            lockedSpelling = nil
            lockedInputPrefix = ""
        }
        return rebuild()
    }

    /// Restricts the first unselected syllable; it does not consume digits or
    /// commit Chinese. A partial initial remains a prefix when more keys arrive.
    func selectSpelling(at index: Int) -> NineKeyPinyinResult {
        guard let previous = result, previous.spellingOptions.indices.contains(index) else {
            return result ?? publish(remaining: remaining)
        }
        let spelling = previous.spellingOptions[index]
        // AOSP includes M/N as standalone interjections. In the disambiguation
        // row a one-letter consonant means an initial that can still grow;
        // dictionary membership alone must not force a syllable boundary.
        // An apostrophe remains available to end that syllable explicitly.
        let isConsonantInitial = spelling.utf8.count == 1 && !["a", "e", "o"].contains(spelling)
        lockedSpelling = isConsonantInitial || !fullSpellings.contains(spelling)
            ? .initial(spelling) : .syllable(spelling)
        let count = spelling.utf8.count
        lockedInputPrefix = String(digits.prefix(fixedDigits.count + count))
        return rebuild()
    }

    func selectCandidate(at index: Int) -> NineKeyPinyinResult {
        guard result?.isComplete != true, choices.indices.contains(index) else {
            return publish(remaining: remaining)
        }
        let choice = choices[index]
        if choice.pinyin.isEmpty {
            choices = []
            return publish(remaining: remaining, complete: true, commit: fixedText)
        }
        // Read-only probes never learn. Only an explicit candidate selection
        // reaches im_choose, and its text is rechecked against fresh candidates.
        decoder.reset()
        let fresh = decoder.update(pinyin: choice.pinyin)
        guard let nativeIndex = fresh.candidates.firstIndex(of: choice.text) else {
            clearProbes()
            return rebuild()
        }
        let selected = decoder.selectCandidate(at: nativeIndex)
        let text = selected.isComplete ? selected.commitText : selected.fixedText
        let selectedBytes = choice.pinyin.utf8.count - selected.remainingPinyin.utf8.count
        guard text == choice.text, selectedBytes > 0, selectedBytes < choice.offsets.count else {
            clearProbes()
            return rebuild()
        }
        let consumed = choice.offsets[selectedBytes]
        guard consumed > 0, consumed <= remaining.count else { return rebuild() }
        let oldRemaining = remaining
        fixedText += text
        fixedDigits += String(oldRemaining.prefix(consumed))
        lockedSpelling = nil
        lockedInputPrefix = ""
        clearProbes()
        decoder.reset()
        if choice.whole || remaining.isEmpty {
            choices = []
            return publish(remaining: remaining, complete: true, commit: fixedText)
        }
        return rebuild()
    }

    private var remaining: String { String(digits.dropFirst(fixedDigits.count)) }

    private func publish(remaining: String, complete: Bool = false, commit: String = "",
                         spellings: [String] = [], display: String = "") -> NineKeyPinyinResult {
        let snapshot = NineKeyPinyinResult(candidates: choices.map(\.display), fixedText: fixedText,
            remainingDigits: remaining, isComplete: complete, commitText: commit,
            spellingOptions: spellings, displayPinyin: display)
        result = snapshot
        return snapshot
    }

    private func rebuild() -> NineKeyPinyinResult {
        let suffix = remaining
        choices = []
        if suffix.isEmpty {
            if !fixedText.isEmpty {
                choices = [Choice(text: fixedText, display: fixedText, pinyin: "", consumed: 0,
                                  offsets: [0], cost: 0, whole: true)]
            }
            return publish(remaining: suffix)
        }
        let raw = Array(suffix.prefix(Self.segmentLength).utf8)
        let paths = buildPaths(raw)
        var assembled: [Choice] = []
        var spellingCosts: [String: Double] = [:]
        for path in paths.prefix(Self.maximumProbes) {
            let probe = lookup(path.pinyin)
            for (index, candidate) in probe.candidates.enumerated() {
                let offset = min(candidate.consumedPinyinLength, path.offsets.count - 1)
                guard offset > 0 else { continue }
                let consumed = path.offsets[offset]
                guard consumed > 0 else { continue }
                let whole = consumed >= path.rawEnd
                // Whole-sentence costs are comparable across pinyin paths.
                // Small spelling priors break ties using actual dictionary data.
                let cost = candidate.score + path.prior * 0.1
                let display = whole ? fixedText + candidate.text : candidate.text
                assembled.append(Choice(text: candidate.text, display: display, pinyin: path.pinyin,
                    consumed: consumed, offsets: path.offsets, cost: cost, whole: whole))
                if index == 0 {
                    spellingCosts[path.firstSpelling] = min(spellingCosts[path.firstSpelling] ?? .infinity, cost)
                }
            }
        }
        // Preserve space for partial words; dozens of ambiguous full sentences
        // must not crowd out the first character/word a user wants to fix.
        let full = assembled.filter(\.whole).sorted(by: Self.precedes)
        let partial = assembled.filter { !$0.whole }.sorted(by: Self.precedes)
        var seen = Set<String>()
        for choice in Array(full.prefix(20)) + Array(partial.prefix(80)) + full.dropFirst(20) {
            guard seen.insert(choice.display).inserted else { continue }
            choices.append(choice)
            if choices.count == Self.maximumCandidateCount { break }
        }
        let rawHead = Array(raw.prefix { $0 != 39 })
        var possible: [String: Double] = spellingCosts
        for length in 1...max(1, min(6, rawHead.count)) {
            guard length <= rawHead.count else { break }
            let code = String(decoding: rawHead.prefix(length), as: UTF8.self)
            for spelling in fullByCode[code] ?? [] where possible[spelling.text] == nil {
                possible[spelling.text] = 100_000 + spelling.cost
            }
        }
        if rawHead.count <= 6 {
            let code = String(decoding: rawHead, as: UTF8.self)
            for spelling in prefixByCode[code] ?? [] where possible[spelling.text] == nil {
                possible[spelling.text] = 100_000 + spelling.cost
            }
        }
        let spellings = possible.keys.sorted { (possible[$0]!, $0) < (possible[$1]!, $1) }
        let display = choices.first?.pinyin.replacingOccurrences(of: "'", with: " ") ?? ""
        return publish(remaining: suffix, spellings: Array(spellings.prefix(16)), display: display)
    }

    private static func precedes(_ lhs: Choice, _ rhs: Choice) -> Bool {
        if lhs.consumed != rhs.consumed { return lhs.consumed > rhs.consumed }
        if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
        return lhs.display < rhs.display
    }

    private func buildPaths(_ raw: [UInt8]) -> [Path] {
        guard !raw.isEmpty else { return [] }
        var beams = Array(repeating: [Path](), count: raw.count + 1)
        beams[0] = [Path(pinyin: "", firstSpelling: "", syllables: 0, prior: 0, offsets: [0], rawEnd: 0)]
        for position in 0..<raw.count {
            guard !beams[position].isEmpty else { continue }
            var seen = Set<String>()
            beams[position] = beams[position].sorted { ($0.prior, $0.pinyin) < ($1.prior, $1.pinyin) }
                .filter { seen.insert($0.pinyin).inserted }.prefix(Self.beamWidth).map { $0 }
            if raw[position] == 39 {
                for path in beams[position] {
                    var offsets = path.offsets
                    offsets[offsets.count - 1] = position + 1
                    beams[position + 1].append(Path(pinyin: path.pinyin, firstSpelling: path.firstSpelling,
                        syllables: path.syllables, prior: path.prior, offsets: offsets, rawEnd: position + 1))
                }
                continue
            }
            var edges: [(Spelling, Int)] = []
            for length in 1...min(6, raw.count - position) {
                let part = raw[position..<(position + length)]
                if part.contains(39) { break }
                let code = String(decoding: part, as: UTF8.self)
                let entries = position + length == raw.count ? prefixByCode[code] : fullByCode[code]
                edges += (entries ?? []).map { ($0, position + length) }
            }
            for path in beams[position] where path.syllables < 9 {
                for (spelling, end) in edges {
                    if path.syllables == 0, let locked = lockedSpelling {
                        if !locked.accepts(spelling.text) { continue }
                    }
                    var offsets = path.offsets
                    let separator = path.pinyin.isEmpty ? "" : "'"
                    if !separator.isEmpty { offsets.append(position) }
                    offsets += Array((position + 1)...end)
                    beams[end].append(Path(pinyin: path.pinyin + separator + spelling.text,
                        firstSpelling: path.firstSpelling.isEmpty ? spelling.text : path.firstSpelling,
                        syllables: path.syllables + 1, prior: path.prior + spelling.cost,
                        offsets: offsets, rawEnd: end))
                }
            }
        }
        // The native core has a nine-syllable segment cap. If a longer input
        // cannot fit, return its longest valid prefix and preserve the suffix.
        guard let end = (1...raw.count).reversed().first(where: { !beams[$0].isEmpty }) else { return [] }
        var seen = Set<String>()
        return beams[end].sorted { ($0.prior, $0.pinyin) < ($1.prior, $1.pinyin) }
            .filter { seen.insert($0.pinyin).inserted }.prefix(Self.maximumProbes).map { $0 }
    }

    private func lookup(_ pinyin: String) -> PinyinProbeResult {
        if let hit = probes[pinyin] { return hit }
        let value = decoder.probe(pinyin: pinyin, candidateLimit: 8)
        if probeOrder.count >= 128 {
            probes.removeValue(forKey: probeOrder.removeFirst())
        }
        probes[pinyin] = value
        probeOrder.append(pinyin)
        return value
    }

    private func clearProbes() {
        probes.removeAll(keepingCapacity: true)
        probeOrder.removeAll(keepingCapacity: true)
    }

    private static func code(for pinyin: String) -> String? {
        var mapped: [UInt8] = []
        for letter in pinyin.utf8 {
            switch letter {
            case 97...99: mapped.append(50)
            case 100...102: mapped.append(51)
            case 103...105: mapped.append(52)
            case 106...108: mapped.append(53)
            case 109...111: mapped.append(54)
            case 112...115: mapped.append(55)
            case 116...118: mapped.append(56)
            case 119...122: mapped.append(57)
            default: return nil
            }
        }
        return String(decoding: mapped, as: UTF8.self)
    }
}
