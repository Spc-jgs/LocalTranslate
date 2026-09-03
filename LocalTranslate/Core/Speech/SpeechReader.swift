import AVFoundation
import Combine
import Foundation

/// 朗读一段文本。
///
/// 只封装系统合成器，不含任何 Feature 的会话或状态机，因此放在共享层。
/// 合成器**惰性创建**：从不朗读的用户不会为它付出任何代价——这是空闲态
/// 不持有资源那条约束的要求，构造类型不算激活，真正拿到音频设备才算。
@MainActor
final class SpeechReader: NSObject, ObservableObject {

    static let shared = SpeechReader()

    /// 正在朗读的调用方标识；`nil` 表示没有在读。
    ///
    /// 用标识而不是布尔值，是因为界面上有多个喇叭按钮（原文、译文），
    /// 需要知道该让哪一个显示成「停止」。
    @Published private(set) var speakingID: String?

    private var synthesizer: AVSpeechSynthesizer?

    private override init() {
        super.init()
    }

    /// 该语言在本机是否装了语音。取不到就不该给出可点的按钮——
    /// 静默失败会让用户以为是功能坏了。
    nonisolated static func hasVoice(for languageCode: String) -> Bool {
        AVSpeechSynthesisVoice(language: languageCode) != nil
    }

    /// 朗读；再次朗读同一个 `id` 表示停止。
    func speak(_ text: String, languageCode: String, id: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return }

        // 点正在读的那个按钮 = 停止。
        guard speakingID != id else {
            stop()
            return
        }

        guard let voice = AVSpeechSynthesisVoice(language: languageCode) else {
            return
        }

        stop()

        let synthesizer = synthesizer ?? {
            let created = AVSpeechSynthesizer()
            created.delegate = self
            self.synthesizer = created
            return created
        }()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice

        speakingID = id
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        speakingID = nil
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechReader: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.speakingID = nil
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.speakingID = nil
        }
    }
}
