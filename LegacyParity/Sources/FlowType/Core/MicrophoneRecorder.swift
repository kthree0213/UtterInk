import AVFoundation
import Foundation

/// 用 AVAudioEngine 把麦克风写入临时 CAF，供 WhisperKit 转写；同时在 tap 内估算输入电平供 UI 使用。
final class MicrophoneRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var outputURL: URL?

    /// 音频线程上更新的平滑电平，供节流回调使用。
    private var smoothedLevel: Float = 0
    private var lastEmitMono: CFAbsoluteTime = 0
    private let emitInterval: CFAbsoluteTime = 1.0 / 40.0
    private var levelUpdate: (@Sendable (Float) -> Void)?

    /// macOS 14+ 使用 `AVAudioApplication` 与 `AVAudioEngine` 录音一致，系统才会弹出麦克风授权并出现在「隐私与安全性 → 麦克风」列表。
    static func requestMicrophonePermission() async -> Bool {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                return await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            @unknown default:
                return false
            }
        }
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// - Parameter levelUpdate: 在主线程节流调用，参数为约 0…1 的电平（已平滑与映射）。
    func startRecording(levelUpdate: (@Sendable (Float) -> Void)? = nil) throws {
        stopRecording()

        self.levelUpdate = levelUpdate
        smoothedLevel = 0
        lastEmitMono = 0

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowType-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        self.engine = engine
        self.audioFile = file
        self.outputURL = url

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if let out = self.audioFile {
                try? out.write(from: buffer)
            }
            guard let update = self.levelUpdate else { return }

            let instant = Self.instantaneousLevel(from: buffer)
            // 上升快、下降慢，减少图标抖动。
            let attack: Float = 0.45
            let release: Float = 0.12
            if instant > self.smoothedLevel {
                self.smoothedLevel = self.smoothedLevel * (1 - attack) + instant * attack
            } else {
                self.smoothedLevel = self.smoothedLevel * (1 - release) + instant * release
            }

            let now = CFAbsoluteTimeGetCurrent()
            if now - self.lastEmitMono >= self.emitInterval {
                self.lastEmitMono = now
                update(self.smoothedLevel)
            }
        }

        try engine.start()
    }

    @discardableResult
    func stopRecording() -> URL? {
        levelUpdate = nil
        smoothedLevel = 0
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        audioFile = nil
        let url = outputURL
        outputURL = nil
        return url
    }

    /// 将 RMS 映射到 0…1，偏重于语音常见幅度。
    private static func instantaneousLevel(from buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let chCount = Int(buffer.format.channelCount)

        if let ch = buffer.floatChannelData {
            var maxRms: Float = 0
            for c in 0..<chCount {
                let p = ch[c]
                var sum: Float = 0
                for i in 0..<frames {
                    let s = p[i]
                    sum += s * s
                }
                maxRms = max(maxRms, sqrt(sum / Float(frames)))
            }
            let shaped = sqrt(maxRms * 14)
            return min(1, max(0, shaped))
        }

        if let ch = buffer.int16ChannelData {
            let scale: Float = 1.0 / 32768.0
            var maxRms: Float = 0
            for c in 0..<chCount {
                let p = ch[c]
                var sum: Float = 0
                for i in 0..<frames {
                    let s = Float(p[i]) * scale
                    sum += s * s
                }
                maxRms = max(maxRms, sqrt(sum / Float(frames)))
            }
            let shaped = sqrt(maxRms * 14)
            return min(1, max(0, shaped))
        }

        return 0
    }
}
