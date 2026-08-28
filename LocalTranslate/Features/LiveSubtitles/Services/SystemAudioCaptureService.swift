import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics

public protocol SystemAudioCaptureDelegate: AnyObject {
    func systemAudioCaptureDidOutput(pcmBuffer: AVAudioPCMBuffer)
    func systemAudioCaptureAudioLevelDidChange(level: Float)
    func systemAudioCaptureDidFail(error: Error)
}

public final class SystemAudioCaptureService: NSObject, SCStreamDelegate, SCStreamOutput {

    public static let shared = SystemAudioCaptureService()

    public weak var delegate: SystemAudioCaptureDelegate?

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.shaopc.LocalTranslate.audioCaptureQueue", qos: .userInteractive)
    private var isCapturing = false

    private override init() {
        super.init()
    }

    public var isRunning: Bool {
        isCapturing
    }

    public func startCapture() async throws {
        guard !isCapturing else { return }

        // 检查屏幕录制权限
        guard CGPreflightScreenCaptureAccess() else {
            throw NSError(
                domain: "SystemAudioCaptureService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "需要屏幕录制权限以捕获系统音频"]
            )
        }

        // 获取可共享内容以创建 Filter
        let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = availableContent.displays.first else {
            throw NSError(
                domain: "SystemAudioCaptureService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "未找到有效的显示器"]
            )
        }

        // 创建仅捕获音频的 Filter (排除本应用自身音频)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1

        // 降低视频分辨率以节省 CPU (仅做音频内录)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        try await newStream.startCapture()

        self.stream = newStream
        self.isCapturing = true
    }

    public func stopCapture() async {
        guard isCapturing, let stream = self.stream else { return }

        do {
            try await stream.stopCapture()
        } catch {
            // 静默忽略停止异常
        }

        self.stream = nil
        self.isCapturing = false
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }

        guard let formatDescription = sampleBuffer.formatDescription,
              let audioBuffer = sampleBufferToPCMBuffer(sampleBuffer: sampleBuffer, formatDescription: formatDescription) else {
            return
        }

        // 计算音频能量电平
        let level = calculateAudioLevel(pcmBuffer: audioBuffer)
        delegate?.systemAudioCaptureAudioLevelDidChange(level: level)

        // 派发 PCM Buffer 给语音识别引擎
        delegate?.systemAudioCaptureDidOutput(pcmBuffer: audioBuffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.isCapturing = false
        self.stream = nil
        delegate?.systemAudioCaptureDidFail(error: error)
    }

    // MARK: - Helper

    private func sampleBufferToPCMBuffer(sampleBuffer: CMSampleBuffer, formatDescription: CMFormatDescription) -> AVAudioPCMBuffer? {
        guard var asbd = formatDescription.audioStreamBasicDescription else { return nil }
        guard let audioFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        let bytesToCopy = min(Int(audioBufferList.mBuffers.mDataByteSize), Int(pcmBuffer.frameLength) * Int(audioFormat.streamDescription.pointee.mBytesPerFrame))
        guard let source = audioBufferList.mBuffers.mData else { return nil }

        if let floatChannelData = pcmBuffer.floatChannelData {
            memcpy(floatChannelData[0], source, bytesToCopy)
        } else if let int16ChannelData = pcmBuffer.int16ChannelData {
            memcpy(int16ChannelData[0], source, bytesToCopy)
        } else {
            return nil
        }

        return pcmBuffer
    }

    private func calculateAudioLevel(pcmBuffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = pcmBuffer.floatChannelData?[0] else { return 0 }
        let frames = Int(pcmBuffer.frameLength)
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        return min(max(rms * 5.0, 0.0), 1.0)
    }
}
