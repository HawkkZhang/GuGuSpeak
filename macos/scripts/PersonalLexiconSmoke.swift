import Foundation

@main
enum PersonalLexiconSmoke {
    static func main() async throws {
        guard PersonalLexiconModelManager.resolveResources() != nil else {
            throw SmokeFailure("semantic model resources are unavailable")
        }

        let corrector = PersonalLexiconCorrector()
        let meetingTerm = [PersonalTerm(text: "会议")]
        let meeting = await corrector.correct("明天我们开回忆讨论项目", terms: meetingTerm)
        let memory = await corrector.correct("这是我童年的回忆", terms: meetingTerm)
        guard meeting == "明天我们开会议讨论项目" else {
            throw SmokeFailure("meeting context mismatch: \(meeting)")
        }
        guard memory == "这是我童年的回忆" else {
            throw SmokeFailure("memory context was incorrectly changed: \(memory)")
        }

        let brand = await corrector.correct(
            "打开咕咕 Talk 设置",
            terms: [PersonalTerm(text: "GuGuTalk")]
        )
        guard brand == "打开GuGuTalk设置" || brand == "打开GuGuTalk 设置" else {
            throw SmokeFailure("mixed-script brand mismatch: \(brand)")
        }

        let englishBrand = await corrector.correct(
            "打开 Google Talk 设置",
            terms: [PersonalTerm(text: "GuGuTalk")]
        )
        guard englishBrand == "打开 GuGuTalk 设置" || englishBrand == "打开GuGuTalk设置" else {
            throw SmokeFailure("English near-pronunciation brand mismatch: \(englishBrand)")
        }

        let mixedFinder = PhoneticCandidateFinder(pinyinData: """
        U+6263: kòu  # 扣
        U+95EE: wèn  # 问
        U+5F20: zhāng  # 张
        U+601D: sī  # 思
        U+5072: cāi,sī  # 偲
        U+516B: bā  # 八
        U+52A0: jiā  # 加
        U+8BF6: ēi  # 诶
        U+7231: ài  # 爱
        """)
        let cases = [
            ("试一下扣问模型", "Qwen", "扣问"),
            ("联系人张思思", "张偲偲", "张思思"),
            ("部署到 K 八 S", "K8s", "K 八 S"),
            ("这个模块用 C 加加写", "C++", "C 加加"),
            ("接入诶爱能力", "AI", "诶爱"),
            ("接入 Open 诶爱能力", "OpenAI", "Open 诶爱")
        ]
        for (text, term, expectedOriginal) in cases {
            let candidates = mixedFinder.candidates(in: text, terms: [PersonalTerm(text: term)])
            guard candidates.contains(where: {
                $0.original == expectedOriginal && $0.replacement == term
            }) else {
                throw SmokeFailure("arbitrary term was not recalled: \(term) from \(text)")
            }
        }

        let correctedCases = [
            ("试一下扣问模型", "Qwen", "试一下Qwen模型"),
            ("联系人张思思", "张偲偲", "联系人张偲偲"),
            ("部署到 K 八 S", "K8s", "部署到 K8s"),
            ("这个模块用 C 加加写", "C++", "这个模块用 C++写"),
            ("接入诶爱能力", "AI", "接入AI能力"),
            ("接入 Open 诶爱能力", "OpenAI", "接入 OpenAI能力")
        ]
        for (text, term, expected) in correctedCases {
            let corrected = await corrector.correct(text, terms: [PersonalTerm(text: term)])
            guard corrected == expected else {
                throw SmokeFailure("arbitrary term correction mismatch: \(corrected), expected \(expected)")
            }
        }

        let negative = mixedFinder.candidates(
            in: "打开 Google Chrome 设置",
            terms: [PersonalTerm(text: "GuGuTalk")]
        )
        guard !negative.contains(where: { $0.replacement == "GuGuTalk" }) else {
            throw SmokeFailure("different English term was incorrectly recalled")
        }

        let finder = PhoneticCandidateFinder(pinyinData: """
        U+77ED: duǎn  # 短
        U+8D85: chāo  # 超
        U+7EA7: jí  # 级
        U+957F: cháng  # 长
        U+4E2A: gè  # 个
        U+6027: xìng  # 性
        U+8BCD: cí  # 词
        """)
        guard finder.candidates(
            in: "短",
            terms: [PersonalTerm(text: "超级长个性词")]
        ).isEmpty else {
            throw SmokeFailure("long personal term unexpectedly matched a short transcript")
        }

        print("Personal lexicon smoke passed")
        print("  meeting: \(meeting)")
        print("  memory:  \(memory)")
        print("  brand:   \(brand)")
        print("  English: \(englishBrand)")
    }
}

private struct SmokeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
