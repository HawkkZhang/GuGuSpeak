import Foundation

struct LocalSenseVoiceModel: Sendable {
    let directory: URL
    let tokens: URL
    let model: URL

    var cacheKey: String {
        directory.path
    }
}

enum LocalAsrModelManager {
    static let defaultModelName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"

    static func resolveModel() throws -> LocalSenseVoiceModel {
        let roots = candidateRoots()
        for root in roots {
            if let model = resolveModel(in: root) {
                return model
            }
        }

        let installPath = userModelsRoot().appendingPathComponent(defaultModelName).path
        throw SessionFailureInfo(
            message: "未找到 SenseVoice 本地模型。请运行 macos/scripts/install-sensevoice-model.sh，或把 tokens.txt 和 model.int8.onnx 放到 \(installPath)。"
        )
    }

    static func userModelsRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("GuGuTalk", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    private static func candidateRoots() -> [URL] {
        var roots: [URL] = []

        if let override = ProcessInfo.processInfo.environment["GUGUTALK_LOCAL_ASR_MODEL_DIR"], !override.isEmpty {
            roots.append(URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true))
        }

        roots.append(userModelsRoot())

        if let resourceRoot = Bundle.main.resourceURL?.appendingPathComponent("models", isDirectory: true) {
            roots.append(resourceRoot)
        }

        return roots
    }

    private static func resolveModel(in root: URL) -> LocalSenseVoiceModel? {
        if let direct = modelIfUsable(directory: root) {
            return direct
        }

        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = subdirs.compactMap(modelIfUsable(directory:))
        return candidates.first { $0.directory.lastPathComponent == defaultModelName } ?? candidates.first
    }

    private static func modelIfUsable(directory: URL) -> LocalSenseVoiceModel? {
        let tokens = directory.appendingPathComponent("tokens.txt", isDirectory: false)
        let int8Model = directory.appendingPathComponent("model.int8.onnx", isDirectory: false)
        let fp32Model = directory.appendingPathComponent("model.onnx", isDirectory: false)

        guard FileManager.default.fileExists(atPath: tokens.path) else {
            return nil
        }

        if FileManager.default.fileExists(atPath: int8Model.path) {
            return LocalSenseVoiceModel(directory: directory, tokens: tokens, model: int8Model)
        }

        if FileManager.default.fileExists(atPath: fp32Model.path) {
            return LocalSenseVoiceModel(directory: directory, tokens: tokens, model: fp32Model)
        }

        return nil
    }
}
