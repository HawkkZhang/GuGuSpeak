import Foundation

struct LocalParaformerModel: Sendable {
    let directory: URL
    let tokens: URL
    let encoder: URL
    let decoder: URL
}

struct LocalPunctuationModel: Sendable {
    let directory: URL
    let model: URL
}

struct LocalAsrModels: Sendable {
    let asr: LocalParaformerModel
    let punctuation: LocalPunctuationModel

    var cacheKey: String {
        [
            asr.tokens.path,
            asr.encoder.path,
            asr.decoder.path,
            punctuation.model.path,
        ].joined(separator: "#")
    }
}

enum LocalAsrModelManager {
    static let defaultAsrModelName = "sherpa-onnx-streaming-paraformer-bilingual-zh-en"
    static let defaultPunctuationModelName =
        "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"

    static func resolveModels() throws -> LocalAsrModels {
        guard let asr = resolveAsrModel() else {
            let installPath = userModelsRoot().appendingPathComponent(defaultAsrModelName).path
            throw SessionFailureInfo(
                message: "未找到流式中英本地模型。请运行 macos/scripts/install-local-asr-models.sh，或把 encoder.int8.onnx、decoder.int8.onnx 和 tokens.txt 放到 \(installPath)。"
            )
        }

        guard let punctuation = resolvePunctuationModel() else {
            let installPath = userModelsRoot().appendingPathComponent(defaultPunctuationModelName).path
            throw SessionFailureInfo(
                message: "未找到中英文标点模型。请运行 macos/scripts/install-local-asr-models.sh，或把 model.int8.onnx 放到 \(installPath)。"
            )
        }

        return LocalAsrModels(asr: asr, punctuation: punctuation)
    }

    static func userModelsRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("GuGuTalk", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    private static func resolveAsrModel() -> LocalParaformerModel? {
        for root in asrCandidateRoots() {
            if let model = resolveAsrModel(in: root) {
                return model
            }
        }
        return nil
    }

    private static func resolvePunctuationModel() -> LocalPunctuationModel? {
        if let override = environmentDirectory(named: "GUGUTALK_LOCAL_PUNCTUATION_MODEL_DIR"),
           let model = resolvePunctuationModel(in: override, allowDirect: true) {
            return model
        }

        for root in sharedCandidateRoots() {
            if let model = resolvePunctuationModel(in: root, allowDirect: false) {
                return model
            }
        }

        if let asrOverride = environmentDirectory(named: "GUGUTALK_LOCAL_ASR_MODEL_DIR"),
           let model = resolvePunctuationModel(in: asrOverride, allowDirect: false) {
            return model
        }

        return nil
    }

    private static func asrCandidateRoots() -> [URL] {
        var roots: [URL] = []
        if let override = environmentDirectory(named: "GUGUTALK_LOCAL_ASR_MODEL_DIR") {
            roots.append(override)
        }
        roots.append(contentsOf: sharedCandidateRoots())
        return roots
    }

    private static func sharedCandidateRoots() -> [URL] {
        var roots = [userModelsRoot()]
        if let resourceRoot = Bundle.main.resourceURL?.appendingPathComponent("models", isDirectory: true) {
            roots.append(resourceRoot)
        }
        return roots
    }

    private static func environmentDirectory(named name: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath, isDirectory: true)
    }

    private static func resolveAsrModel(in root: URL) -> LocalParaformerModel? {
        if let direct = asrModelIfUsable(directory: root) {
            return direct
        }

        let candidates = childDirectories(of: root).compactMap(asrModelIfUsable(directory:))
        return candidates.first { $0.directory.lastPathComponent == defaultAsrModelName }
            ?? candidates.first
    }

    private static func resolvePunctuationModel(
        in root: URL,
        allowDirect: Bool
    ) -> LocalPunctuationModel? {
        if allowDirect, let direct = punctuationModelIfUsable(directory: root) {
            return direct
        }

        let candidates = childDirectories(of: root)
            .filter {
                $0.lastPathComponent == defaultPunctuationModelName
                    || $0.lastPathComponent.localizedCaseInsensitiveContains("punct")
            }
            .compactMap(punctuationModelIfUsable(directory:))

        return candidates.first { $0.directory.lastPathComponent == defaultPunctuationModelName }
            ?? candidates.first
    }

    private static func childDirectories(of root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func asrModelIfUsable(directory: URL) -> LocalParaformerModel? {
        let tokens = directory.appendingPathComponent("tokens.txt", isDirectory: false)
        let int8Encoder = directory.appendingPathComponent("encoder.int8.onnx", isDirectory: false)
        let int8Decoder = directory.appendingPathComponent("decoder.int8.onnx", isDirectory: false)
        let fp32Encoder = directory.appendingPathComponent("encoder.onnx", isDirectory: false)
        let fp32Decoder = directory.appendingPathComponent("decoder.onnx", isDirectory: false)

        guard FileManager.default.fileExists(atPath: tokens.path) else {
            return nil
        }

        if FileManager.default.fileExists(atPath: int8Encoder.path),
           FileManager.default.fileExists(atPath: int8Decoder.path) {
            return LocalParaformerModel(
                directory: directory,
                tokens: tokens,
                encoder: int8Encoder,
                decoder: int8Decoder
            )
        }

        if FileManager.default.fileExists(atPath: fp32Encoder.path),
           FileManager.default.fileExists(atPath: fp32Decoder.path) {
            return LocalParaformerModel(
                directory: directory,
                tokens: tokens,
                encoder: fp32Encoder,
                decoder: fp32Decoder
            )
        }

        return nil
    }

    private static func punctuationModelIfUsable(directory: URL) -> LocalPunctuationModel? {
        let int8Model = directory.appendingPathComponent("model.int8.onnx", isDirectory: false)
        let fp32Model = directory.appendingPathComponent("model.onnx", isDirectory: false)

        if FileManager.default.fileExists(atPath: int8Model.path) {
            return LocalPunctuationModel(directory: directory, model: int8Model)
        }

        if FileManager.default.fileExists(atPath: fp32Model.path) {
            return LocalPunctuationModel(directory: directory, model: fp32Model)
        }

        return nil
    }
}
