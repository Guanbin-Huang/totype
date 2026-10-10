import AVFoundation
import Foundation

final class MobileAudioCapture {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.peter.totype.mobile.pcm")
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []
    var onInterruption: (@Sendable (String) -> Void)?
    private var continuation: AsyncThrowingStream<PCM16Chunk, Error>.Continuation?

    func start() throws -> AsyncThrowingStream<PCM16Chunk, Error> {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        let pair = AsyncThrowingStream<PCM16Chunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        continuation = pair.continuation
        let converter = PCMConverter()
        var sequence: Int64 = 0
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ASRProviderError.unavailable("麦克风音频格式不可用")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [queue] buffer, _ in
            guard let copy = buffer.deepCopy() else {
                pair.continuation.finish(throwing: ASRProviderError.unavailable("复制麦克风缓冲失败"))
                return
            }
            queue.async {
                do {
                    let data = try converter.convert(copy)
                    let chunk = PCM16Chunk(sequence: sequence, data: data, capturedAt: Date(), sampleRate: 16000, channels: 1)
                    sequence += 1
                    switch pair.continuation.yield(chunk) {
                    case .dropped: pair.continuation.finish(throwing: ASRProviderError.unavailable("音频发送积压；已停止，避免丢字"))
                    case .enqueued, .terminated: break
                    @unknown default: break
                    }
                } catch { pair.continuation.finish(throwing: error) }
            }
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() }
        catch { finish(); throw error }
        let interruptionHandler = onInterruption
        observers = [
            NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                object: session, queue: nil) { notification in
                if let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   AVAudioSession.InterruptionType(rawValue: raw) == .began {
                    let message = "录音被系统中断，请重新开始。"
                    pair.continuation.finish(throwing: ASRProviderError.unavailable(message))
                    interruptionHandler?(message)
                }
            },
            NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                object: session, queue: nil) { notification in
                if let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                   AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable {
                    let message = "音频输入设备已断开，请重新开始。"
                    pair.continuation.finish(throwing: ASRProviderError.unavailable(message))
                    interruptionHandler?(message)
                }
            }
        ]
        return pair.stream
    }
    // Remove the producer, drain conversion work, then finish. The sender drains before finalize.
    func finish() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        queue.sync { continuation?.finish() }
        continuation = nil
    }
    func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
