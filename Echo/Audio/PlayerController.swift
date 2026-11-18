import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import Combine

/// Текущее время воспроизведения отдельно, чтобы 4 раза в секунду
/// перерисовывались только полоска прогресса и тексты, а не весь интерфейс
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
}

/// Получает названия песен из потока интернет-радио (ICY StreamTitle)
final class RadioMetadataReceiver: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    var onTitle: ((String) -> Void)?

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        for group in groups {
            for item in group.items {
                if let s = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    onTitle?(fixCyrillic(s))
                    return
                }
            }
        }
    }
}

/// Мозг плеера: очередь, перемешивание, повтор, «Моя волна», онлайн-треки Audius,
/// радио, экран блокировки, таймер сна, учёт прослушиваний.
///
/// Онлайн-трек начинает играть сразу потоком (AVPlayer), параллельно скачивается
/// во временный кэш, а потом незаметно переключается на движок с эквалайзером.
/// Следующие треки скачиваются заранее, поэтому для них работает и кроссфейд.
final class PlayerController: ObservableObject {
    @Published private(set) var queue: [String] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var shuffle = false
    @Published var repeatMode: RepeatMode = .off { didSet { saveState() } }
    @Published private(set) var isWave = false
    @Published private(set) var isPreparingWave = false
    @Published private(set) var source: PlaybackSource = .none
    @Published private(set) var station: RadioStation?
    @Published private(set) var radioTitle: String?
    @Published private(set) var radioBuffering = false
    @Published private(set) var isBuffering = false
    @Published private(set) var sleepEndDate: Date?
    @Published private(set) var sleepAtTrackEnd = false
    @Published var showNowPlaying = false

    let clock = PlaybackClock()
    let library: Library
    let settings: AppSettings
    let online: OnlineStore

    private let engine = AudioEngine()

    // радио
    private var radioPlayer: AVPlayer?
    private var radioReceiver: RadioMetadataReceiver?
    private var radioStatusObserver: NSKeyValueObservation?

    // онлайн-поток (пока трек не скачался)
    private var streamPlayer: AVPlayer?
    private var streamingID: String?
    private var streamEndObserver: NSObjectProtocol?
    private var streamItemStatusObserver: NSKeyValueObservation?
    private var streamControlObserver: NSKeyValueObservation?

