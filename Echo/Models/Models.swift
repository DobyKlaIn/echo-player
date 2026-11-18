import Foundation

// MARK: - Трек

struct Track: Identifiable, Hashable {
    var id: String
    /// Путь относительно папки «Музыка» (абсолютный путь контейнера меняется между установками)
    var fileName: String
    var title: String
    var artist: String
    var album: String
    var genre: String
    var duration: Double
    var hasArtwork: Bool
    var addedAt: Date
    var playCount: Int = 0
    var skipCount: Int = 0
    var lastPlayedAt: Date? = nil
    var liked: Bool = false
    var disliked: Bool = false
    var secondsListened: Double = 0

    var displayArtist: String { artist.isEmpty ? "Неизвестный исполнитель" : artist }
    var displayAlbum: String { album.isEmpty ? "Без альбома" : album }
    var albumKey: String { "\(displayArtist.lowercased())|\(displayAlbum.lowercased())" }
    /// Онлайн-трек из Audius (не хранится в медиатеке)
    var isOnline: Bool { id.hasPrefix("audius-") }
}

extension Track: Codable {
    enum CodingKeys: String, CodingKey {
        case id, fileName, title, artist, album, genre, duration, hasArtwork, addedAt
        case playCount, skipCount, lastPlayedAt, liked, disliked, secondsListened
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? ""
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        hasArtwork = try c.decodeIfPresent(Bool.self, forKey: .hasArtwork) ?? false
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        skipCount = try c.decodeIfPresent(Int.self, forKey: .skipCount) ?? 0
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        liked = try c.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        disliked = try c.decodeIfPresent(Bool.self, forKey: .disliked) ?? false
        secondsListened = try c.decodeIfPresent(Double.self, forKey: .secondsListened) ?? 0
    }
}

// MARK: - Плейлист

struct Playlist: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var trackIDs: [String] = []
    var createdAt: Date = Date()
}

// MARK: - История

struct HistoryEntry: Codable, Hashable {
    var trackID: String
    var date: Date
}

// MARK: - Радиостанция

struct RadioStation: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var url: String
    var favicon: String
    var tags: String
    var country: String
    var bitrate: Int
    var codec: String

    var subtitle: String {
        var parts: [String] = []
        let firstTags = tags.split(separator: ",").prefix(3).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !firstTags.isEmpty { parts.append(firstTags.joined(separator: ", ")) }
        if bitrate > 0 { parts.append("\(bitrate) kbps") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Характер «Моей волны»

enum WaveMood: String, CaseIterable, Codable, Identifiable {
    case mix, favorite, unfamiliar, popular, fresh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mix: return "Микс"
        case .favorite: return "Любимое"
        case .unfamiliar: return "Незнакомое"
        case .popular: return "Популярное"
        case .fresh: return "Свежее"
        }
    }

    var icon: String {
        switch self {
        case .mix: return "sparkles"
        case .favorite: return "heart.fill"
        case .unfamiliar: return "questionmark.circle"
        case .popular: return "flame.fill"
        case .fresh: return "leaf.fill"
        }
    }

    var hint: String {
        switch self {
        case .mix: return "Всё вперемешку с учётом твоих вкусов"
        case .favorite: return "В основном треки с лайком"
        case .unfamiliar: return "То, что ты почти не слушал"
        case .popular: return "Твои самые заслушанные треки"
        case .fresh: return "Недавно добавленное"
        }
    }
}

enum RepeatMode: Int {
    case off, all, one

    var icon: String { self == .one ? "repeat.1" : "repeat" }
}

enum PlaybackSource: Equatable {
    case none, local, radio
}

// MARK: - Утилиты

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded(.down))
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// Стабильный хэш строки (hashValue в Swift меняется между запусками)
func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 1469598103934665603
    for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 1099511628211
    }
    return h
}

/// Чинит «кракозябры» в старых русских mp3: теги в cp1251, прочитанные как Latin-1 («Ïðèâåò» → «Привет»)
func fixCyrillic(_ s: String) -> String {
    let scalars = s.unicodeScalars
    guard !scalars.isEmpty, scalars.allSatisfy({ $0.value <= 0xFF }) else { return s }
    let high = scalars.filter { $0.value >= 0xC0 }.count
    guard high >= 2, Double(high) / Double(scalars.count) > 0.3 else { return s }
    guard let data = s.data(using: .isoLatin1),
          let fixed = String(data: data, encoding: .windowsCP1251) else { return s }
    return fixed
}
