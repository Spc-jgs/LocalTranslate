import Foundation
@preconcurrency import CoreAudio
@preconcurrency import AVFoundation

public protocol SystemAudioCaptureDelegate: AnyObject {
    nonisolated func systemAudioCaptureDidOutput(pcmBuffer: AVAudioPCMBuffer)
    nonisolated func systemAudioCaptureAudioLevelDidChange(level: Float)
    nonisolated func systemAudioCaptureDidFail(error: Error)
}

/// Captures the outgoing system mix through a private Core Audio process tap.
/// This never creates a display stream, so macOS uses System Audio Recording
/// permission instead of showing the app as sharing the screen.
public final class SystemAudioCaptureService: @unchecked Sendable {

    public static let shared = SystemAudioCaptureService()

    public nonisolated(unsafe) weak var delegate: SystemAudioCaptureDelegate?

    private nonisolated struct CaptureResources: @unchecked Sendable {
        let tapID: AudioObjectID
        let aggregateDeviceID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
    }

    private enum CaptureError: LocalizedError {
        case coreAudio(operation: String, status: OSStatus)
        case invalidTapFormat

        var errorDescription: String? {
            switch self {
            case let .coreAudio(operation, status):
                return "\(operation)失败（Core Audio \(status)）"
            case .invalidTapFormat:
                return "无法读取系统音频采集格式"
            }
        }
    }

    private let audioQueue = DispatchQueue(
        label: "com.shaopc.LocalTranslate.audioProcessTap",
        qos: .userInteractive
    )
    private var resources: CaptureResources?
    private var isCapturing = false

    private init() {}

    public var isRunning: Bool {
        isCapturing
    }

    public func startCapture() async throws {
        guard !isCapturing, resources == nil else { return }

        let created = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CaptureResources, Error>) in
            audioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    continuation.resume(returning: try self.createCaptureResources())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        if Task.isCancelled {
            Self.destroy(created)
            throw CancellationError()
        }

        resources = created
        isCapturing = true
    }

    public func stopCapture() async {
        guard let resources else {
            isCapturing = false
            return
        }

        self.resources = nil
        isCapturing = false
        await withCheckedContinuation { continuation in
            audioQueue.async {
                Self.destroy(resources)
                continuation.resume()
            }
        }
    }

    private nonisolated func createCaptureResources() throws -> CaptureResources {
        let tapDescription = CATapDescription(
            monoGlobalTapButExcludeProcesses: []
        )
        tapDescription.name = "LocalTranslate System Audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            tapDescription.bundleIDs = [bundleIdentifier]
        }

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            operation: "创建系统音频 Tap"
        )

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?

        do {
            let tapUID = tapDescription.uuid.uuidString
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "LocalTranslate System Audio",
                kAudioAggregateDeviceUIDKey: "com.shaopc.LocalTranslate.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                // Auto-start makes AudioDeviceStart wait for the first audible
                // process. Start IO immediately so pause/stop always remains
                // responsive even while the system is silent.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: tapUID,
                        kAudioSubTapDriftCompensationKey: true
                    ]
                ]
            ]
            try Self.check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &aggregateDeviceID
                ),
                operation: "创建音频聚合设备"
            )

            let format = try Self.tapFormat(tapID)
            try Self.check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &ioProcID,
                    aggregateDeviceID,
                    audioQueue
                ) { [weak self] _, inputData, _, _, _ in
                    guard let self,
                          let pcmBuffer = Self.copyPCMBuffer(
                            inputData,
                            format: format
                          ) else { return }
                    self.deliver(pcmBuffer)
                },
                operation: "创建系统音频回调"
            )
            guard let ioProcID else {
                throw CaptureError.coreAudio(
                    operation: "创建系统音频回调",
                    status: kAudioHardwareUnspecifiedError
                )
            }
            try Self.check(
                AudioDeviceStart(aggregateDeviceID, ioProcID),
                operation: "启动系统音频采集"
            )

            return CaptureResources(
                tapID: tapID,
                aggregateDeviceID: aggregateDeviceID,
                ioProcID: ioProcID
            )
        } catch {
            if let ioProcID,
               aggregateDeviceID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            if aggregateDeviceID != kAudioObjectUnknown {
                AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            }
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    private nonisolated func deliver(_ buffer: AVAudioPCMBuffer) {
        let level = Self.calculateAudioLevel(buffer)
        delegate?.systemAudioCaptureAudioLevelDidChange(level: level)
        delegate?.systemAudioCaptureDidOutput(pcmBuffer: buffer)
    }

    private nonisolated static func destroy(_ resources: CaptureResources) {
        AudioDeviceStop(resources.aggregateDeviceID, resources.ioProcID)
        AudioDeviceDestroyIOProcID(
            resources.aggregateDeviceID,
            resources.ioProcID
        )
        AudioHardwareDestroyAggregateDevice(resources.aggregateDeviceID)
        AudioHardwareDestroyProcessTap(resources.tapID)
    }

    private nonisolated static func tapFormat(
        _ tapID: AudioObjectID
    ) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                &description
            ),
            operation: "读取系统音频格式"
        )
        guard let format = AVAudioFormat(streamDescription: &description) else {
            throw CaptureError.invalidTapFormat
        }
        return format
    }

    private nonisolated static func copyPCMBuffer(
        _ inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard let first = sourceBuffers.first,
              first.mNumberChannels > 0,
              first.mDataByteSize > 0 else { return nil }

        let bytesPerFrame = max(
            Int(format.streamDescription.pointee.mBytesPerFrame),
            1
        )
        let frameCount = AVAudioFrameCount(
            Int(first.mDataByteSize) / bytesPerFrame
        )
        guard frameCount > 0,
              let ownedBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
              ) else { return nil }
        ownedBuffer.frameLength = frameCount

        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            ownedBuffer.mutableAudioBufferList
        )
        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            let source = sourceBuffers[index]
            var destination = destinationBuffers[index]
            guard let sourceData = source.mData,
                  let destinationData = destination.mData else { continue }
            let byteCount = min(
                Int(source.mDataByteSize),
                Int(destination.mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destination.mDataByteSize = UInt32(byteCount)
            destinationBuffers[index] = destination
        }
        return ownedBuffer
    }

    private nonisolated static func calculateAudioLevel(
        _ buffer: AVAudioPCMBuffer
    ) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        for index in 0..<frames {
            let sample = channelData[index]
            sum += sample * sample
        }
        return min(max(sqrt(sum / Float(frames)) * 5, 0), 1)
    }

    private nonisolated static func check(
        _ status: OSStatus,
        operation: String
    ) throws {
        guard status == noErr else {
            throw CaptureError.coreAudio(operation: operation, status: status)
        }
    }
}
