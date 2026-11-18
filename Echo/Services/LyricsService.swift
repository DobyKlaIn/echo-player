import Foundation

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double
    let text: String
}

struct LyricsResult: Codable {
    var synced: String?
    var plain: String?
    var instrumental: Bool = false

    var isEmpty: Bool {
        (synced ?? "").isEmpty && (plain ?? "").isEmpty && !instrumental
    }
}

/// Тексты песен: сначала .lrc рядом с файлом, потом кэш, потом бесплатная база LRCLIB
enum LyricsService {
    private struct LrclibItem: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private static let userAgent = "EchoPlayer/1.0 (personal iOS music player)"

    static func cacheURL(_ id: String) -> URL {
        Library.lyricsDir.appendingPathComponent("\(id).json")
    }

    static func load(track: Track, fileURL: URL, forceRefresh: Bool = false) async -> LyricsResult? {
        // 1. Файл .lrc рядом с треком
        let lrcURL = fileURL.deletingPathExtension().appendingPathExtension("lrc")
        if let s = try? String(contentsOf: lrcURL, encoding: .utf8), !s.isEmpty {
            return LyricsResult(synced: s, plain: nil)
        }
        // 2. Кэш
        if !forceRefresh, let data = try? Data(contentsOf: cacheURL(track.id)),
           let cached = try? JSONDecoder().decode(LyricsResult.self, from: data) {
            return cached.isEmpty ? nil : cached
        }
        // 3. LRCLIB
        let result = await fetchRemote(track: track)
        let toCache = result ?? LyricsResult()
        if let data = try? JSONEncoder().encode(toCache) {
            try? data.write(to: cacheURL(track.id), options: .atomic)
        }
        return result
    }

    private static func fetchRemote(track: Track) async -> LyricsResult? {
        let title = track.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }

        if !track.artist.isEmpty {
            var comps = URLComponents(string: "https://lrclib.net/api/get")
            var items = [URLQueryItem(name: "track_name", value: title),
                         URLQueryItem(name: "artist_name", value: track.artist)]
            if !track.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: track.album)) }
            if track.duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))) }
            comps?.queryItems = items
            if let url = comps?.url, let item: LrclibItem = await request(url), let r = convert(item) {
                return r
            }
        }

        // запасной вариант — поиск
        var comps = URLComponents(string: "https://lrclib.net/api/search")
        if track.artist.isEmpty {
            comps?.queryItems = [URLQueryItem(name: "q", value: title)]
        } else {
            comps?.queryItems = [URLQueryItem(name: "track_name", value: title),
                                 URLQueryItem(name: "artist_name", value: track.artist)]
        }
        guard let url = comps?.url, let list: [LrclibItem] = await request(url), !list.isEmpty else { return nil }

        // предпочитаем синхронизированный текст с близкой длительностью
        let sorted = list.sorted { a, b in
            let da = abs((a.duration ?? 0) - track.duration)
            let db = abs((b.duration ?? 0) - track.duration)
            let sa = (a.syncedLyrics ?? "").isEmpty ? 1 : 0
            let sb = (b.syncedLyrics ?? "").isEmpty ? 1 : 0
            if sa != sb { return sa < sb }
            return da < db
        }
        for item in sorted {
            if let r = convert(item) { return r }
        }
        return nil
    }

    private static func convert(_ item: LrclibItem) -> LyricsResult? {
        let r = LyricsResult(synced: item.syncedLyrics, plain: item.plainLyrics, instrumental: item.instrumental ?? false)
        return r.isEmpty ? nil : r
    }

    private static func request<T: Decodable>(_ url: URL) async -> T? {
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    /// Разбор формата LRC: [01:23.45]строка
    static func parse(_ lrc: String) -> [LyricLine] {
        guard let re = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#) else { return [] }
        var pairs: [(Double, String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = re.matches(in: raw, range: range)
            guard !matches.isEmpty else { continue }
            let text = re.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var fraction = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    fraction = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                pairs.append((minutes * 60 + seconds + fraction, text))
            }
        }
        return pairs.sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}
