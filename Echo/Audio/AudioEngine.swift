import AVFoundation

/// Аудиодвижок на AVAudioEngine: два плеера для плавного перехода (кроссфейда),
/// 10-полосный эквалайзер. Все вызовы — с главного потока.
final class AudioEngine {
    let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let nodes: [AVAudioPlayerNode] = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    private var files: [AVAudioFile?] = [nil, nil]
    private var startFrames: [AVAudioFramePosition] = [0, 0]
    private var tokens: [Int] = [0, 0]
    private var active = 0

    private var fadeTimer: Timer?
    private var fadeStart = Date()
    private var fadeDuration: Double = 0
    private var fadeOld = 1

    private(set) var isPlaying = false
    private var lastKnownTime: Double = 0

    /// Трек доиграл до конца (не вызывается при stop/seek)
    var onTrackEnd: (() -> Void)?

    static let bandFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    init() {
        engine.attach(mixer)
        engine.attach(eq)
        for n in nodes { engine.attach(n) }

        let out = engine.mainMixerNode.outputFormat(forBus: 0)
        let rate = out.sampleRate > 0 ? out.sampleRate : 44100
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)

        for (i, n) in nodes.enumerated() {
            engine.connect(n, to: mixer, fromBus: 0, toBus: i, format: format)
        }
        engine.connect(mixer, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)

        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Self.bandFrequencies[i]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        engine.prepare()
    }

    // MARK: Состояние

    var hasFile: Bool { files[active] != nil }

    var duration: Double {
        guard let f = files[active] else { return 0 }
        let sr = f.processingFormat.sampleRate
        return sr > 0 ? Double(f.length) / sr : 0
    }

    var currentTime: Double {
        guard let f = files[active] else { return 0 }
        let sr = f.processingFormat.sampleRate
        let node = nodes[active]
        if isPlaying, let nodeTime = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nodeTime), sr > 0 {
            let t = Double(startFrames[active] + pt.sampleTime) / sr
            lastKnownTime = min(max(0, t), duration)
        }
        return lastKnownTime
    }

    // MARK: Эквалайзер

    func setEQ(gains: [Float], enabled: Bool) {
        for (i, g) in gains.prefix(eq.bands.count).enumerated() {
            eq.bands[i].gain = max(-12, min(12, g))
        }
        let maxBoost = gains.max() ?? 0
        eq.globalGain = enabled ? -max(0, maxBoost) * 0.5 : 0
        eq.bypass = !enabled
    }

    // MARK: Воспроизведение

    private func ensureRunning() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            print("Не удалось запустить движок: \(error)")
        }
    }

    /// Загружает файл в активный плеер и (по желанию) запускает
    @discardableResult
    func load(url: URL, from time: Double = 0, autoplay: Bool = true) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        cancelFade()
        for i in 0..<2 {
            tokens[i] += 1
            nodes[i].stop()
            nodes[i].volume = 1
            files[i] = nil
        }
        let slot = active
        let node = nodes[slot]
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: mixer, fromBus: 0, toBus: slot, format: file.processingFormat)
        files[slot] = file
        lastKnownTime = max(0, time)
        schedule(slot: slot, from: lastKnownTime)
        if autoplay {
            ensureRunning()
            node.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
        return true
    }

    private func schedule(slot: Int, from time: Double) {
        guard let file = files[slot] else { return }
        let sr = file.processingFormat.sampleRate
        let total = file.length
        var start = AVAudioFramePosition(max(0, time) * sr)
        if start >= total { start = max(0, total - 1) }
        startFrames[slot] = start
        let count = AVAudioFrameCount(max(1, total - start))
        let token = tokens[slot]
        nodes[slot].scheduleSegment(file, startingFrame: start, frameCount: count, at: nil,
                                    completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.tokens[slot] == token else { return }
                self.segmentFinished(slot: slot)
            }
        }
    }

    private func segmentFinished(slot: Int) {
        guard slot == active else { return }
        isPlaying = false
        lastKnownTime = duration
        onTrackEnd?()
    }

    func pause() {
        _ = currentTime
        finishFadeNow()
        nodes[active].pause()
        isPlaying = false
        // останавливаем и сам движок, чтобы не тратить батарею на тишину
        engine.pause()
    }

    func resume() {
        guard files[active] != nil else { return }
        if !engine.isRunning {
            // движок остановили (звонок, смена наушников) — перепланируем с последней позиции
            let t = lastKnownTime
            ensureRunning()
            tokens[active] += 1
            nodes[active].stop()
            schedule(slot: active, from: t)
        }
        nodes[active].play()
        isPlaying = true
    }

    func seek(to time: Double) {
        guard files[active] != nil else { return }
        finishFadeNow()
        let wasPlaying = isPlaying
        let node = nodes[active]
        tokens[active] += 1
        node.stop()
        lastKnownTime = min(max(0, time), duration)
        schedule(slot: active, from: lastKnownTime)
        if wasPlaying {
            ensureRunning()
            node.play()
        }
    }

    func stop() {
        cancelFade()
        for i in 0..<2 {
            tokens[i] += 1
            nodes[i].stop()
            files[i] = nil
        }
        isPlaying = false
        lastKnownTime = 0
    }

    // MARK: Кроссфейд

    /// Плавно переходит на следующий файл: новый трек нарастает, старый затихает
    @discardableResult
    func crossfade(to url: URL, duration fade: Double) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        finishFadeNow()
        let old = active
        let new = 1 - active
        tokens[new] += 1
        nodes[new].stop()
        engine.disconnectNodeOutput(nodes[new])
        engine.connect(nodes[new], to: mixer, fromBus: 0, toBus: new, format: file.processingFormat)
        files[new] = file
        schedule(slot: new, from: 0)
        nodes[new].volume = 0
        ensureRunning()
        nodes[new].play()
        active = new
        lastKnownTime = 0
        isPlaying = true

        fadeOld = old
        fadeStart = Date()
        fadeDuration = max(0.5, fade)
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.fadeTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
        return true
    }

    private func fadeTick() {
        let p = Float(min(1, Date().timeIntervalSince(fadeStart) / fadeDuration))
        // равномощная кривая — громкость не проседает посередине
        nodes[active].volume = sin(p * .pi / 2)
        nodes[fadeOld].volume = cos(p * .pi / 2)
        if p >= 1 { completeFade() }
    }

    private func completeFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        let old = fadeOld
        guard old != active else { return }
        tokens[old] += 1
        nodes[old].stop()
        nodes[old].volume = 1
        files[old] = nil
        nodes[active].volume = 1
    }

    private func finishFadeNow() {
        if fadeTimer != nil { completeFade() }
    }

    private func cancelFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    // MARK: Смена аудиовыхода

    /// Вызывается при AVAudioEngineConfigurationChange (подключили/отключили Bluetooth и т.п.)
    func handleConfigurationChange() {
        let t = lastKnownTime
        let wasPlaying = isPlaying
        finishFadeNow()
        guard files[active] != nil else { return }
        tokens[active] += 1
        nodes[active].stop()
        schedule(slot: active, from: t)
        if wasPlaying {
            ensureRunning()
            nodes[active].play()
        }
    }
}
