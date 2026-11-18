import Foundation

/// Скачивает онлайн-треки во временный кэш, чтобы играть их через движок
/// с эквалайзером и плавными переходами. Старые файлы удаляются сами.
actor AudioDownloader {
    static let shared = AudioDownloader()

    static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OnlineAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let cacheLimitBytes: Int64 = 700_000_000

    private var tasks: [String: Task<URL?, Never>] = [:]

    nonisolated static func cachedFile(audiusID: String) -> URL? {
        let url = cacheDir.appendingPathComponent("\(audiusID).mp3")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    nonisolated static func remove(audiusID: String) {
        let url = cacheDir.appendingPathComponent("\(audiusID).mp3")
        try? FileManager.default.removeItem(at: url)
    }

    func file(audiusID: String) async -> URL? {
        if let cached = Self.cachedFile(audiusID: audiusID) {
            Self.touch(cached)
            return cached
        }
        if let running = tasks[audiusID] {
            return await running.value
        }
        let task = Task<URL?, Never> {
            await Self.fetch(audiusID: audiusID)
        }
        tasks[audiusID] = task
        let result = await task.value
        tasks[audiusID] = nil
        if result != nil { Self.trimCache() }
        return result
    }

    private static func fetch(audiusID: String) async -> URL? {
        guard let url = AudiusAPI.streamURL(audiusID: audiusID) else { return nil }
        do {
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
            let (tmp, response) = try await URLSession.shared.download(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: tmp)
                return nil
            }
            let dest = cacheDir.appendingPathComponent("\(audiusID).mp3")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    nonisolated static func cacheSize() -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for url in items {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    nonisolated static func clearCache() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for url in items { try? fm.removeItem(at: url) }
    }

    /// Удаляем самые старые файлы, если кэш больше лимита
    nonisolated static func trimCache() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for url in items {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentModificationDate ?? .distantPast
            files.append((url: url, size: size, date: date))
            total += size
        }
        guard total > cacheLimitBytes else { return }
        for f in files.sorted(by: { $0.date < $1.date }) {
            try? fm.removeItem(at: f.url)
            total -= f.size
            if total <= cacheLimitBytes * 8 / 10 { break }
        }
    }
}

/// Онлайн-треки: лайки, история, открытия для «Моей волны».
/// Изменяется только с главного потока.
final class OnlineStore: ObservableObject {
    static let shared = OnlineStore()

    @Published private(set) var likedIDs: [String] = []
    @Published private(set) var dislikedIDs: Set<String> = []
    @Published private(set) var discoveryIDs: [String] = []
    @Published private(set) var recentSearches: [String] = []

    /// Все известные треки (из поиска, трендов и сохранённые)
    private(set) var known: [String: OnlineTrack] = [:]
    /// Треки, которые храним между запусками (лайкнутые, сыгранные, в плейлистах)
    private var persisted: [String] = []
    private var plays: [String: Int] = [:]
    private var skips: [String: Int] = [:]
    private var lastPlayed: [String: Date] = [:]
    private var discoveryDate: Date = .distantPast
    private var saveTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var tracks: [OnlineTrack]
        var liked: [String]
        var disliked: [String]
        var plays: [String: Int]
        var skips: [String: Int]
        var lastPlayed: [String: Date]
        var searches: [String]
    }

    private static var fileURL: URL { Library.supportDir.appendingPathComponent("online.json") }

    init() {
        load()
    }

    // MARK: Доступ

    static func isOnline(_ id: String) -> Bool { id.hasPrefix(AudiusAPI.idPrefix) }

    func onlineTrack(_ id: String) -> OnlineTrack? { known[id] }

    func track(_ id: String) -> Track? {
        guard let o = known[id] else { return nil }
        var t = Track(id: o.id, fileName: "", title: o.title, artist: o.artist, album: "",
                      genre: o.genre, duration: o.duration, hasArtwork: false,
                      addedAt: o.releaseDate ?? Date.distantPast)
        t.playCount = plays[id] ?? 0
        t.skipCount = skips[id] ?? 0
        t.lastPlayedAt = lastPlayed[id]
        t.liked = likedIDs.contains(id)
        t.disliked = dislikedIDs.contains(id)
        return t
    }

    func tracks(_ ids: [String]) -> [Track] { ids.compactMap { track($0) } }

    var likedTracks: [Track] { tracks(likedIDs) }

    var discoveryTracks: [Track] { tracks(discoveryIDs).filter { !$0.disliked } }

    func artworkURL(for id: String, large: Bool) -> URL? {
        guard let o = known[id] else { return nil }
        let s = large ? (o.artworkLarge.isEmpty ? o.artworkSmall : o.artworkLarge) : (o.artworkSmall.isEmpty ? o.artworkLarge : o.artworkSmall)
        return s.isEmpty ? nil : URL(string: s)
    }

    func streamURL(for id: String) -> URL? {
        guard let a = AudiusAPI.audiusID(from: id) else { return nil }
        return AudiusAPI.streamURL(audiusID: a)
    }

    func cachedFile(for id: String) -> URL? {
        guard let a = AudiusAPI.audiusID(from: id) else { return nil }
        return AudioDownloader.cachedFile(audiusID: a)
    }

    // MARK: Изменения

    func register(_ list: [OnlineTrack]) {
        for t in list { known[t.id] = t }
    }

    /// Запомнить трек навсегда (сыграли, лайкнули, добавили в плейлист)
    func remember(_ id: String) {
        guard known[id] != nil, !persisted.contains(id) else { return }
        persisted.append(id)
        if persisted.count > 2000 {
            let keep = Set(likedIDs).union(dislikedIDs)
            let oldest = Set(persisted.prefix(300)).subtracting(keep)
            persisted.removeAll { oldest.contains($0) }
        }
        scheduleSave()
    }

    func toggleLike(_ id: String) {
        if let i = likedIDs.firstIndex(of: id) {
            likedIDs.remove(at: i)
        } else {
            likedIDs.insert(id, at: 0)
            dislikedIDs.remove(id)
            remember(id)
        }
        scheduleSave()
    }

    func toggleDislike(_ id: String) {
        if dislikedIDs.contains(id) {
            dislikedIDs.remove(id)
        } else {
            dislikedIDs.insert(id)
            likedIDs.removeAll { $0 == id }
            remember(id)
        }
        scheduleSave()
    }

    func recordPlay(_ id: String) {
        guard known[id] != nil else { return }
        plays[id, default: 0] += 1
        lastPlayed[id] = Date()
        remember(id)
        scheduleSave()
    }

    func recordSkip(_ id: String) {
        guard known[id] != nil else { return }
        skips[id, default: 0] += 1
        scheduleSave()
    }

    func addSearch(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        recentSearches.removeAll { $0.lowercased() == t.lowercased() }
        recentSearches.insert(t, at: 0)
        if recentSearches.count > 10 { recentSearches = Array(recentSearches.prefix(10)) }
        scheduleSave()
    }

    func clearSearches() {
        recentSearches = []
        scheduleSave()
    }

    // MARK: Открытия для «Моей волны»

    var discoveryIsFresh: Bool {
        !discoveryIDs.isEmpty && Date().timeIntervalSince(discoveryDate) < 3 * 3600
    }

    /// Загружает свежие треки: общий тренд + жанры, которые ты лайкал
    func loadDiscovery() async {
        let liked: [OnlineTrack] = await MainActor.run { self.likedIDs.compactMap { self.known[$0] } }
        var genreCount: [String: Int] = [:]
        for t in liked {
            let g = t.genre.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if !g.isEmpty { genreCount[g, default: 0] += 1 }
        }
        let topGenres = genreCount.sorted { $0.value > $1.value }.prefix(2).map(\.key)

        var collected = await AudiusAPI.trending(genre: nil, time: "week", limit: 40)
        for g in topGenres {
            let more = await AudiusAPI.trending(genre: g, time: "month", limit: 30)
            collected.append(contentsOf: more)
        }
        let final = collected
        guard !final.isEmpty else { return }
        await MainActor.run {
            self.register(final)
            var seen = Set<String>()
            self.discoveryIDs = final.map(\.id).filter { seen.insert($0).inserted }
            self.discoveryDate = Date()
        }
    }

    // MARK: Файлы

    func download(_ id: String) async -> URL? {
        guard let a = AudiusAPI.audiusID(from: id) else { return nil }
        return await AudioDownloader.shared.file(audiusID: a)
    }

    func dropCachedFile(_ id: String) {
        guard let a = AudiusAPI.audiusID(from: id) else { return }
        AudioDownloader.remove(audiusID: a)
    }

    /// Скачивает обложку, чтобы её было видно на экране блокировки и в цвете фона
    func ensureArtwork(_ id: String) async {
        if ArtworkCache.shared.image(for: id) != nil { return }
        let urlString: String? = await MainActor.run {
            guard let o = self.known[id] else { return nil }
            return o.artworkLarge.isEmpty ? o.artworkSmall : o.artworkLarge
        }
        guard let s = urlString, let url = URL(string: s) else { return }
        guard let result = try? await URLSession.shared.data(from: url),
              let http = result.1 as? HTTPURLResponse, http.statusCode == 200 else { return }
        if Library.saveArtwork(result.0, id: id) {
            ArtworkCache.shared.invalidate(id)
        }
    }

    // MARK: Сохранение

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        for t in snap.tracks { known[t.id] = t }
        persisted = snap.tracks.map(\.id)
        likedIDs = snap.liked
        dislikedIDs = Set(snap.disliked)
        plays = snap.plays
        skips = snap.skips
        lastPlayed = snap.lastPlayed
        recentSearches = snap.searches
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            guard let strong = self else { return }
            await MainActor.run { strong.saveNow() }
        }
    }

    func saveNow() {
        let ids = Set(persisted).union(likedIDs).union(dislikedIDs)
        let tracks = ids.compactMap { known[$0] }
        let snap = Snapshot(tracks: tracks, liked: likedIDs, disliked: Array(dislikedIDs),
                            plays: plays, skips: skips, lastPlayed: lastPlayed, searches: recentSearches)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        let url = Self.fileURL
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }
}
