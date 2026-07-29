import AppKit
import ApplicationServices
import Foundation
import os

@MainActor
final class TextInsertionService {
    private static let logger = Logger(subsystem: "com.desktopvoiceinput", category: "TextInsertion")

    func insert(text: String) -> InsertionResult {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let targetApp = frontmostApplication?.localizedName
        let targetBundleID = frontmostApplication?.bundleIdentifier
        let targetProcessID = frontmostApplication?.processIdentifier

        Self.logger.info("开始插入文本，目标应用: \(targetApp ?? "未知", privacy: .public)，bundleID: \(targetBundleID ?? "未知", privacy: .public)，文本长度: \(text.count)")

        if targetBundleID == Bundle.main.bundleIdentifier, !focusedElementLooksEditable() {
            Self.logger.warning("目标是自己的窗口，但焦点不是可输入控件，拒绝插入")
            return InsertionResult(
                method: .failed,
                targetAppName: targetApp,
                succeeded: false,
                failureReason: "当前焦点不在可输入区域。请先点进 GuGuTalk 的文本框或切到目标应用。"
            )
        }

        if usesWeChatStableInsertion(bundleID: targetBundleID) {
            Self.logger.info("微信稳定插入策略：Accessibility -> Unicode 键入 -> 剪贴板兜底")
            if let result = accessibilityInsertion(text: text, targetApp: targetApp) {
                Self.logger.info("✓ Accessibility 插入成功")
                return result
            }
            Self.logger.warning("✗ Accessibility 插入失败，将改用 Unicode 键入")

            if simulatedKeyboardInsertion(text: text, targetProcessID: targetProcessID) {
                Self.logger.info("✓ Unicode 键入指令已发送到目标应用")
                return InsertionResult(method: .simulatedKeyboard, targetAppName: targetApp, succeeded: true, failureReason: nil)
            }
            Self.logger.warning("✗ Unicode 键入失败，将回退到剪贴板粘贴")
        }

        Self.logger.info("尝试方法 1: 剪贴板粘贴")
        if clipboardPasteInsertion(text: text) {
            Self.logger.info("✓ 剪贴板粘贴指令已发送；系统无法直接确认目标输入框是否实际接收")
            return InsertionResult(method: .clipboardPaste, targetAppName: targetApp, succeeded: true, failureReason: nil)
        }
        Self.logger.warning("✗ 剪贴板粘贴失败")

        Self.logger.info("尝试方法 2: Accessibility API")
        if let result = accessibilityInsertion(text: text, targetApp: targetApp) {
            Self.logger.info("✓ Accessibility 插入成功")
            return result
        }
        Self.logger.warning("✗ Accessibility 插入失败")

        Self.logger.info("尝试方法 3: 模拟键盘输入")
        if simulatedKeyboardInsertion(text: text, targetProcessID: targetProcessID) {
            Self.logger.info("✓ 模拟键盘成功")
            return InsertionResult(method: .simulatedKeyboard, targetAppName: targetApp, succeeded: true, failureReason: nil)
        }
        Self.logger.error("✗ 所有插入方法都失败")

        return InsertionResult(method: .failed, targetAppName: targetApp, succeeded: false, failureReason: "无法写入当前应用，请手动复制预览文本。")
    }

    private func usesWeChatStableInsertion(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return [
            "com.tencent.xinWeChat",
            "com.tencent.WeChat"
        ].contains(bundleID)
    }

    private func accessibilityInsertion(text: String, targetApp: String?) -> InsertionResult? {
        guard AXIsProcessTrusted() else { return nil }

        guard let focusedElement = focusedElement() else {
            return nil
        }

        var valueObject: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &valueObject)
        guard valueResult == .success, let currentValue = valueObject as? String else { return nil }
        let editableValue = normalizedEditableValue(currentValue, from: focusedElement)

