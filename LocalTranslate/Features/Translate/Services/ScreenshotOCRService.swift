import AppKit
import Foundation
import Vision

@MainActor
final class ScreenshotOCRService {
    static let shared = ScreenshotOCRService()

    private init() {}

    /// 调起系统原生交互框选，并对截屏进行精准 Vision OCR 识别与段落重组
    func captureAndRecognizeText() async throws -> String? {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("local_translate_ocr_\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        // 1. 异步调用原生截图 CLI
        let success = await runScreenCapture(outputURL: tempFile)
        guard success, FileManager.default.fileExists(atPath: tempFile.path) else {
            return nil // 用户按 ESC 取消
        }

        // 2. 读取物理像素 CGImage
        guard let nsImage = NSImage(contentsOf: tempFile),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        // 3. 在后台异步执行 Apple Vision 神经引擎 OCR 提取
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]

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

    private func runScreenCapture(outputURL: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                // -i: 交互选框, -x: 静音无快门声
                process.arguments = ["-i", "-x", outputURL.path]

                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// 智能段落重组算法 (Smart Paragraph Merging)
    /// 防止 Vision 框架将连续英文/中文按行切碎导致大模型断句生硬
    private nonisolated static func mergeObservationsToParagraphs(_ observations: [VNRecognizedTextObservation]) -> String {
        // 1. 按照屏幕阅读顺序排序（Y轴自上而下，X轴自左向右）
        let sorted = observations.sorted { a, b in
            // Vision 坐标系原点在左下角，minY 越大代表越靠上
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

                // 2. 判断是否属于换段落还是行内换行
                if verticalGap > avgHeight * 0.9 {
                    // 大行距 -> 新段落
                    result += "\n\n"
                } else {
                    // 行距紧密 -> 判断是否为代码/项目符号列表/中英文拼接
                    let prevTrimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isPrevEndsWithHyphen = prevTrimmed.hasSuffix("-")
                    let isPrevChinese = isChinese(prevTrimmed.last)
                    let isCurrChinese = isChinese(text.first)

                    if isPrevEndsWithHyphen {
                        // 英文连字符换行 (如 "imple-\nmentation" -> "implementation")
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
