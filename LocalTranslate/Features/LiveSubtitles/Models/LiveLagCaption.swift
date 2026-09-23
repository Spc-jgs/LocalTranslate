import Foundation

/// 字幕条上「落后语音多少秒」的文案。
///
/// 设置页已经有这个数字；看视频的人只看到「追赶中」。两处必须同一句话，
/// 否则调节奏时对照不上。
nonisolated enum LiveLagCaption {
    static func text(lag: TimeInterval, catchingUp: Bool) -> String {
        let seconds = String(format: "%.1f 秒", max(lag, 0))
        return catchingUp ? seconds + "（追赶中）" : seconds
    }
}
