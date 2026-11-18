import Foundation
import AVFoundation
import ImageIO
import UIKit

struct AlbumGroup: Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var trackIDs: [String]
}

struct ArtistGroup: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var trackIDs: [String]
}

/// Медиатека: файлы, метаданные, лайки, плейлисты, история.
/// Все изменения состояния — только на главном потоке.
final class Library: ObservableObject {
    @Published private(set) var tracks: [Track] = [] { didSet { rebuildIndex() } }
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanStatus: String = ""
    @Published var toast: String? = nil

    private var indexByID: [String: Int] = [:]
    private var saveTask: Task<Void, Never>?
    private var scanInProgress = false

    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf", "alac", "m4b"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]

    // MARK: Папки

    static let documentsDir: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    static let musicDir: URL = {
        let dir = documentsDir.appendingPathComponent("Музыка", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Echo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let artworkDir: URL = {
        let dir = supportDir.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let lyricsDir: URL = {
        let dir = supportDir.appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var dbURL: URL { supportDir.appendingPathComponent("library.json") }

    // MARK: Инициализация и сохранение

    private struct Snapshot: Codable {
        var tracks: [Track]
        var playlists: [Playlist]
        var history: [HistoryEntry]
    }

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.dbURL) else { return }
        let decoder = JSONDecoder()
        guard let snap = try? decoder.decode(Snapshot.self, from: data) else { return }
        tracks = snap.tracks
        playlists = snap.playlists
        history = snap.history
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }
            guard let strong = self else { return }
            await MainActor.run { strong.saveNow() }
        }
    }

    func saveNow() {
        let snap = Snapshot(tracks: tracks, playlists: playlists, history: history)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        let url = Self.dbURL
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func rebuildIndex() {
        var map: [String: Int] = [:]
        map.reserveCapacity(tracks.count)
        for (i, t) in tracks.enumerated() { map[t.id] = i }
        indexByID = map
    }

    // MARK: Доступ

    func track(_ id: String) -> Track? {
        guard let i = indexByID[id], tracks.indices.contains(i) else { return nil }
        return tracks[i]
    }

    func tracks(for ids: [String]) -> [Track] {
        ids.compactMap { track($0) }
    }

    func url(for track: Track) -> URL {
        Self.musicDir.appendingPathComponent(track.fileName)
    }

    func playlist(_ id: String) -> Playlist? {
        playlists.first { $0.id == id }
    }

    // MARK: Сканирование папки

    func rescan() async {
        let shouldRun: Bool = await MainActor.run {
            if self.scanInProgress { return false }
            self.scanInProgress = true
            self.isScanning = true
            self.scanStatus = "Ищу музыку…"
            return true
        }
        guard shouldRun else { return }

        Self.collectLooseFiles()
        let existing: [Track] = await MainActor.run { self.tracks }
        let files = Self.listAudioFiles()
        let fileSet = Set(files.map { $0.precomposedStringWithCanonicalMapping })

        var known = Set<String>()
        var kept: [Track] = []
        for t in existing {
            let key = t.fileName.precomposedStringWithCanonicalMapping
            if fileSet.contains(key), !known.contains(key) {
                kept.append(t)
                known.insert(key)
            }
        }

        let newFiles = files.filter { !known.contains($0.precomposedStringWithCanonicalMapping) }
        var added: [Track] = []
        for (i, rel) in newFiles.enumerated() {
            let t = await Self.makeTrack(relativePath: rel)
            added.append(t)
            if i % 10 == 0 {
                let status = "Добавляю треки: \(i + 1) из \(newFiles.count)"
                await MainActor.run { self.scanStatus = status }
            }
        }

        let keptFinal = kept
        let addedFinal = added
        let removedIDs = Set(existing.map(\.id)).subtracting(keptFinal.map(\.id))

        await MainActor.run {
            // Пока шло сканирование, пользователь мог лайкнуть трек — берём актуальные версии
            var current: [String: Track] = [:]
            for t in self.tracks { current[t.id] = t }
            var result = keptFinal.map { current[$0.id] ?? $0 }
            result.append(contentsOf: addedFinal)
            self.tracks = result
            if !removedIDs.isEmpty {
                self.playlists = self.playlists.map { p in
                    var p = p
                    p.trackIDs.removeAll { removedIDs.contains($0) }
                    return p
                }
            }
            self.isScanning = false
            self.scanInProgress = false
            self.scanStatus = ""
            if !addedFinal.isEmpty || !removedIDs.isEmpty { self.scheduleSave() }
            if !addedFinal.isEmpty { self.toast = "Добавлено треков: \(addedFinal.count)" }
        }
    }

    static func listAudioFiles() -> [String] {
        guard let subs = FileManager.default.subpaths(atPath: musicDir.path) else { return [] }
        return subs.filter { p in
            let name = (p as NSString).lastPathComponent
            let ext = (p as NSString).pathExtension.lowercased()
            return !name.hasPrefix(".") && audioExtensions.contains(ext)
        }.sorted()
    }

    /// Файлы, закинутые через приложение «Файлы» прямо в корень, и пришедшие через «Открыть в…»
    static func collectLooseFiles() {
        let fm = FileManager.default
        let inbox = documentsDir.appendingPathComponent("Inbox", isDirectory: true)
        for dir in [documentsDir, inbox] {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                let name = item.lastPathComponent
                if dir == documentsDir && (name == "Музыка" || name == "Inbox") { continue }
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: item.path, isDirectory: &isDir)
                if isDir.boolValue {
                    let subs = fm.subpaths(atPath: item.path) ?? []
                    let hasAudio = subs.contains { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                    if hasAudio { try? fm.moveItem(at: item, to: uniqueDestination(for: name)) }
                } else if audioExtensions.contains(item.pathExtension.lowercased()) {
                    try? fm.moveItem(at: item, to: uniqueDestination(for: name))
                }
            }
        }
    }

