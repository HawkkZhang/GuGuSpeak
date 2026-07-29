import Foundation
import os

@MainActor
final class SmartPostProcessor {
    private static let logger = Logger(subsystem: "com.end.DesktopVoiceInput", category: "SmartPostProcessor")

    private let settings: AppSettings
    private let llmClient: LLMClient
    private let fallback: TranscriptPostProcessor
    private let hotwordStore: HotwordStore
    private let personalLexiconCorrector = PersonalLexiconCorrector()

    init(settings: AppSettings, hotwordStore: HotwordStore, llmClient: LLMClient = LLMClient()) {
        self.settings = settings
        self.hotwordStore = hotwordStore
        self.llmClient = llmClient
        self.fallback = TranscriptPostProcessor()
    }

    func processRulesOnly(text: String) -> String {
        var result = fallback.finalize(text)
        result = applyHotwordCorrection(to: result)
        return applyFinalPunctuationRules(to: result)
    }

    var requiresAsyncPersonalLexiconProcessing: Bool {
        !hotwordStore.isEmpty
    }

    func process(text: String, targetApp: String?, targetBundleID: String?) async -> String {
        var result = fallback.finalize(text)

        // 热词模糊替换（规则层，始终生效）
        result = applyHotwordCorrection(to: result)

        guard !result.isEmpty else { return result }

        if settings.postProcessingEnabled {
            let pipeline = resolvePipeline(targetApp: targetApp, targetBundleID: targetBundleID)
            if !pipeline.rules.isEmpty {
                result = PostProcessingConfig.applyRules(pipeline.rules, to: result)
            }

            if let prompt = pipeline.llmPrompt, !prompt.isEmpty {
                let config = settings.llmProviderConfig
                if config.isConfigured {
                    let systemPrompt = buildSystemPrompt(basePrompt: prompt)
                    do {
                        let llmResult = try await llmClient.complete(system: systemPrompt, user: result, config: config)
                        if !llmResult.isEmpty {
                            result = llmResult
                        }
                    } catch {
                        Self.logger.error("LLM post-processing failed, using rule-only result. error=\(error.localizedDescription, privacy: .public)")
                    }
                } else {
                    Self.logger.info("LLM not configured, skipping LLM post-processing")
                }
            }
        }

        result = applyHotwordCorrection(to: result)
        result = await personalLexiconCorrector.correct(result, terms: hotwordStore.terms)
        return applyFinalPunctuationRules(to: result)
    }

    private func resolvePipeline(targetApp: String?, targetBundleID: String?) -> PostProcessingConfig.ProcessingPipeline {
        if let prompt = settings.activePostProcessingPrompt {
            return PostProcessingConfig.ProcessingPipeline(
                rules: [.collapseWhitespace, .trimWhitespace],
                llmPrompt: prompt
            )
        }

        return PostProcessingConfig.ProcessingPipeline(
            rules: [.collapseWhitespace, .trimWhitespace]
        )
    }

    private func buildSystemPrompt(basePrompt: String) -> String {
        let terms = hotwordStore.terms
        guard !terms.isEmpty else { return basePrompt }
        let wordList = terms.map(\.text).joined(separator: "、")
        return basePrompt + "\n\n参考热词表（如果识别结果中有发音相近但拼写不同的词，优先使用热词表中的正确写法）：\(wordList)"
    }

    private func applyHotwordCorrection(to text: String) -> String {
        hotwordStore.applyReplacements(to: text)
    }

    private func applyFinalPunctuationRules(to text: String) -> String {
        let normalized = fallback.finalize(text)
        let punctuationRules = settings.punctuationMode.rules
        return PostProcessingConfig.applyRules(punctuationRules, to: normalized)
    }
}
