import SwiftUI

enum AccentTheme: String, CaseIterable, Identifiable {
    case echo, yandex, spotify, vk, sunset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .echo: return "Эхо (фиолетовый)"
        case .yandex: return "Как в Яндексе (жёлтый)"
        case .spotify: return "Как в Spotify (зелёный)"
        case .vk: return "Как в VK (синий)"
        case .sunset: return "Закат (оранжевый)"
        }
    }

    var color: Color {
        switch self {
        case .echo: return Color(red: 0.69, green: 0.40, blue: 1.0)
        case .yandex: return Color(red: 1.0, green: 0.80, blue: 0.0)
        case .spotify: return Color(red: 0.11, green: 0.73, blue: 0.33)
        case .vk: return Color(red: 0.0, green: 0.47, blue: 1.0)
        case .sunset: return Color(red: 1.0, green: 0.45, blue: 0.25)
        }
    }

    /// Цвет текста/иконок поверх акцентного фона
    var onAccent: Color {
        switch self {
        case .yandex, .spotify, .sunset: return .black
        default: return .white
        }
    }
}

struct EQPreset: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let gains: [Float]

    static let all: [EQPreset] = [
        EQPreset(name: "Ровно", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Бас", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Супербас", gains: [9, 7, 5, 2, 0, -1, -1, 0, 0, 0]),
        EQPreset(name: "Вокал", gains: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]),
        EQPreset(name: "Поп", gains: [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2]),
        EQPreset(name: "Рок", gains: [5, 4, 2, 0, -1, -1, 1, 3, 4, 5]),
        EQPreset(name: "Хип-хоп", gains: [6, 5, 2, 3, -1, -1, 1, 0, 2, 3]),
        EQPreset(name: "Электроника", gains: [5, 4, 1, 0, -2, 1, 0, 2, 4, 5]),
        EQPreset(name: "Акустика", gains: [3, 3, 2, 1, 2, 2, 3, 3, 2, 1]),
        EQPreset(name: "Высокие", gains: [0, 0, 0, 0, 0, 1, 3, 5, 6, 7]),
        EQPreset(name: "Ночь", gains: [-3, -2, -1, 0, 1, 2, 2, 1, -1, -3])
    ]
}

/// Настройки приложения (сохраняются в UserDefaults)
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var crossfade: Double { didSet { d.set(crossfade, forKey: "crossfade") } }
    @Published var eqEnabled: Bool { didSet { d.set(eqEnabled, forKey: "eqEnabled") } }
    @Published var eqGains: [Float] { didSet { d.set(eqGains.map { Double($0) }, forKey: "eqGains") } }
    @Published var eqPresetName: String { didSet { d.set(eqPresetName, forKey: "eqPreset") } }
    @Published var waveMood: WaveMood { didSet { d.set(waveMood.rawValue, forKey: "waveMood") } }
    @Published var accent: AccentTheme { didSet { d.set(accent.rawValue, forKey: "accent") } }
    @Published var radioCountry: String { didSet { d.set(radioCountry, forKey: "radioCountry") } }
    /// Подмешивать в «Мою волну» свежие треки из Audius
    @Published var waveOnline: Bool { didSet { d.set(waveOnline, forKey: "waveOnline") } }

    init() {
        let d = UserDefaults.standard
        crossfade = d.object(forKey: "crossfade") as? Double ?? 4
        eqEnabled = d.object(forKey: "eqEnabled") as? Bool ?? false
        if let arr = d.array(forKey: "eqGains") as? [Double], arr.count == 10 {
            eqGains = arr.map { Float($0) }
        } else {
            eqGains = Array(repeating: 0, count: 10)
        }
        eqPresetName = d.string(forKey: "eqPreset") ?? "Ровно"
        waveMood = WaveMood(rawValue: d.string(forKey: "waveMood") ?? "") ?? .mix
        accent = AccentTheme(rawValue: d.string(forKey: "accent") ?? "") ?? .echo
        radioCountry = d.string(forKey: "radioCountry") ?? "RU"
        waveOnline = d.object(forKey: "waveOnline") as? Bool ?? true
    }

    func apply(_ preset: EQPreset) {
        eqGains = preset.gains
        eqPresetName = preset.name
        if !eqEnabled { eqEnabled = true }
    }
}
