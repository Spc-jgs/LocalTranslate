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
        guard var asbd = formatDescription.audioStreamBasicDescription,
              let audioFormat = AVAudioFormat(streamDescription: &asbd) else {
            return nil
        }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)

        var bufferListSizeNeeded: Int = 0
        var blockBuffer: CMBlockBuffer?

        // 1. 查询所需 AudioBufferList 准确内存大小
        let queryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )

        guard queryStatus == noErr, bufferListSizeNeeded > 0 else { return nil }

        // 2. 动态分配内存提取真实音频流
        let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: bufferListSizeNeeded)
        defer { bufferListPtr.deallocate() }

        let extractStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferListPtr,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard extractStatus == noErr else { return nil }

        let audioBufferPointer = UnsafeBufferPointer(
            start: &bufferListPtr.pointee.mBuffers,
            count: Int(bufferListPtr.pointee.mNumberBuffers)
        )

        if let floatChannelData = pcmBuffer.floatChannelData {
            for (index, buffer) in audioBufferPointer.enumerated() {
                if let source = buffer.mData, index < Int(audioFormat.channelCount) {
                    memcpy(floatChannelData[index], source, Int(buffer.mDataByteSize))
                }
            }
        } else if let int16ChannelData = pcmBuffer.int16ChannelData {
            for (index, buffer) in audioBufferPointer.enumerated() {
                if let source = buffer.mData, index < Int(audioFormat.channelCount) {
                    memcpy(int16ChannelData[index], source, Int(buffer.mDataByteSize))
                }
            }
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
