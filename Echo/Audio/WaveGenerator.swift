import Foundation

/// «Моя волна»: бесконечный поток из медиатеки, который подстраивается под лайки,
/// дизлайки, пропуски и выбранный характер.
enum WaveGenerator {
    static func next(count: Int, from tracks: [Track], mood: WaveMood, recent: [String]) -> [String] {
        var pool = tracks.filter { !$0.disliked && $0.duration > 20 || (!$0.disliked && $0.duration == 0) }
        if pool.isEmpty { pool = tracks.filter { !$0.disliked } }
        guard !pool.isEmpty else { return [] }

        let recentSet = Set(recent.suffix(40))
        let lastArtist = recent.last.flatMap { id in tracks.first(where: { $0.id == id })?.artist } ?? ""
        let now = Date()
        let maxPlays = Double(pool.map(\.playCount).max() ?? 0)

        var weighted: [(id: String, artist: String, weight: Double)] = pool.map { t in
            var w = 1.0
            let plays = Double(t.playCount)
            if t.liked { w *= 2.5 }

            switch mood {
            case .mix:
                w *= 1 + log(1 + plays) * 0.25
            case .favorite:
                w *= t.liked ? 6 : 0.12
            case .unfamiliar:
                w *= 1 / pow(1 + plays, 1.4)
                if t.liked { w *= 0.4 }
            case .popular:
                w *= maxPlays > 0 ? 0.05 + pow(plays / maxPlays, 1.2) * 10 : 1
            case .fresh:
                let days = now.timeIntervalSince(t.addedAt) / 86400
                w *= 8 / (1 + days / 2)
            }

            // часто пропускаешь — реже попадается
            let skipPenalty = max(0, Double(t.skipCount) - plays * 0.5)
            w *= pow(0.75, min(skipPenalty, 12))

            // недавно звучал — пусть отдохнёт
            if let last = t.lastPlayedAt {
                let hours = now.timeIntervalSince(last) / 3600
                if hours < 1 { w *= 0.05 } else if hours < 6 { w *= 0.4 }
            }
            if recentSet.contains(t.id) { w *= 0.01 }
            return (id: t.id, artist: t.artist.lowercased(), weight: max(w, 0.00001))
        }

        var result: [String] = []
        var prevArtist = lastArtist.lowercased()
        for _ in 0..<count {
            guard !weighted.isEmpty else { break }
            // не ставим подряд одного и того же исполнителя
            let adjusted = weighted.map { item -> Double in
                (!prevArtist.isEmpty && item.artist == prevArtist && weighted.count > 1) ? item.weight * 0.15 : item.weight
            }
            let total = adjusted.reduce(0, +)
            var r = Double.random(in: 0..<max(total, 0.000001))
            var pick = weighted.count - 1
            for (i, w) in adjusted.enumerated() {
                r -= w
                if r <= 0 { pick = i; break }
            }
            let chosen = weighted.remove(at: pick)
            result.append(chosen.id)
            prevArtist = chosen.artist
        }
        return result
    }
}
