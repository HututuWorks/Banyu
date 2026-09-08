import Foundation

@main
struct NineKeySmoke {
    @MainActor
    static func main() {
        let disambiguationOnly = CommandLine.arguments.last == "--disambiguation-only"
        guard CommandLine.arguments.count == (disambiguationOnly ? 4 : 3),
              let bridge = PinyinDecoder(dictionaryPath: CommandLine.arguments[1],
                                         userDictionaryPath: CommandLine.arguments[2]) else { fatalError("dictionary setup") }
        let decoder = NineKeyPinyinDecoder(pinyinDecoder: bridge)
        func require(_ condition: Bool, _ label: String) {
            if !condition { fatalError(label) }
        }
        func report(_ name: String, _ values: [Double]) {
            let sorted = values.sorted()
            print(String(format: "%@ count=%d median_ms=%.3f p95_ms=%.3f max_ms=%.3f", name,
                         sorted.count, sorted[sorted.count / 2], sorted[sorted.count * 95 / 100], sorted.last!))
        }
        for (digits, chinese) in [("64426", "你好"), ("96582432653", "我快到了"),
                                  ("94664486", "中国"), ("64'426", "你好"), ("'64''426'", "你好")] {
            decoder.reset()
            let result = decoder.update(digits: digits)
            guard let index = result.candidates.firstIndex(of: chinese) else {
                fatalError("expected real T9 dictionary phrase")
            }
            let chosen = decoder.selectCandidate(at: index)
            require(chosen.isComplete && chosen.commitText == chinese, "T9 choice commits exact expected phrase")
            require(chosen.remainingDigits.isEmpty, "no digits lost on exact phrase")
        }
        decoder.reset()
        var result = decoder.update(digits: "96582432653")
        guard let wo = result.candidates.firstIndex(of: "我") else { fatalError("partial real word offered") }
        result = decoder.selectCandidate(at: wo)
        require(!result.isComplete && result.fixedText == "我" && result.remainingDigits == "582432653", "partial T9 choice retains suffix")
        result = decoder.update(digits: "96582432653")
        require(result.fixedText == "我", "T9 fixed prefix survives repeated input")
        guard let finish = result.candidates.firstIndex(of: "我快到了") else { fatalError("T9 suffix completes sentence") }
        result = decoder.selectCandidate(at: finish)
        require(result.isComplete && result.commitText == "我快到了", "T9 segmented selection")

        decoder.reset()
        result = decoder.update(digits: "64426")
        guard let ni = result.spellingOptions.firstIndex(of: "ni") else { fatalError("real spelling disambiguation offered") }
        result = decoder.selectSpelling(at: ni)
        require(!result.isComplete && result.remainingDigits == "64426" && result.candidates.contains("你好"), "spelling selection narrows without consuming")
        result = decoder.update(digits: "6442662")
        require(result.displayPinyin.hasPrefix("ni"), "spelling constraint survives append")
        result = decoder.update(digits: "6")
        require(!result.candidates.isEmpty && result.fixedText.isEmpty, "delete through constraint recovers")

        // N/M are present as full entries in the real AOSP spelling table.
        // Selecting them from one ambiguous key must still allow a vowel.
        for (initial, extendedDigits, expectedSyllable, expectedCandidate) in
            [("n", "64", "ni", "你"), ("m", "62", "ma", "吗")] {
            decoder.reset()
            result = decoder.update(digits: "6")
            guard let option = result.spellingOptions.firstIndex(of: initial) else {
                fatalError("consonant initial disambiguation offered")
            }
            _ = decoder.selectSpelling(at: option)
            result = decoder.update(digits: extendedDigits)
            require(result.displayPinyin.split(separator: " ").first == Substring(expectedSyllable)
                && result.candidates.contains(expectedCandidate), "selected initial extends into real syllable")
            require(!result.isComplete && result.remainingDigits == extendedDigits,
                    "extending initial does not consume or commit digits")
            result = decoder.update(digits: "6")
            require(result.displayPinyin == initial, "deleting appended vowel retains initial constraint")
        }
        decoder.reset()
        result = decoder.update(digits: "64")
        guard let completeNi = result.spellingOptions.firstIndex(of: "ni") else {
            fatalError("complete syllable disambiguation offered")
        }
        _ = decoder.selectSpelling(at: completeNi)
        result = decoder.update(digits: "6426")
        require(result.displayPinyin.split(separator: " ").first == "ni"
            && !result.candidates.contains("鸟"), "completed ni stays a syllable instead of extending to niao")
        require(!result.isComplete && result.remainingDigits == "6426", "complete syllable constraint does not commit")
        result = decoder.update(digits: "6")
        require(!result.candidates.isEmpty, "delete into complete syllable releases constraint")
        if disambiguationOnly {
            print("PASS: real T9 phrases, partial selection, m/n initial extension, fixed ni boundary, deletion")
            return
        }
        result = decoder.update(digits: "6🙂")
        require(result.candidates.isEmpty && result.remainingDigits == "6🙂", "invalid input remains visible")
        result = decoder.update(digits: String(repeating: "6", count: 65))
        require(result.candidates.isEmpty && result.remainingDigits.count == 65, "oversized buffer bounded without losing input")

        var remaining = String(repeating: "64426", count: 8)
        var committed = ""
        for _ in 0..<16 where !remaining.isEmpty {
            decoder.reset()
            result = decoder.update(digits: remaining)
            require(!result.candidates.isEmpty, "long T9 input offers a real prefix")
            result = decoder.selectCandidate(at: 0)
            require(result.isComplete && result.remainingDigits.count < remaining.count, "long T9 segment progresses")
            committed += result.commitText
            remaining = result.remainingDigits
        }
        require(remaining.isEmpty && !committed.isEmpty, "long T9 suffix fully consumed")

        let other = NineKeyPinyinDecoder(pinyinDecoder: bridge)
        decoder.reset()
        other.reset()
        result = decoder.update(digits: "64426")
        let expectedIndex = result.candidates.firstIndex(of: "你好")!
        _ = other.update(digits: "96582432653")
        _ = bridge.update(pinyin: "zhongguo")
        result = decoder.selectCandidate(at: expectedIndex)
        require(result.commitText == "你好", "T9 selection survives another T9 and QWERTY search")

        // Deterministic generated buffers exercise the actual dictionary and
        // the bounded graph; no canned mapping is added to production code.
        var seed: UInt64 = 0x5487
        var generatedTimes: [Double] = []
        for round in 0..<120 {
            decoder.reset()
            var input = ""
            for index in 0..<(1 + round % 64) {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                input += index % 11 == 10 ? "'" : String(2 + Int((seed >> 32) % 8))
            }
            let generatedStart = ProcessInfo.processInfo.systemUptime
            result = decoder.update(digits: input)
            generatedTimes.append((ProcessInfo.processInfo.systemUptime - generatedStart) * 1000)
            require(result.candidates.count <= 40, "generated input obeys candidate bound")
            if !result.candidates.isEmpty {
                result = decoder.selectCandidate(at: 0)
                require(result.remainingDigits.count < input.count, "generated candidate consumes a real input prefix")
                require(input.hasSuffix(result.remainingDigits), "generated suffix preserves original digit order")
            }
        }

        var times: [Double] = []
        var selects: [Double] = []
        for _ in 0..<30 {
            decoder.reset()
            let digits = "96582432653"
            for count in 1...digits.count {
                let start = ProcessInfo.processInfo.systemUptime
                result = decoder.update(digits: String(digits.prefix(count)))
                times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                require(result.candidates.count <= NineKeyPinyinDecoder.maximumCandidateCount, "candidate bound")
            }
            let start = ProcessInfo.processInfo.systemUptime
            _ = decoder.selectCandidate(at: 0)
            selects.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        report("t9_update", times)
        report("t9_selection_including_flush", selects)
        report("t9_generated_1_to_64_characters", generatedTimes)
        print("PASS: T9 real phrases, partial selection, disambiguation, editing, input bounds, long suffix, interleaved sessions")
    }
}
