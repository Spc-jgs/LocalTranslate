import AppKit
import Foundation
import Vision
import CoreGraphics

@MainActor
final class ScreenshotOCRService {
    static let shared = ScreenshotOCRService()

    private var isCapturing = false

    private init() {}

    /// 检查并请求屏幕录制权限
    func checkPermission(promptIfNeeded: Bool = true) -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        guard promptIfNeeded else {
            return false
        }

        CGRequestScreenCaptureAccess()

        let alert = NSAlert()
        alert.messageText = "需要“屏幕录制”权限"
        alert.informativeText = "LocalTranslate 需要屏幕录制权限才能识别截图中的文字并翻译。\n\n请在“系统设置 -> 隐私与安全性 -> 屏幕与系统音频录制”中允许 LocalTranslate，然后重新尝试截图。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }

        return false
    }

    /// 调起系统原生交互框选，并对截屏进行精准 Vision OCR 识别与段落重组
    func captureAndRecognizeText() async throws -> String? {
        guard checkPermission(promptIfNeeded: true) else {
            return nil
        }

        guard !isCapturing else {
            return nil
        }
        isCapturing = true
        defer {
            isCapturing = false
        }

        // 1. 调起系统原生截图 (参考 Easydict 成熟实现: -i -s -x)
        guard let nsImage = await takeInteractiveScreenshot() else {
            return nil // 用户按 ESC 取消或未截取
        }

        // 2. 提取最高物理精度 CGImage
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        // 3. 在后台异步执行 Apple Vision 神经引擎 OCR 提取
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // 与翻译支持的源语言对齐：OCR 认不出的语言，翻译也就无从谈起。
            request.recognitionLanguages = [
                "zh-Hans", "zh-Hant", "en-US",
                "ja-JP", "ko-KR",
                "fr-FR", "de-DE", "es-ES", "ru-RU"
            ]

            if #available(macOS 13.0, *) {
                request.automaticallyDetectsLanguage = true
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            guard let observations = request.results, !observations.isEmpty else {
                return nil
            }

            return Self.mergeObservationsToParagraphs(observations)
        }.value
    }

    /// 基于系统 screencapture 的非阻塞异步截图 (匹配 Easydict 工业级实现)
    private func takeInteractiveScreenshot() async -> NSImage? {
        let temporaryPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr_cap_\(UUID().uuidString)")
            .appendingPathExtension("png")
            .path

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -i: 交互选框, -s: 仅选区模式 (防空格切窗口), -x: 静音
            process.arguments = ["-i", "-s", "-x", temporaryPath]

            process.terminationHandler = { _ in
                DispatchQueue.main.async {
                    // 读取失败时同样要清理，否则截图会留在临时目录里，
                    // 与「截图读取后即删除」的隐私承诺不符。
                    defer {
                        try? FileManager.default.removeItem(
                            atPath: temporaryPath
                        )
                    }

                    continuation.resume(
                        returning: NSImage(contentsOfFile: temporaryPath)
                    )
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// 智能段落重组算法 (Smart Paragraph Merging)
    /// 防止 Vision 框架将连续英文/中文按行切碎导致大模型断句生硬
    private nonisolated static func mergeObservationsToParagraphs(_ observations: [VNRecognizedTextObservation]) -> String {
        // 1. 按照屏幕阅读顺序排序（Y轴自上而下，X轴自左向右）
        let sorted = observations.sorted { a, b in
            if abs(a.boundingBox.minY - b.boundingBox.minY) > 0.035 {
                return a.boundingBox.minY > b.boundingBox.minY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }

        var result = ""
        var prevObservation: VNRecognizedTextObservation?

        for obs in sorted {
            guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else {
                continue
            }

            if let prev = prevObservation {
                let verticalGap = prev.boundingBox.minY - obs.boundingBox.maxY
                let avgHeight = (prev.boundingBox.height + obs.boundingBox.height) / 2.0

                if verticalGap > avgHeight * 0.9 {
                    // 大行距 -> 新段落
                    result += "\n\n"
                } else {
                    let prevTrimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isPrevEndsWithHyphen = prevTrimmed.hasSuffix("-")
                    let isPrevChinese = isChinese(prevTrimmed.last)
                    let isCurrChinese = isChinese(text.first)

                    if isPrevEndsWithHyphen {
                        result.removeLast()
                    } else if isPrevChinese || isCurrChinese {
                        // 中文字符换行无缝拼接
                    } else {
                        // 英文自然换行以空格连接
                        result += " "
                    }
                }
            }

            result += text
            prevObservation = obs
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func isChinese(_ char: Character?) -> Bool {
        guard let char, let scalar = char.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value) ||
               (0x20000...0x2A6DF).contains(scalar.value)
    }
}
