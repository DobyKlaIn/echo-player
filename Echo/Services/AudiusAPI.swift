import Foundation

/// Трек из Audius в удобном для приложения виде
struct OnlineTrack: Codable, Hashable, Identifiable {
    /// id в приложении: "audius-<id в Audius>"
    var id: String
    var audiusID: String
    var title: String
    var artist: String
    var artistHandle: String
    var genre: String
    var mood: String
    var duration: Double
    var artworkSmall: String
    var artworkLarge: String
    var permalink: String
    var releaseDate: Date?
    var playCount: Int

    var webURL: URL? {
        permalink.isEmpty ? nil : URL(string: "https://audius.co" + permalink)
    }
}

struct OnlinePlaylist: Identifiable, Hashable {
    var id: String
    var name: String
    var owner: String
    var artwork: String
    var trackCount: Int
    var isAlbum: Bool
}

/// Бесплатный открытый API Audius (поиск, тренды, потоковое воспроизведение)
enum AudiusAPI {
    static let base = "https://api.audius.co/v1"
    static let appName = "EchoPlayer"
    static let idPrefix = "audius-"

    // MARK: Ответы API

    private struct Wrapper<T: Decodable>: Decodable {
        let data: T?
    }

    private struct ArtworkSizes: Decodable {
        let small: String?
        let medium: String?
        let large: String?

        enum CodingKeys: String, CodingKey {
            case small = "150x150"
            case medium = "480x480"
            case large = "1000x1000"
        }
    }

    private struct AUser: Decodable {
        let name: String?
        let handle: String?
    }

    private struct AAccess: Decodable {
        let stream: Bool?
    }

    private struct ATrack: Decodable {
        let id: String
        let title: String?
        let duration: Double?
        let genre: String?
        let mood: String?
        let release_date: String?
        let created_at: String?
        let play_count: Int?
        let is_streamable: Bool?
        let is_stream_gated: Bool?
        let is_delete: Bool?
        let permalink: String?
        let artwork: ArtworkSizes?
        let user: AUser?
        let access: AAccess?
    }

    private struct APlaylist: Decodable {
        let id: String
        let playlist_name: String?
        let artwork: ArtworkSizes?
        let user: AUser?
        let track_count: Int?
        let is_album: Bool?
        let is_private: Bool?
    }

    // MARK: Запросы

    static func trending(genre: String?, time: String = "week", limit: Int = 50) async -> [OnlineTrack] {
        var q = ["time": time, "limit": String(limit)]
        if let g = genre { q["genre"] = g }
        return await tracks(path: "/tracks/trending", query: q)
    }

    static func search(_ text: String, limit: Int = 50) async -> [OnlineTrack] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return await tracks(path: "/tracks/search", query: ["query": trimmed, "limit": String(limit)])
    }

    static func trendingPlaylists(time: String = "week", limit: Int = 20) async -> [OnlinePlaylist] {
        let list: [APlaylist] = await request(path: "/playlists/trending", query: ["time": time, "limit": String(limit)]) ?? []
        return list.compactMap { p in
            guard p.is_private != true, let name = p.playlist_name, !name.isEmpty else { return nil }
            return OnlinePlaylist(id: p.id, name: name, owner: p.user?.name ?? "",
                                  artwork: p.artwork?.medium ?? p.artwork?.small ?? "",
                                  trackCount: p.track_count ?? 0, isAlbum: p.is_album ?? false)
        }
    }

    static func playlistTracks(_ playlistID: String) async -> [OnlineTrack] {
        await tracks(path: "/playlists/\(playlistID)/tracks", query: [:])
    }

    static func streamURL(audiusID: String) -> URL? {
        var comps = URLComponents(string: "\(base)/tracks/\(audiusID)/stream")
        comps?.queryItems = [URLQueryItem(name: "app_name", value: appName)]
        return comps?.url
    }

    static func audiusID(from appID: String) -> String? {
        guard appID.hasPrefix(idPrefix) else { return nil }
        return String(appID.dropFirst(idPrefix.count))
    }

    // MARK: Внутреннее

    private static func tracks(path: String, query: [String: String]) async -> [OnlineTrack] {
        let raw: [ATrack] = await request(path: path, query: query) ?? []
        return convert(raw)
    }

    private static func request<T: Decodable>(path: String, query: [String: String]) async -> T? {
        var comps = URLComponents(string: base + path)
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "app_name", value: appName))
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    if attempt == 0 { continue }
                    return nil
                }
                return try JSONDecoder().decode(Wrapper<T>.self, from: data).data
            } catch {
                if attempt == 1 { return nil }
            }
        }
        return nil
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        // формат "2026-11-14 16:14:54"
        let f3 = DateFormatter()
        f3.locale = Locale(identifier: "en_US_POSIX")
        f3.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f3.date(from: String(s.prefix(19)))
    }

    private static func convert(_ raw: [ATrack]) -> [OnlineTrack] {
        var seen = Set<String>()
        var result: [OnlineTrack] = []
        for t in raw {
            // только то, что можно слушать бесплатно
            if t.is_delete == true || t.is_streamable == false || t.is_stream_gated == true || t.access?.stream == false {
                continue
            }
            if seen.contains(t.id) { continue }
            seen.insert(t.id)
            let title = (t.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            result.append(OnlineTrack(
                id: idPrefix + t.id,
                audiusID: t.id,
                title: title,
                artist: (t.user?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                artistHandle: t.user?.handle ?? "",
                genre: t.genre ?? "",
                mood: t.mood ?? "",
                duration: t.duration ?? 0,
                artworkSmall: t.artwork?.small ?? t.artwork?.medium ?? "",
                artworkLarge: t.artwork?.large ?? t.artwork?.medium ?? "",
                permalink: t.permalink ?? "",
                releaseDate: parseDate(t.release_date) ?? parseDate(t.created_at),
                playCount: t.play_count ?? 0
            ))
        }
        return result
    }
}

/// Жанры Audius с русскими названиями
struct OnlineGenre: Identifiable, Hashable {
    let title: String
    let apiName: String?
    var id: String { title }

    static let all: [OnlineGenre] = [
        OnlineGenre(title: "Всё", apiName: nil),
        OnlineGenre(title: "Электроника", apiName: "Electronic"),
        OnlineGenre(title: "Хип-хоп", apiName: "Hip-Hop/Rap"),
        OnlineGenre(title: "Поп", apiName: "Pop"),
        OnlineGenre(title: "Рок", apiName: "Rock"),
        OnlineGenre(title: "Фонк", apiName: "Phonk"),
        OnlineGenre(title: "Lo-Fi", apiName: "Lo-Fi"),
        OnlineGenre(title: "House", apiName: "House"),
        OnlineGenre(title: "Techno", apiName: "Techno"),
        OnlineGenre(title: "Трэп", apiName: "Trap"),
        OnlineGenre(title: "Drum & Bass", apiName: "Drum & Bass"),
        OnlineGenre(title: "Dubstep", apiName: "Dubstep"),
        OnlineGenre(title: "R&B", apiName: "R&B/Soul"),
        OnlineGenre(title: "Альтернатива", apiName: "Alternative"),
        OnlineGenre(title: "Метал", apiName: "Metal"),
        OnlineGenre(title: "Эмбиент", apiName: "Ambient"),
        OnlineGenre(title: "Джаз", apiName: "Jazz"),
        OnlineGenre(title: "Классика", apiName: "Classical"),
        OnlineGenre(title: "Латино", apiName: "Latin")
    ]
}