    private var tickTimer: Timer?
    private var originalQueue: [String] = []
    private var lastTick: Date?
    private var listenedThisTrack: Double = 0
    private var pendingListen: Double = 0
    private var playCounted = false
    private var crossfadeTriggered = false
    private var failures = 0
    private var wasPlayingBeforeInterruption = false
    private var tickCount = 0
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    var currentTrackID: String? { queue.indices.contains(index) ? queue[index] : nil }
    var currentTrack: Track? { currentTrackID.flatMap { library.resolve($0) } }
    var hasContent: Bool { source == .radio ? station != nil : currentTrack != nil }
    var upcoming: [String] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }
    var isCurrentOnline: Bool { currentTrackID.map(OnlineStore.isOnline) ?? false }

    init(library: Library, settings: AppSettings, online: OnlineStore) {
        self.library = library
        self.settings = settings
        self.online = online

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])

        engine.onTrackEnd = { [weak self] in self?.trackEnded() }
        engine.setEQ(gains: settings.eqGains, enabled: settings.eqEnabled)

        settings.$eqGains
            .combineLatest(settings.$eqEnabled)
            .sink { [weak self] value in
                self?.engine.setEQ(gains: value.0, enabled: value.1)
            }
            .store(in: &cancellables)

        setupRemoteCommands()
        setupNotifications()

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        restoreState()
    }

    // MARK: Запуск треков

    func playTracks(_ ids: [String], startAt: Int = 0, shuffled: Bool? = nil) {
        guard !ids.isEmpty else { return }
        let start = ids.indices.contains(startAt) ? startAt : 0
        if let s = shuffled { shuffle = s }
        isWave = false
        originalQueue = ids
        if shuffle {
            var rest = ids
            let first = rest.remove(at: start)
            queue = [first] + rest.shuffled()
            index = 0
        } else {
            queue = ids
            index = start
        }
        failures = 0
        startCurrent()
    }

    /// Пул треков для «Моей волны»: своя музыка, онлайн-лайки и открытия Audius
    private func wavePool() -> [Track] {
        var pool = library.tracks
        let likedOnline = online.likedTracks
        pool.append(contentsOf: likedOnline)
        if settings.waveOnline {
            let likedSet = Set(likedOnline.map(\.id))
            pool.append(contentsOf: online.discoveryTracks.filter { !likedSet.contains($0.id) })
        }
        return pool
    }

    func startWave() {
        let needDiscovery = settings.waveOnline && !online.discoveryIsFresh
        if needDiscovery && (library.tracks.isEmpty || online.discoveryIDs.isEmpty) {
            // без открытий волна пустая или слишком однообразная — сначала подгружаем
            isPreparingWave = true
            Task { [weak self] in
                guard let strong = self else { return }
                await strong.online.loadDiscovery()
                await MainActor.run {
                    strong.isPreparingWave = false
                    strong.startWaveNow()
                }
            }
            return
        }
        if needDiscovery {
            Task { [weak self] in await self?.online.loadDiscovery() }
        }
        startWaveNow()
    }

    private func startWaveNow() {
        let ids = WaveGenerator.next(count: 6, from: wavePool(), mood: settings.waveMood,
                                     recent: library.history.suffix(40).map(\.trackID))
        guard !ids.isEmpty else {
            library.toast = settings.waveOnline
                ? "Нет интернета, а своей музыки пока нет"
                : "Сначала добавь музыку или включи открытия Audius"
            return
        }
        isWave = true
        shuffle = false
        originalQueue = ids
        queue = ids
        index = 0
        failures = 0
        startCurrent()
    }

    /// Пользователь поменял характер волны — перестраиваем то, что ещё не играло
    func waveMoodChanged() {
        guard isWave else { return }
        queue = Array(queue.prefix(index + 1))
        ensureWaveBuffer()
        prefetchUpcoming()
    }

    private func ensureWaveBuffer() {
        guard isWave else { return }
        if queue.count - index <= 3 {
            let more = WaveGenerator.next(count: 6, from: wavePool(), mood: settings.waveMood,
                                          recent: Array(queue.suffix(40)))
            queue.append(contentsOf: more)
            originalQueue = queue
            if settings.waveOnline && !online.discoveryIsFresh {
                Task { [weak self] in await self?.online.loadDiscovery() }
            }
        }
    }

    private func startCurrent(at time: Double = 0, autoplay: Bool = true) {
        stopRadio()
        stopStream()
        flushListening()
        guard let track = currentTrack else {
            engine.stop()
            isPlaying = false
            source = .none
            updateNowPlaying()
            return
        }
        crossfadeTriggered = false
        listenedThisTrack = 0
        playCounted = false
        if autoplay { activateSession() }

        if track.isOnline {
            online.remember(track.id)
            if let cached = online.cachedFile(for: track.id),
               engine.load(url: cached, from: time, autoplay: autoplay) {
                AudioDownloader.touch(cached)
                didStartLocal(track: track, time: time, autoplay: autoplay)
            } else {
                // нет в кэше (или файл битый) — играем потоком, параллельно качаем
                online.dropCachedFile(track.id)
                engine.stop()
                startStream(track, at: time, autoplay: autoplay)
            }
            let id = track.id
            Task { [weak self] in
                guard let strong = self else { return }
                await strong.online.ensureArtwork(id)
                await MainActor.run {
                    if strong.currentTrackID == id { strong.updateNowPlaying() }
                }
            }
        } else if engine.load(url: library.url(for: track), from: time, autoplay: autoplay) {
            didStartLocal(track: track, time: time, autoplay: autoplay)
        } else {
            // файл повреждён или удалён — пропускаем
            failures += 1
            if failures < min(queue.count, 20), index + 1 < queue.count || isWave {
                if isWave { ensureWaveBuffer() }
                index += 1
                startCurrent(at: 0, autoplay: autoplay)
                return
            }
            isPlaying = false
            library.toast = "Не получается открыть «\(track.title)»"
        }
        ensureWaveBuffer()
        prefetchUpcoming()
        updateNowPlaying()
        saveState()
    }

    private func didStartLocal(track: Track, time: Double, autoplay: Bool) {
        failures = 0
        source = .local
        duration = engine.duration > 0 ? engine.duration : track.duration
        clock.time = time
        isPlaying = autoplay && engine.isPlaying
        lastTick = Date()
    }

    // MARK: Онлайн-поток

    private func startStream(_ track: Track, at time: Double, autoplay: Bool) {
        guard let url = online.streamURL(for: track.id) else { return }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        if time > 1 {
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        }
        let id = track.id
        streamEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.streamEnded(id: id)
        }
        streamItemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            let failed = it.status == .failed
            DispatchQueue.main.async {
                if failed { self?.streamFailed(id: id) }
            }
        }
        streamControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let waiting = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            DispatchQueue.main.async {
                guard let self = self, self.streamingID == id else { return }
                self.isBuffering = waiting
            }
        }
        streamPlayer = player
        streamingID = id
        source = .local
        duration = track.duration
        clock.time = time
        failures = 0
        lastTick = Date()
        if autoplay {
            player.play()
            isPlaying = true
            isBuffering = true
        } else {
            isPlaying = false
        }

        // качаем файл и переключаемся на движок с эквалайзером
        Task { [weak self] in
            guard let strong = self else { return }
            let file = await strong.online.download(id)
            guard let file = file else { return }
            await MainActor.run { strong.handoffToEngine(id: id, file: file) }
        }
    }

    private func handoffToEngine(id: String, file: URL) {
        guard streamingID == id, let sp = streamPlayer, currentTrackID == id else { return }
        let t = sp.currentTime().seconds
        guard t.isFinite else { return }
        // перед самым концом не переключаемся — пусть доиграет потоком
        if duration > 0, duration - t < 4 { return }
        let playing = isPlaying
        if engine.load(url: file, from: t + 0.05, autoplay: playing) {
            stopStream()
            duration = engine.duration > 0 ? engine.duration : duration
            clock.time = t
            isPlaying = playing && engine.isPlaying
            crossfadeTriggered = false
            updateNowPlaying()
        } else {
            online.dropCachedFile(id)
        }
    }

    private func stopStream() {
        if let obs = streamEndObserver { NotificationCenter.default.removeObserver(obs) }
        streamEndObserver = nil
        streamItemStatusObserver = nil
        streamControlObserver = nil
        streamPlayer?.pause()
        streamPlayer = nil
        streamingID = nil
        isBuffering = false
    }

    private func streamEnded(id: String) {
        guard streamingID == id else { return }
        stopStream()
        trackEnded()
    }

    private func streamFailed(id: String) {
        guard streamingID == id else { return }
        stopStream()
        library.toast = "Трек не загрузился — проверь интернет"
        failures += 1
        if failures < 5, index + 1 < queue.count || isWave {
            advance(auto: true)
        } else {
            isPlaying = false
            updateNowPlaying()
        }
    }

    /// Заранее скачиваем следующие онлайн-треки — переход будет мгновенным
    private func prefetchUpcoming() {
        let next = upcoming.prefix(2).filter { OnlineStore.isOnline($0) && online.cachedFile(for: $0) == nil }
        for id in next {
            Task { [weak self] in
                guard let strong = self else { return }
                _ = await strong.online.download(id)
            }
        }
    }

    private var playbackTime: Double {
        if let sp = streamPlayer {
            let s = sp.currentTime().seconds
            return s.isFinite ? s : clock.time
        }
        return engine.currentTime
    }

    // MARK: Управление

    func play() {
        switch source {
        case .radio:
            activateSession()
            radioPlayer?.play()
            isPlaying = true
        case .local:
            activateSession()
            if let sp = streamPlayer {
                sp.play()
                isPlaying = true
            } else {
                engine.resume()
                isPlaying = engine.isPlaying
            }
            lastTick = Date()
        case .none:
            if currentTrack != nil {
                startCurrent()
            } else {
                startWave()
            }
        }
        updateNowPlaying()
    }

    func pause() {
        switch source {
        case .radio: radioPlayer?.pause()
        case .local:
            if let sp = streamPlayer {
                sp.pause()
                clock.time = playbackTime
            } else {
                engine.pause()
                clock.time = engine.currentTime
            }
        case .none: break
        }
        isPlaying = false
        flushListening()
        updateNowPlaying()
        saveState()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func next() {
        if source == .radio { return }
        if let id = currentTrackID, clock.time < 30, duration > 45 {
            recordSkip(id)
        }
        advance(auto: false)
    }

    func previous() {
        if source == .radio { return }
        if clock.time > 4 || index == 0 {
            seek(to: 0)
            if !isPlaying { play() }
            return
        }
        index -= 1
        startCurrent()
    }

    func seek(to t: Double) {
        guard source == .local else { return }
        let target = min(max(0, t), max(0, duration - 0.3))
        if let sp = streamPlayer {
            sp.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        } else {
            engine.seek(to: target)
        }
        clock.time = target
        crossfadeTriggered = false
        updateNowPlaying()
    }

    func jump(toQueueIndex i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        startCurrent()
    }

    private func advance(auto: Bool, crossfade: Bool = false) {
        if auto && repeatMode == .one {
            if crossfade { return }
            startCurrent()
            return
        }
        if isWave { ensureWaveBuffer() }
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all && !queue.isEmpty {
            if shuffle {
                queue = queue.shuffled()
            }
            index = 0
        } else {
            // очередь закончилась: оставляем первый трек на паузе
            index = 0
            startCurrent(at: 0, autoplay: false)
            return
        }
        if crossfade, streamPlayer == nil, let track = currentTrack {
            let fileURL: URL? = track.isOnline ? online.cachedFile(for: track.id) : library.url(for: track)
            if let url = fileURL {
                flushListening()
                if engine.crossfade(to: url, duration: settings.crossfade) {
                    if track.isOnline { online.remember(track.id) }
                    source = .local
                    duration = engine.duration > 0 ? engine.duration : track.duration
                    clock.time = 0
                    listenedThisTrack = 0
                    playCounted = false
                    isPlaying = true
                    ensureWaveBuffer()
                    prefetchUpcoming()
                    updateNowPlaying()
                    saveState()
                    if track.isOnline {
                        let id = track.id
                        Task { [weak self] in
                            guard let strong = self else { return }
                            await strong.online.ensureArtwork(id)
                            await MainActor.run {
                                if strong.currentTrackID == id { strong.updateNowPlaying() }
                            }
                        }
                    }
                    return
                }
            }
        }
        startCurrent()
    }

    private func trackEnded() {
        if !playCounted, let id = currentTrackID {
            recordPlay(id)
            playCounted = true
        }
        if sleepAtTrackEnd {
            // таймер сна «до конца трека»: готовим следующий, но не включаем
            sleepAtTrackEnd = false
            if isWave { ensureWaveBuffer() }
            if index + 1 < queue.count { index += 1 }
            startCurrent(at: 0, autoplay: false)
            return
        }
        advance(auto: true)
    }

    // MARK: Статистика (своя музыка и онлайн)

    private func recordPlay(_ id: String) {
        if OnlineStore.isOnline(id) {
            online.recordPlay(id)
        }
        library.recordPlay(id)
    }

    private func recordSkip(_ id: String) {
        if OnlineStore.isOnline(id) {
            online.recordSkip(id)
        } else {
            library.recordSkip(id)
        }
    }

    // MARK: Очередь

    func playNext(_ id: String) {
        if queue.isEmpty || source != .local {
            playTracks([id])
            return
        }
        queue.insert(id, at: min(index + 1, queue.count))
        originalQueue.append(id)
        library.toast = "Сыграет следующим"
        prefetchUpcoming()
        saveState()
    }

    func addToQueue(_ id: String) {
        if queue.isEmpty || source != .local {
            playTracks([id])
            return
        }
        if isWave {
            queue.insert(id, at: min(index + 1, queue.count))
        } else {
            queue.append(id)
        }
        originalQueue.append(id)
        library.toast = "Добавлено в очередь"
        prefetchUpcoming()
        saveState()
    }

    func moveUpcoming(from source: IndexSet, to destination: Int) {
        var up = upcoming
        up.moveItems(fromOffsets: source, toOffset: destination)
        queue = Array(queue.prefix(index + 1)) + up
        prefetchUpcoming()
        saveState()
    }

    func removeUpcoming(at offsets: IndexSet) {
        var up = upcoming
        for o in offsets.sorted(by: >) where up.indices.contains(o) { up.remove(at: o) }
        queue = Array(queue.prefix(index + 1)) + up
        saveState()
    }

    func clearUpcoming() {
        queue = Array(queue.prefix(index + 1))
        saveState()
    }

    func toggleShuffle() {
        guard !isWave, let cur = currentTrackID else {
            shuffle.toggle()
            return
        }
        shuffle.toggle()
        if shuffle {
            originalQueue = queue
            var rest = queue
            rest.remove(at: index)
            queue = [cur] + rest.shuffled()
            index = 0
        } else if let i = originalQueue.firstIndex(of: cur) {
            queue = originalQueue
            index = i
        }
        prefetchUpcoming()
        saveState()
    }

    func cycleRepeat() {
        repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off
    }

    /// Трек удалили из медиатеки
    func trackDeleted(_ id: String) {
        let wasCurrent = currentTrackID == id
        if let i = queue.firstIndex(of: id), i < index { index -= 1 }
        queue.removeAll { $0 == id }
        originalQueue.removeAll { $0 == id }
        if wasCurrent {
            if queue.isEmpty {
                engine.stop()
                stopStream()
                source = .none
                isPlaying = false
                updateNowPlaying()
            } else {
                index = min(index, queue.count - 1)
                startCurrent(at: 0, autoplay: isPlaying)
            }
        }
        saveState()
    }

    // MARK: Лайки

    func isLiked(_ id: String) -> Bool {
        library.resolve(id)?.liked ?? false
    }

    func toggleLike(_ id: String) {
        if OnlineStore.isOnline(id) {
            online.toggleLike(id)
            objectWillChange.send()
        } else {
            library.toggleLike(id)
        }
    }

    func toggleLikeCurrent() {
        guard let id = currentTrackID else { return }
        toggleLike(id)
    }

    func dislikeCurrent() {
        guard let id = currentTrackID else { return }
        if OnlineStore.isOnline(id) {
            online.toggleDislike(id)
            objectWillChange.send()
        } else {
            library.toggleDislike(id)
        }
        if library.resolve(id)?.disliked == true {
            library.toast = "Больше не будет в «Моей волне»"
            next()
        }
    }

    // MARK: Радио

    func playStation(_ s: RadioStation) {
        guard let url = URL(string: s.url) else { return }
        if source == .local {
            engine.pause()
            streamPlayer?.pause()
        }
        flushListening()
        stopRadio()
        activateSession()

        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        let receiver = RadioMetadataReceiver()
        receiver.onTitle = { [weak self] title in
            guard let self = self else { return }
            self.radioTitle = title
            self.updateNowPlaying()
        }
        output.setDelegate(receiver, queue: DispatchQueue.main)
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        radioStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let waiting = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            DispatchQueue.main.async {
                self?.radioBuffering = waiting
            }
        }
        player.play()

        radioPlayer = player
        radioReceiver = receiver
        station = s
        radioTitle = nil
        source = .radio
        isPlaying = true
        isWave = false
        updateNowPlaying()
        RadioService.registerClick(s.id)
    }

    private func stopRadio() {
        radioStatusObserver = nil
        radioPlayer?.pause()
        radioPlayer = nil
        radioReceiver = nil
        radioBuffering = false
        if source == .radio {
            station = nil
            radioTitle = nil
            source = .none
        }
    }

    /// Вернуться из радио к своей музыке
    func leaveRadio() {
        stopRadio()
        if currentTrack != nil {
            startCurrent(at: clock.time, autoplay: false)
        }
    }

    // MARK: Таймер сна

    func setSleepTimer(minutes: Int?) {
        sleepEndDate = nil
        sleepAtTrackEnd = false
        guard let m = minutes else { return }
        if m < 0 {
            sleepAtTrackEnd = true
        } else {
            sleepEndDate = Date().addingTimeInterval(Double(m) * 60)
        }
    }

    // MARK: Тик (4 раза в секунду)

    private func tick() {
        tickCount += 1

        if let end = sleepEndDate, Date() >= end {
            sleepEndDate = nil
            pause()
            return
        }

        guard source == .local, streamPlayer != nil || engine.hasFile else { return }
        let t = playbackTime
        if abs(clock.time - t) > 0.05 { clock.time = t }

        let now = Date()
        if isPlaying, !isBuffering, let last = lastTick {
            let dt = now.timeIntervalSince(last)
            if dt > 0, dt < 2 {
                listenedThisTrack += dt
                pendingListen += dt
            }
        }
        lastTick = now

        if isPlaying, !playCounted, let id = currentTrackID,
           listenedThisTrack >= 30 || (duration > 0 && listenedThisTrack >= duration * 0.5) {
            playCounted = true
            recordPlay(id)
        }

        if pendingListen >= 30 { flushListening() }
        if tickCount % 20 == 0 { saveTimeOnly() }

        // плавный переход к следующему треку (только когда играет движок)
        let cf = settings.crossfade
        let hasNext = isWave || index + 1 < queue.count || repeatMode == .all
        if streamPlayer == nil, isPlaying, cf > 0, !crossfadeTriggered, repeatMode != .one, hasNext,
           duration > cf * 2 + 5, duration - t <= cf, !sleepAtTrackEnd {
            crossfadeTriggered = true
            if !playCounted, let id = currentTrackID {
                recordPlay(id)
                playCounted = true
            }
            advance(auto: true, crossfade: true)
        }
    }

    private func flushListening() {
        guard pendingListen > 0, let id = currentTrackID else {
            pendingListen = 0
            return
        }
        library.addListening(id, seconds: pendingListen)
        pendingListen = 0
    }

    // MARK: Аудиосессия

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func setupNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            self?.handleRouteChange(note)
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine.engine, queue: .main) { [weak self] _ in
            self?.engine.handleConfigurationChange()
        })
    }

    /// Приложение ушло в фон — сохраняем всё (вызывается из EchoApp)
    func appWillResignActive() {
        flushListening()
        saveState()
        library.saveNow()
        online.saveNow()
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying { pause() }
        case .ended:
            let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
            if wasPlayingBeforeInterruption && opts.contains(.shouldResume) {
                play()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // выдернули наушники — ставим на паузу, как все нормальные плееры
        if reason == .oldDeviceUnavailable, isPlaying {
            pause()
        }
    }

    // MARK: Экран блокировки и пульт

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        _ = c.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        _ = c.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        _ = c.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlay()
            return .success
        }
        _ = c.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        _ = c.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        _ = c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        let center = MPNowPlayingInfoCenter.default()
        if source == .radio, let st = station {
            info[MPMediaItemPropertyTitle] = radioTitle ?? st.name
            info[MPMediaItemPropertyArtist] = st.name
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            let c = MPRemoteCommandCenter.shared()
            c.nextTrackCommand.isEnabled = false
            c.previousTrackCommand.isEnabled = false
            c.changePlaybackPositionCommand.isEnabled = false
        } else if let t = currentTrack {
            info[MPMediaItemPropertyTitle] = t.title
            info[MPMediaItemPropertyArtist] = t.displayArtist
            if !t.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = t.album }
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            if let img = ArtworkCache.shared.image(for: t.id) {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            }
            let c = MPRemoteCommandCenter.shared()
            c.nextTrackCommand.isEnabled = true
            c.previousTrackCommand.isEnabled = true
            c.changePlaybackPositionCommand.isEnabled = true
        } else {
            center.nowPlayingInfo = nil
            return
        }
        center.nowPlayingInfo = info
    }

    // MARK: Сохранение сессии

    private func saveTimeOnly() {
        UserDefaults.standard.set(clock.time, forKey: "state.time")
    }

    private func saveState() {
        let d = UserDefaults.standard
        guard source != .radio else { return }
        d.set(queue, forKey: "state.queue")
        d.set(originalQueue, forKey: "state.original")
        d.set(index, forKey: "state.index")
        d.set(clock.time, forKey: "state.time")
        d.set(isWave, forKey: "state.wave")
        d.set(shuffle, forKey: "state.shuffle")
        d.set(repeatMode.rawValue, forKey: "state.repeat")
    }

    private func restoreState() {
        let d = UserDefaults.standard
        // сначала читаем всё, потом меняем свойства (repeatMode при записи сам сохраняет состояние)
        let saved = d.stringArray(forKey: "state.queue") ?? []
        let savedOriginal = d.stringArray(forKey: "state.original") ?? []
        let savedIndex = d.integer(forKey: "state.index")
        let savedTime = d.double(forKey: "state.time")
        let savedWave = d.bool(forKey: "state.wave")
        let savedShuffle = d.bool(forKey: "state.shuffle")
        let savedRepeat = RepeatMode(rawValue: d.integer(forKey: "state.repeat")) ?? .off

        let currentID = saved.indices.contains(savedIndex) ? saved[savedIndex] : nil
        let valid = saved.filter { library.resolve($0) != nil }
        if !valid.isEmpty {
            queue = valid
            let orig = savedOriginal.filter { library.resolve($0) != nil }
            originalQueue = orig.isEmpty ? valid : orig
            index = currentID.flatMap { valid.firstIndex(of: $0) } ?? 0
            isWave = savedWave
            shuffle = savedShuffle
        }
        repeatMode = savedRepeat
        if let cur = currentTrack, !cur.isOnline || online.cachedFile(for: cur.id) != nil {
            startCurrent(at: savedTime, autoplay: false)
        } else if currentTrack != nil {
            // онлайн-трек без кэша — не грузим сеть при запуске, начнём по кнопке
            source = .none
            duration = currentTrack?.duration ?? 0
            clock.time = 0
        }
    }
}