    static func uniqueDestination(for name: String, in dir: URL = musicDir) -> URL {
        let fm = FileManager.default
        var dest = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            dest = dir.appendingPathComponent(newName)
            n += 1
        }
        return dest
    }

    // MARK: Импорт

    func importFiles(_ urls: [URL]) async {
        var count = 0
        for url in urls { count += Self.copyIn(url) }
        await rescan()
        if count == 0 {
            await MainActor.run { self.toast = "Не нашёл аудиофайлов (mp3, m4a, flac, wav)" }
        }
    }

    /// Копирует файл или папку в «Музыку». Возвращает число аудиофайлов.
    static func copyIn(_ src: URL) -> Int {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { return 0 }

        if isDir.boolValue {
            guard let subs = fm.subpaths(atPath: src.path) else { return 0 }
            let audio = subs.filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            guard !audio.isEmpty else { return 0 }
            let folder = uniqueDestination(for: src.lastPathComponent)
            var n = 0
            for sub in subs {
                let ext = (sub as NSString).pathExtension.lowercased()
                guard audioExtensions.contains(ext) || imageExtensions.contains(ext) else { continue }
                let dest = folder.appendingPathComponent(sub)
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fm.copyItem(at: src.appendingPathComponent(sub), to: dest)) != nil, audioExtensions.contains(ext) {
                    n += 1
                }
            }
            return n
        }

        guard audioExtensions.contains(src.pathExtension.lowercased()) else { return 0 }
        let srcPath = src.resolvingSymlinksInPath().path
        let musicPath = musicDir.resolvingSymlinksInPath().path
        if srcPath.hasPrefix(musicPath) { return 1 }
        let dest = uniqueDestination(for: src.lastPathComponent)
        do {
            if srcPath.contains("/Documents/Inbox/") {
                try fm.moveItem(at: src, to: dest)
            } else {
                try fm.copyItem(at: src, to: dest)
            }
            return 1
        } catch {
            return 0
        }
    }

    // MARK: Метаданные

    struct RawMetadata {
        var title: String?
        var artist: String?
        var album: String?
        var genre: String?
        var duration: Double = 0
        var artwork: Data?
    }

    static func readMetadata(url: URL) async -> RawMetadata {
        var meta = RawMetadata()
        let asset = AVURLAsset(url: url)
        do {
            let (common, all, dur) = try await asset.load(.commonMetadata, .metadata, .duration)
            let seconds = dur.seconds
            meta.duration = seconds.isFinite ? seconds : 0
            for item in common {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle: meta.title = try? await item.load(.stringValue)
                case .commonKeyArtist: meta.artist = try? await item.load(.stringValue)
                case .commonKeyAlbumName: meta.album = try? await item.load(.stringValue)
                case .commonKeyArtwork: meta.artwork = try? await item.load(.dataValue)
                default: break
                }
            }
            let genreIDs: Set<AVMetadataIdentifier> = [.id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre]
            for item in all {
                if let ident = item.identifier, genreIDs.contains(ident) {
                    meta.genre = try? await item.load(.stringValue)
                    break
                }
            }
        } catch {
            // файл без метаданных — возьмём имя файла
        }
        if meta.duration <= 0, let file = try? AVAudioFile(forReading: url) {
            let sr = file.processingFormat.sampleRate
            if sr > 0 { meta.duration = Double(file.length) / sr }
        }
        return meta
    }

    static func makeTrack(relativePath rel: String) async -> Track {
        let url = musicDir.appendingPathComponent(rel)
        let id = UUID().uuidString
        let meta = await readMetadata(url: url)

        let fileBase = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
        var title = (meta.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var artist = (meta.artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            let cleaned = stripTrackNumber(fileBase)
            let parts = cleaned.components(separatedBy: " - ")
            if parts.count >= 2 {
                if artist.isEmpty { artist = parts[0].trimmingCharacters(in: .whitespaces) }
                title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            } else {
                title = cleaned
            }
        }

        var hasArt = false
        if let data = meta.artwork, saveArtwork(data, id: id) {
            hasArt = true
        } else if let cover = folderCover(for: url), let data = try? Data(contentsOf: cover), saveArtwork(data, id: id) {
            hasArt = true
        }

        return Track(
            id: id,
            fileName: rel,
            title: fixCyrillic(title),
            artist: fixCyrillic(artist),
            album: fixCyrillic((meta.album ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
            genre: fixCyrillic(meta.genre ?? ""),
            duration: meta.duration,
            hasArtwork: hasArt,
            addedAt: Date()
        )
    }

    static func stripTrackNumber(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"^\s*\d{1,3}\s*[.\-_)]\s*"#) else { return s }
        let ns = s as NSString
        let result = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return result.isEmpty ? s : result
    }

    static func folderCover(for fileURL: URL) -> URL? {
        let dir = fileURL.deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let preferred = ["cover", "folder", "front", "album", "artwork"]
        for name in preferred {
            if let match = items.first(where: { item in
                let base = (item as NSString).deletingPathExtension.lowercased()
                let ext = (item as NSString).pathExtension.lowercased()
                return base == name && imageExtensions.contains(ext)
            }) {
                return dir.appendingPathComponent(match)
            }
        }
        return nil
    }

    @discardableResult
    static func saveArtwork(_ data: Data, id: String) -> Bool {
        guard let big = downscaleJPEG(data, maxPixel: 900),
              let small = downscaleJPEG(data, maxPixel: 180) else { return false }
        do {
            try big.write(to: artworkDir.appendingPathComponent("\(id).jpg"), options: .atomic)
            try small.write(to: artworkDir.appendingPathComponent("\(id)_s.jpg"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func downscaleJPEG(_ data: Data, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    }

    // MARK: Изменения треков

    private func mutate(_ id: String, _ change: (inout Track) -> Void) {
        guard let i = indexByID[id], tracks.indices.contains(i) else { return }
        change(&tracks[i])
        scheduleSave()
    }

    func toggleLike(_ id: String) {
        mutate(id) { t in
            t.liked.toggle()
            if t.liked { t.disliked = false }
        }
    }

    func toggleDislike(_ id: String) {
        mutate(id) { t in
            t.disliked.toggle()
            if t.disliked { t.liked = false }
        }
    }

    func recordPlay(_ id: String) {
        mutate(id) { t in
            t.playCount += 1
            t.lastPlayedAt = Date()
        }
        history.append(HistoryEntry(trackID: id, date: Date()))
        if history.count > 600 { history.removeFirst(history.count - 600) }
    }

    func recordSkip(_ id: String) {
        mutate(id) { $0.skipCount += 1 }
    }

    func addListening(_ id: String, seconds: Double) {
        guard seconds > 0 else { return }
        mutate(id) { $0.secondsListened += seconds }
    }

    func updateArtwork(_ id: String, data: Data) {
        guard Self.saveArtwork(data, id: id) else { return }
        ArtworkCache.shared.invalidate(id)
        mutate(id) { $0.hasArtwork = true }
    }

    func editInfo(_ id: String, title: String, artist: String, album: String) {
        mutate(id) { t in
            t.title = title
            t.artist = artist
            t.album = album
        }
    }

    func deleteTrack(_ id: String) {
        guard let t = track(id) else { return }
        try? FileManager.default.removeItem(at: url(for: t))
        try? FileManager.default.removeItem(at: Self.artworkDir.appendingPathComponent("\(id).jpg"))
        try? FileManager.default.removeItem(at: Self.artworkDir.appendingPathComponent("\(id)_s.jpg"))
        tracks.removeAll { $0.id == id }
        playlists = playlists.map { p in
            var p = p
            p.trackIDs.removeAll { $0 == id }
            return p
        }
        scheduleSave()
    }

    // MARK: Плейлисты

    @discardableResult
    func createPlaylist(name: String, trackIDs: [String] = []) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = Playlist(name: trimmed.isEmpty ? "Новый плейлист" : trimmed, trackIDs: trackIDs)
        playlists.insert(p, at: 0)
        scheduleSave()
        return p
    }

    func renamePlaylist(_ id: String, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists[i].name = trimmed
        scheduleSave()
    }

    func deletePlaylist(_ id: String) {
        playlists.removeAll { $0.id == id }
        scheduleSave()
    }

    func add(_ trackID: String, to playlistID: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if !playlists[i].trackIDs.contains(trackID) {
            playlists[i].trackIDs.append(trackID)
            scheduleSave()
            toast = "Добавлено в «\(playlists[i].name)»"
        } else {
            toast = "Уже есть в «\(playlists[i].name)»"
        }
    }

    func removeFromPlaylist(_ playlistID: String, offsets: IndexSet) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for o in offsets.sorted(by: >) where playlists[i].trackIDs.indices.contains(o) {
            playlists[i].trackIDs.remove(at: o)
        }
        scheduleSave()
    }

    func movePlaylistTracks(_ playlistID: String, from: IndexSet, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.moveItems(fromOffsets: from, toOffset: to)
        scheduleSave()
    }

    // MARK: Подборки

    var likedTracks: [Track] {
        tracks.filter { $0.liked }.sorted { $0.addedAt > $1.addedAt }
    }

    var recentlyAdded: [Track] {
        Array(tracks.sorted { $0.addedAt > $1.addedAt }.prefix(100))
    }

    var mostPlayed: [Track] {
        Array(tracks.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(100))
    }

    /// Давно не слушал: слушал раньше, но не последние 3 недели
    var forgotten: [Track] {
        let border = Date().addingTimeInterval(-21 * 86400)
        return tracks.filter { t in
            guard let last = t.lastPlayedAt else { return false }
            return last < border && !t.disliked
        }.sorted { $0.playCount > $1.playCount }
    }

    var recentlyPlayed: [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        for entry in history.reversed() {
            if seen.contains(entry.trackID) { continue }
            seen.insert(entry.trackID)
            if let t = track(entry.trackID) { result.append(t) }
            if result.count >= 20 { break }
        }
        return result
    }

    var albums: [AlbumGroup] {
        var order: [String] = []
        var groups: [String: AlbumGroup] = [:]
        for t in tracks where !t.album.isEmpty {
            let key = t.albumKey
            if groups[key] == nil {
                groups[key] = AlbumGroup(id: key, title: t.album, artist: t.displayArtist, trackIDs: [])
                order.append(key)
            }
            groups[key]?.trackIDs.append(t.id)
        }
        return order.compactMap { groups[$0] }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var artists: [ArtistGroup] {
        var groups: [String: [String]] = [:]
        var names: [String: String] = [:]
        for t in tracks {
            let key = t.displayArtist.lowercased()
            groups[key, default: []].append(t.id)
            if names[key] == nil { names[key] = t.displayArtist }
        }
        return groups.map { ArtistGroup(name: names[$0.key] ?? $0.key, trackIDs: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Статистика

    var totalListeningSeconds: Double {
        tracks.reduce(0) { $0 + $1.secondsListened }
    }

    var libraryDuration: Double {
        tracks.reduce(0) { $0 + $1.duration }
    }

    func topArtists(limit: Int) -> [(name: String, plays: Int)] {
        var counts: [String: Int] = [:]
        for t in tracks where t.playCount > 0 {
            counts[t.displayArtist, default: 0] += t.playCount
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map { (name: $0.key, plays: $0.value) }
    }

    func listening(since date: Date) -> Int {
        history.filter { $0.date >= date }.count
    }

    func storageBytes() -> Int64 {
        let fm = FileManager.default
        guard let subs = fm.subpaths(atPath: Self.musicDir.path) else { return 0 }
        var total: Int64 = 0
        for sub in subs {
            let path = Self.musicDir.appendingPathComponent(sub).path
            if let attrs = try? fm.attributesOfItem(atPath: path), let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }
}

extension Array {
    mutating func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        let items = source.sorted().compactMap { indices.contains($0) ? self[$0] : nil }
        var dest = destination
        for i in source.sorted(by: >) where indices.contains(i) {
            remove(at: i)
            if i < dest { dest -= 1 }
        }
        dest = Swift.max(0, Swift.min(dest, count))
        insert(contentsOf: items, at: dest)
    }
}
