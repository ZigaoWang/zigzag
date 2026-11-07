import AVFoundation
import CoreAudio
import WebKit

/// The sound Zigzag's pages play, as it goes to the speakers, through a Core Audio process tap on WebKit's GPU
/// process (where every page's audio is played). Used by tab capture when a page's own sound can't be reached:
/// WebKit gives Web Audio only silence for streamed (MSE) and protected video, which is most video sites.
///
/// It hears all of Zigzag's web audio, not one tab. macOS asks once whether Zigzag may record the sound it plays.
/// Samples come mixed to mono, as Float, on a queue of its own.
@available(macOS 14.4, *)
nonisolated final class SystemAudioTap: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case noAudioProcess, status(String, OSStatus)
        var description: String {
            switch self {
            case .noAudioProcess: return "WebKit's audio isn't playing"
            case let .status(step, code): return "\(step) failed (\(code))"
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.zigzag.system-audio-tap", qos: .userInitiated)

    /// The GPU process plays every page's sound. Its ID comes from WebKit (`_gpuProcessIdentifier`); 0 before it runs.
    @MainActor
    static func webAudioProcess(of webView: WKWebView) -> pid_t {
        let selector = NSSelectorFromString("_gpuProcessIdentifier")
        guard webView.responds(to: selector) else { return 0 }
        typealias Getter = @convention(c) (AnyObject, Selector) -> pid_t
        return unsafeBitCast(webView.method(for: selector), to: Getter.self)(webView, selector)
    }

    /// Starts hearing `pid`'s sound; `samples` gets each buffer (mono Float, its sample rate). `muting` silences that
    /// process on the speakers meanwhile, as Chrome silences a captured tab (the tap still hears it).
    func start(pid: pid_t, muting: Bool, samples: @escaping @Sendable (UnsafeBufferPointer<Float>, Double) -> Void) throws {
        let process = try Self.audioObject(for: pid)
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.name = "Zigzag tab capture"
        description.isPrivate = true
        description.muteBehavior = muting ? .mutedWhenTapped : .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure.status("Creating the tap", status) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { stop(); throw Failure.status("Reading the tap's format", status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Zigzag Tab Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID)
        guard status == noErr else { stop(); throw Failure.status("Creating the capture device", status) }

        let rate = format.mSampleRate
        let channels = Int(max(1, format.mChannelsPerFrame))
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        var mono = [Float]()
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            if interleaved {
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                let all = data.assumingMemoryBound(to: Float.self)
                if mono.count != frames { mono = [Float](repeating: 0, count: frames) }
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += all[frame * channels + channel] }
                    mono[frame] = sum / Float(channels)
                }
            } else {
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                if mono.count != frames { mono = [Float](repeating: 0, count: frames) }
                for index in 0..<frames { mono[index] = 0 }
                for buffer in buffers {
                    guard let channel = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for index in 0..<frames { mono[index] += channel[index] / Float(buffers.count) }
                }
            }
            mono.withUnsafeBufferPointer { samples($0, rate) }
        }
        guard status == noErr else { stop(); throw Failure.status("Listening", status) }
        status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else { stop(); throw Failure.status("Starting", status) }
    }

    func stop() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private static func audioObject(for pid: pid_t) throws -> AudioObjectID {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { throw Failure.noAudioProcess }
        return object
    }
}
