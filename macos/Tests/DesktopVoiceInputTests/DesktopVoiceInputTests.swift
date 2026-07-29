import XCTest
import AVFoundation
import AppKit
@testable import DesktopVoiceInput

final class DesktopVoiceInputTests: XCTestCase {
    func testPhoneticCandidateFinderFindsChineseHomophone() {
        let finder = PhoneticCandidateFinder(pinyinData: """
        U+4F1A: huì  # 会
        U+8BAE: yì  # 议
        U+56DE: huí  # 回
        U+5FC6: yì  # 忆
        """)

        let candidates = finder.candidates(
            in: "明天我们开回忆讨论项目",
            terms: [PersonalTerm(text: "会议")]
        )

        XCTAssertTrue(candidates.contains { $0.original == "回忆" && $0.replacement == "会议" })
    }

    func testPhoneticCandidateFinderFindsMixedScriptBrandName() {
        let finder = PhoneticCandidateFinder(pinyinData: """
        U+5495: gū  # 咕
        """)

        let candidates = finder.candidates(
            in: "打开咕咕 Talk",
            terms: [PersonalTerm(text: "GuGuTalk")]
        )

        XCTAssertTrue(candidates.contains { $0.original == "咕咕 Talk" && $0.replacement == "GuGuTalk" })
    }

    func testPhoneticCandidateFinderFindsEnglishNearPronunciation() {
        let finder = PhoneticCandidateFinder(
            pinyinData: "",
            englishPronunciationData: """
            google G UW1 G AH0 L
            gu G UW1
            talk T AO1 K
            """
        )

        let candidates = finder.candidates(
            in: "打开 Google Talk 设置",
            terms: [PersonalTerm(text: "GuGuTalk")]
        )

        XCTAssertTrue(candidates.contains { $0.original == "Google Talk" && $0.replacement == "GuGuTalk" })
    }

