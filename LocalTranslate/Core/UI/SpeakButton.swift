import SwiftUI

/// 朗读按钮。正在读时变成停止。
///
/// 判不出语言（`languageCode` 为 nil）或本机没装该语音时不显示：
/// 给出一个点了没反应的按钮，比不给按钮更糟。
struct SpeakButton: View {

    let text: String
    let languageCode: String?
    /// 区分同一界面上的多个按钮，决定哪一个显示成「停止」。
    let id: String

    var size: CGFloat = 10

    @ObservedObject
    private var reader = SpeechReader.shared

    private var isSpeaking: Bool {
        reader.speakingID == id
    }

    private var available: Bool {
        guard let languageCode, !text.isEmpty else { return false }
        return SpeechReader.hasVoice(for: languageCode)
    }

    var body: some View {
        if available, let languageCode {
            Button {
                SpeechReader.shared.speak(
                    text,
                    languageCode: languageCode,
                    id: id
                )
            } label: {
                Image(
                    systemName: isSpeaking
                        ? "stop.circle"
                        : "speaker.wave.2"
                )
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isSpeaking ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(isSpeaking ? "停止朗读" : "朗读")
            .accessibilityLabel(isSpeaking ? "停止朗读" : "朗读")
        }
    }
}
