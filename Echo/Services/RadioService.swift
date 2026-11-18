import Foundation

/// Интернет-радио из открытого каталога radio-browser.info (бесплатно, без ключей)
enum RadioService {
    private static let servers = [
        "https://de1.api.radio-browser.info",
        "https://de2.api.radio-browser.info",
        "https://fi1.api.radio-browser.info",
        "https://nl1.api.radio-browser.info",
        "https://all.api.radio-browser.info"
    ]
    private static let userAgent = "EchoPlayer/1.0"

    private struct RBStation: Decodable {
        let stationuuid: String
        let name: String?
        let url: String?
        let url_resolved: String?
        let favicon: String?
        let tags: String?
        let country: String?
        let bitrate: Int?
        let codec: String?
        let lastcheckok: Int?
    }

    static func top(countryCode: String) async -> [RadioStation] {
        await search(params: [
            "countrycode": countryCode,
            "order": "clickcount",
            "reverse": "true",
            "hidebroken": "true",
            "limit": "80"
        ])
    }

    static func search(name: String) async -> [RadioStation] {
        await search(params: [
            "name": name,
            "order": "clickcount",
            "reverse": "true",
            "hidebroken": "true",
            "limit": "80"
        ])
    }

    static func byTag(_ tag: String, countryCode: String?) async -> [RadioStation] {
        var p = [
            "tag": tag,
            "order": "clickcount",
            "reverse": "true",
            "hidebroken": "true",
            "limit": "80"
        ]
        if let c = countryCode { p["countrycode"] = c }
        let list = await search(params: p)
        if list.count < 5, countryCode != nil {
            // мало станций в стране — ищем по всему миру
            p.removeValue(forKey: "countrycode")
            return await search(params: p)
        }
        return list
    }

    private static func search(params: [String: String]) async -> [RadioStation] {
        for server in servers.shuffled() {
            var comps = URLComponents(string: server + "/json/stations/search")
            comps?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = comps?.url else { continue }
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                let raw = try JSONDecoder().decode([RBStation].self, from: data)
                return convert(raw)
            } catch {
                continue
            }
        }
        return []
    }

    private static func convert(_ raw: [RBStation]) -> [RadioStation] {
        var seen = Set<String>()
        var result: [RadioStation] = []
        for s in raw {
            let stream = (s.url_resolved?.isEmpty == false ? s.url_resolved : s.url) ?? ""
            let name = (s.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stream.isEmpty, !name.isEmpty else { continue }
            let key = name.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(RadioStation(id: s.stationuuid, name: name, url: stream,
                                       favicon: s.favicon ?? "", tags: s.tags ?? "",
                                       country: s.country ?? "", bitrate: s.bitrate ?? 0,
                                       codec: s.codec ?? ""))
        }
        return result
    }

    /// Каталог просит отмечать прослушивания — так популярные станции поднимаются выше
    static func registerClick(_ id: String) {
        guard let server = servers.first, let url = URL(string: "\(server)/json/url/\(id)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req).resume()
    }
}

/// Избранные и недавние станции
final class RadioStore: ObservableObject {
    @Published private(set) var favorites: [RadioStation] = []
    @Published private(set) var recent: [RadioStation] = []

    private let favKey = "radio.favorites"
    private let recentKey = "radio.recent"

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: favKey), let list = try? JSONDecoder().decode([RadioStation].self, from: data) {
            favorites = list
        }
        if let data = d.data(forKey: recentKey), let list = try? JSONDecoder().decode([RadioStation].self, from: data) {
            recent = list
        }
    }

    func isFavorite(_ s: RadioStation) -> Bool {
        favorites.contains { $0.id == s.id }
    }

    func toggleFavorite(_ s: RadioStation) {
        if isFavorite(s) {
            favorites.removeAll { $0.id == s.id }
        } else {
            favorites.insert(s, at: 0)
        }
        save()
    }

    func markPlayed(_ s: RadioStation) {
        recent.removeAll { $0.id == s.id }
        recent.insert(s, at: 0)
        if recent.count > 12 { recent = Array(recent.prefix(12)) }
        save()
    }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(favorites) { d.set(data, forKey: favKey) }
        if let data = try? JSONEncoder().encode(recent) { d.set(data, forKey: recentKey) }
    }
}