    func testPhoneticCandidateFinderHandlesArbitraryMixedTerms() {
        let finder = PhoneticCandidateFinder(pinyinData: """
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

        XCTAssertTrue(finder.candidates(
            in: "试一下扣问模型",
            terms: [PersonalTerm(text: "Qwen")]
        ).contains { $0.original == "扣问" && $0.replacement == "Qwen" })
        XCTAssertTrue(finder.candidates(
            in: "联系人张思思",
            terms: [PersonalTerm(text: "张偲偲")]
        ).contains { $0.original == "张思思" && $0.replacement == "张偲偲" })
        XCTAssertTrue(finder.candidates(
            in: "部署到 K 八 S",
            terms: [PersonalTerm(text: "K8s")]
        ).contains { $0.original == "K 八 S" && $0.replacement == "K8s" })
        XCTAssertTrue(finder.candidates(
            in: "这个模块用 C 加加写",
            terms: [PersonalTerm(text: "C++")]
        ).contains { $0.original == "C 加加" && $0.replacement == "C++" })
        XCTAssertTrue(finder.candidates(
            in: "接入诶爱能力",
            terms: [PersonalTerm(text: "AI")]
        ).contains { $0.original == "诶爱" && $0.replacement == "AI" })
        XCTAssertTrue(finder.candidates(
            in: "接入 Open 诶爱能力",
            terms: [PersonalTerm(text: "OpenAI")]
        ).contains { $0.original == "Open 诶爱" && $0.replacement == "OpenAI" })
    }

    func testPhoneticCandidateFinderRejectsDifferentEnglishTerm() {
        let finder = PhoneticCandidateFinder(
            pinyinData: "",
            englishPronunciationData: """
            chrome K R OW1 M
            google G UW1 G AH0 L
            gu G UW1
            talk T AO1 K
            """
        )

        let candidates = finder.candidates(
            in: "打开 Google Chrome 设置",
            terms: [PersonalTerm(text: "GuGuTalk")]
        )

        XCTAssertFalse(candidates.contains { $0.replacement == "GuGuTalk" })
    }

    func testPhoneticCandidateFinderSkipsTermLongerThanTranscript() {
        let finder = PhoneticCandidateFinder(pinyinData: """
        U+77ED: duǎn  # 短
        U+8D85: chāo  # 超
        U+7EA7: jí  # 级
        U+957F: cháng  # 长
        U+4E2A: gè  # 个
        U+6027: xìng  # 性
        U+8BCD: cí  # 词
        """)

        let candidates = finder.candidates(
            in: "短",
            terms: [PersonalTerm(text: "超级长个性词")]
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    @MainActor
    func testPersonalTermStoreMigratesLegacyReplacements() throws {
        let suiteName = "GuGuTalkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = [TextReplacement(from: "回忆", to: "会议")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "textReplacements")

        let store = HotwordStore(defaults: defaults)

        XCTAssertEqual(store.terms.count, 1)
        XCTAssertEqual(store.terms[0].text, "会议")
        XCTAssertEqual(store.terms[0].aliases, ["回忆"])
        XCTAssertEqual(store.applyReplacements(to: "开回忆"), "开会议")
    }

    func testPersonalLexiconSemanticCorrectionUsesContext() async throws {
        guard PersonalLexiconModelManager.resolveResources() != nil else {
            throw XCTSkip("Semantic model resources are not installed")
        }
        let corrector = PersonalLexiconCorrector()
        let terms = [PersonalTerm(text: "会议")]

        let meeting = await corrector.correct("明天我们开回忆讨论项目", terms: terms)
        let memory = await corrector.correct("这是我童年的回忆", terms: terms)

        XCTAssertEqual(meeting, "明天我们开会议讨论项目")
        XCTAssertEqual(memory, "这是我童年的回忆")
    }

    func testLocalRepetitionNormalizerRemovesTrailingBoundaryCharacter() {
        XCTAssertEqual(
            LocalRepetitionNormalizer.normalize("现在退出页面的时候候"),
            "现在退出页面的时候"
        )
    }

    func testLocalRepetitionNormalizerRemovesLeadingBoundaryCharacter() {
        XCTAssertEqual(LocalRepetitionNormalizer.normalize("整整个应用的颜色"), "整个应用的颜色")
        XCTAssertEqual(LocalRepetitionNormalizer.normalize("整整整个应用的颜色"), "整个应用的颜色")
        XCTAssertEqual(LocalRepetitionNormalizer.normalize("有有重复"), "有重复")
    }

    func testLocalRepetitionNormalizerPreservesNaturalReduplication() {
        XCTAssertEqual(LocalRepetitionNormalizer.normalize("我想看看这个页面"), "我想看看这个页面")
        XCTAssertEqual(LocalRepetitionNormalizer.normalize("慢慢来，刚刚好"), "慢慢来，刚刚好")
        XCTAssertEqual(LocalRepetitionNormalizer.normalize("上海海事大学"), "上海海事大学")
    }

    func testPasteboardInsertionItemMarksGeneratedTextAsTransient() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GuGuTalkTests.\(UUID().uuidString)"))

        XCTAssertTrue(
            PasteboardInsertionItem.write(
                text: "测试 voice input",
                sourceBundleIdentifier: "com.example.GuGuTalkTests",
                to: pasteboard
            )
        )

        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertEqual(item.string(forType: .string), "测试 voice input")
        XCTAssertTrue(item.types.contains(PasteboardInsertionItem.transientType))
        XCTAssertTrue(item.types.contains(PasteboardInsertionItem.autoGeneratedType))
        XCTAssertEqual(
            item.string(forType: PasteboardInsertionItem.sourceType),
            "com.example.GuGuTalkTests"
        )
    }

    func testLocalPunctuationNormalizerUsesASCIIAfterEnglish() {
        XCTAssertEqual(
            LocalPunctuationNormalizer.normalize("How are you？thank you，ok！"),
            "How are you?thank you,ok!"
        )
    }

    func testLocalPunctuationNormalizerPreservesChinesePunctuation() {
        XCTAssertEqual(
            LocalPunctuationNormalizer.normalize("你好，今天怎么样？"),
            "你好，今天怎么样？"
        )
    }

    func testLocalPunctuationNormalizerHandlesMixedBoundaries() {
        XCTAssertEqual(
            LocalPunctuationNormalizer.normalize("今天用 OpenAI，效果很好。"),
            "今天用 OpenAI,效果很好。"
        )
    }

    func testLocalPunctuationNormalizerHandlesEmptyText() {
        XCTAssertEqual(LocalPunctuationNormalizer.normalize(""), "")
    }

    func testPostProcessorDoesNotAddTerminalPunctuation() {
        let processor = TranscriptPostProcessor()
        XCTAssertEqual(processor.finalize("你好 今天过得怎么样"), "你好今天过得怎么样")
    }

    func testPostProcessorPreservesExistingPunctuation() {
        let processor = TranscriptPostProcessor()
        XCTAssertEqual(processor.finalize("会议结束了吗？"), "会议结束了吗？")
    }

    func testPostProcessorCollapsesWhitespace() {
        let processor = TranscriptPostProcessor()
        XCTAssertEqual(processor.finalize("  明天   上午  十点   开会  "), "明天上午十点开会")
    }

    func testPostProcessorRemovesChinesePauseSpaces() {
        let processor = TranscriptPostProcessor()
        XCTAssertEqual(processor.finalize("这个 过程 中 就 会 有 空格"), "这个过程中就会有空格")
    }

    func testPostProcessorPreservesEnglishWordSpaces() {
        let processor = TranscriptPostProcessor()
        XCTAssertEqual(processor.finalize("打开 OpenAI Cloud 控制台"), "打开 OpenAI Cloud 控制台")
    }

    func testRemoveTrailingPunctuationAfterWhitespace() {
        let result = TextTransform.removeTrailingPunctuation.apply(to: "今天先这样。   \n")
        XCTAssertEqual(result, "今天先这样")
    }

    func testRemoveTrailingPunctuationKeepsQuestionAndExclamationMarks() {
        let result = TextTransform.removeTrailingPunctuation.apply(to: "真的吗？！")
        XCTAssertEqual(result, "真的吗？！")
    }

    func testRemoveTrailingPunctuationRemovesOnlyTerminalPeriods() {
        let result = TextTransform.removeTrailingPunctuation.apply(to: "今天先这样。。")
        XCTAssertEqual(result, "今天先这样")
    }

    func testRemoveTrailingPunctuationKeepsMiddlePunctuation() {
        let result = TextTransform.removeTrailingPunctuation.apply(to: "你好，今天先这样。")
        XCTAssertEqual(result, "你好，今天先这样")
    }

    func testDoubaoTranscriptPayloadUsesResultText() {
        let payload = DoubaoTranscriptPayload(resultObject: [
            "text": "这是豆包官方推荐的累积完整文本。"
        ])
        XCTAssertEqual(payload?.text, "这是豆包官方推荐的累积完整文本。")
    }

    func testDoubaoTranscriptPayloadNormalizesChinesePauseSpaces() {
        let payload = DoubaoTranscriptPayload(resultObject: [
            "text": "这个 过程 中 就 会 有 空格"
        ])
        XCTAssertEqual(payload?.canonicalText, "这个过程中就会有空格")
        XCTAssertEqual(payload?.rawCanonicalText, "这个 过程 中 就 会 有 空格")
    }

    func testDoubaoTranscriptPayloadReturnsNilWhenEmpty() {
        let payload = DoubaoTranscriptPayload(resultObject: [
            "text": "   "
        ])
        XCTAssertNil(payload)
    }

    func testDoubaoTranscriptPayloadReadsUtterances() {
        let payload = DoubaoTranscriptPayload(resultObject: [
            "text": "整段文本",
            "utterances": [
                ["definite": true, "start_time": 0, "end_time": 500, "text": "已经确定，"],
                ["definite": false, "start_time": 500, "end_time": 900, "text": "还在识别"]
            ]
        ])

        XCTAssertEqual(payload?.utterances.count, 2)
        XCTAssertEqual(payload?.definiteCount, 1)
    }

    func testDoubaoTranscriptPayloadReadsResultList() {
        let payload = DoubaoTranscriptPayload(resultValue: [
            [
                "text": "列表结构",
                "utterances": [
                    ["definite": true, "start_time": 0, "end_time": 500, "text": "列表结构"]
                ]
            ]
        ])

        XCTAssertEqual(payload?.text, "列表结构")
        XCTAssertEqual(payload?.utterances.count, 1)
    }

    func testDoubaoCanonicalTextPrefersServiceFullText() {
        let payload = DoubaoTranscriptPayload(resultObject: [
            "text": "服务端完整结果",
            "utterances": [
                ["definite": true, "start_time": 0, "end_time": 800, "text": "局部分句"]
            ]
        ])

        XCTAssertEqual(payload?.canonicalText, "服务端完整结果")
    }

    func testDoubaoCanonicalTextFallsBackToTimeSortedUtterances() {
        let payload = DoubaoTranscriptPayload(resultObject: [
            "utterances": [
                ["definite": false, "start_time": 800, "end_time": 1200, "text": "颜色"],
                ["definite": true, "start_time": 0, "end_time": 800, "text": "整个应用的"]
            ]
        ])

        XCTAssertEqual(payload?.canonicalText, "整个应用的颜色")
    }

    func testDoubaoFinalRepairKeepsDroppedStablePrefix() {
        let repaired = DoubaoTranscriptRepair.recoverFinalText(
            current: "之前还挺好用的。",
            previous: "Gemini 之前还"
        )

        XCTAssertTrue(repaired.didRecover)
        XCTAssertEqual(repaired.text, "Gemini 之前还挺好用的。")
    }

    func testDoubaoFinalRepairDoesNotChangeNormalFullFinal() {
        let repaired = DoubaoTranscriptRepair.recoverFinalText(
            current: "Gemini 之前还挺好用的。",
            previous: "Gemini 之前还"
        )

        XCTAssertFalse(repaired.didRecover)
        XCTAssertEqual(repaired.text, "Gemini 之前还挺好用的。")
    }

    func testDoubaoFinalRepairRequiresMeaningfulOverlap() {
        let repaired = DoubaoTranscriptRepair.recoverFinalText(
            current: "还挺好用的。",
            previous: "Gemini 之前还"
        )

        XCTAssertFalse(repaired.didRecover)
        XCTAssertEqual(repaired.text, "还挺好用的。")
    }

    func testAudioPrerollBufferKeepsRecentAudioWithinDurationLimit() {
        var buffer = AudioPrerollBuffer(maxDuration: 1.0)

        buffer.append(makeAudioChunk(duration: 0.4, level: 0.1))
        buffer.append(makeAudioChunk(duration: 0.4, level: 0.2))
        buffer.append(makeAudioChunk(duration: 0.4, level: 0.3))

        XCTAssertEqual(buffer.chunks.count, 2)
        XCTAssertEqual(buffer.chunks.first?.audioLevel, 0.2)
        XCTAssertEqual(buffer.chunks.last?.audioLevel, 0.3)
        XCTAssertLessThanOrEqual(buffer.duration, 1.0)
    }

    func testAudioPrerollBufferDrainPreservesOrderAndClearsBuffer() {
        var buffer = AudioPrerollBuffer(maxDuration: 2.0)

        buffer.append(makeAudioChunk(duration: 0.25, level: 0.1))
        buffer.append(makeAudioChunk(duration: 0.25, level: 0.2))

        let drained = buffer.drain()

        XCTAssertEqual(drained.map(\.audioLevel), [0.1, 0.2])
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.duration, 0)
    }

    func testAudioSendQueuePreservesOrderAndTracksDuration() {
        var queue = AudioSendQueue()

        queue.append(makeAudioChunk(duration: 0.1, level: 0.1))
        queue.append(makeAudioChunk(duration: 0.2, level: 0.2))

        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.duration, 0.3, accuracy: 0.001)
        XCTAssertEqual(queue.popFirst()?.audioLevel, 0.1)
        XCTAssertEqual(queue.popFirst()?.audioLevel, 0.2)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.duration, 0, accuracy: 0.001)
    }

    private func makeAudioChunk(duration: TimeInterval, level: Float) -> AudioChunk {
        let sampleRate = 16_000.0
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let nativeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        nativeBuffer.frameLength = frameCount
        return AudioChunk(
            pcmData: Data(count: Int(frameCount) * MemoryLayout<Int16>.size),
            sampleRate: sampleRate,
            channels: 1,
            audioLevel: level,
            nativeBuffer: nativeBuffer
        )
    }
}