        var selectedRangeObject: AnyObject?
        let selectionResult = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeObject)
        guard selectionResult == .success, let rangeValue = selectedRangeObject else { return nil }

        var selectedRange = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selectedRange) else { return nil }

        let safeRange = clampedRange(selectedRange, in: editableValue)
        guard let stringRange = Range(NSRange(location: safeRange.location, length: safeRange.length), in: editableValue) else { return nil }

        let merged = editableValue.replacingCharacters(in: stringRange, with: text)
        let cursorLocation = safeRange.location + text.count

        guard AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, merged as CFTypeRef) == .success else {
            return nil
        }

        var newRange = CFRange(location: cursorLocation, length: 0)
        guard let newRangeValue = AXValueCreate(.cfRange, &newRange) else {
            return nil
        }

        AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, newRangeValue)
        return InsertionResult(method: .accessibility, targetAppName: targetApp, succeeded: true, failureReason: nil)
    }

    private func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedObject)
        guard focusedResult == .success, let focusedObject else { return nil }
        return unsafeDowncast(focusedObject, to: AXUIElement.self)
    }

    private func focusedElementLooksEditable() -> Bool {
        guard let focusedElement = focusedElement() else { return false }

        var roleObject: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &roleObject)
        let role = roleResult == .success ? roleObject as? String : nil

        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        if let role, editableRoles.contains(role) {
            return true
        }

        var settableObject: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(focusedElement, kAXValueAttribute as CFString, &settableObject)
        if settableResult == .success, settableObject.boolValue {
            return true
        }

        var selectedRangeObject: AnyObject?
        let selectedRangeResult = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, &selectedRangeObject)
        return selectedRangeResult == .success
    }

    private func normalizedEditableValue(_ currentValue: String, from element: AXUIElement) -> String {
        var placeholderObject: AnyObject?
        let placeholderResult = AXUIElementCopyAttributeValue(element, kAXPlaceholderValueAttribute as CFString, &placeholderObject)
        guard placeholderResult == .success,
              let placeholder = placeholderObject as? String,
              !placeholder.isEmpty,
              currentValue == placeholder else {
            return currentValue
        }

        return ""
    }

    private func clampedRange(_ range: CFRange, in text: String) -> CFRange {
        let upperBound = text.utf16.count
        let location = max(0, min(range.location, upperBound))
        let length = max(0, min(range.length, upperBound - location))
        return CFRange(location: location, length: length)
    }

    private func simulatedKeyboardInsertion(text: String, targetProcessID: pid_t?) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let chunks = unicodeTextChunks(from: text)
        guard !chunks.isEmpty else { return true }

        let source = CGEventSource(stateID: .combinedSessionState)
        Self.logger.info("发送 Unicode 键入事件。chunks=\(chunks.count, privacy: .public) targetPID=\(targetProcessID ?? -1, privacy: .public)")

        for chunk in chunks {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }

            var utf16 = Array(chunk.utf16)
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            keyDown.flags = []
            keyUp.flags = []

            if let targetProcessID {
                keyDown.postToPid(targetProcessID)
                keyUp.postToPid(targetProcessID)
            } else {
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
            }

            if chunks.count > 1 {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }

        return true
    }

    private func unicodeTextChunks(from text: String, maxUTF16Count: Int = 32) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentCount = 0

        for character in text {
            let characterText = String(character)
            let characterCount = characterText.utf16.count
            if !current.isEmpty, currentCount + characterCount > maxUTF16Count {
                chunks.append(current)
                current = ""
                currentCount = 0
            }

            current.append(character)
            currentCount += characterCount
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func clipboardPasteInsertion(text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let savedContents = PasteboardSnapshot(pasteboard: pasteboard)

        let sourceBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.desktopvoiceinput"
        guard PasteboardInsertionItem.write(
            text: text,
            sourceBundleIdentifier: sourceBundleIdentifier,
            to: pasteboard
        ) else {
            savedContents.restore(to: pasteboard)
            return false
        }

        let changeCountAfterSet = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            savedContents.restore(to: pasteboard)
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard pasteboard.changeCount == changeCountAfterSet else { return }
            savedContents.restore(to: pasteboard)
        }

        return true
    }
}

struct PasteboardInsertionItem {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    static func write(text: String, sourceBundleIdentifier: String, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setData(Data(), forType: transientType),
              item.setData(Data(), forType: autoGeneratedType),
              item.setString(sourceBundleIdentifier, forType: sourceType) else {
            return false
        }

        pasteboard.prepareForNewContents(with: .currentHostOnly)
        return pasteboard.writeObjects([item])
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            if !entry.isEmpty {
                snapshot.append(entry)
            }
        }
        self.items = snapshot
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let pasteboardItems = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(pasteboardItems)
    }
}
