import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: PlayerController
    @State private var storage: Int64 = 0
    @State private var showHelp = false

    private let countries: [(code: String, name: String)] = [
        ("RU", "Россия"), ("BY", "Беларусь"), ("KZ", "Казахстан"), ("UA", "Украина"),
        ("US", "США"), ("GB", "Великобритания"), ("DE", "Германия"), ("FR", "Франция")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { StatsView() } label: {
                        Label("Мои итоги", systemImage: "chart.bar.fill")
                    }
                }

                Section("Звук") {
                    NavigationLink { EqualizerView() } label: {
                        HStack {
                            Label("Эквалайзер", systemImage: "slider.vertical.3")
                            Spacer()
                            Text(settings.eqEnabled ? settings.eqPresetName : "выкл").foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Плавный переход", systemImage: "wave.3.right")
                            Spacer()
                            Text(settings.crossfade == 0 ? "выкл" : "\(Int(settings.crossfade)) с")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.crossfade, in: 0...12, step: 1)
                    }
                }

                Section("Моя волна") {
                    Picker(selection: $settings.waveMood) {
                        ForEach(WaveMood.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    } label: {
                        Label("Характер", systemImage: "waveform")
                    }
                    .onChange(of: settings.waveMood) { _ in player.waveMoodChanged() }
                    Text("Волна учится на тебе: лайк — чаще, дизлайк — никогда, пропуск в первые 30 секунд — реже.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Оформление") {
                    Picker(selection: $settings.accent) {
                        ForEach(AccentTheme.allCases) { a in
                            HStack {
                                Circle().fill(a.color).frame(width: 14, height: 14)
                                Text(a.title)
                            }
                            .tag(a)
                        }
                    } label: {
                        Label("Цвет", systemImage: "paintpalette.fill")
                    }
                    .pickerStyle(.navigationLink)
                }

                Section("Радио") {
                    Picker(selection: $settings.radioCountry) {
                        ForEach(countries, id: \.code) { c in
                            Text(c.name).tag(c.code)
                        }
                    } label: {
                        Label("Станции из страны", systemImage: "globe")
                    }
                }

                Section("Медиатека") {
                    HStack {
                        Label("Треков", systemImage: "music.note")
                        Spacer()
                        Text("\(library.tracks.count)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Занимает", systemImage: "internaldrive")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: storage, countStyle: .file)).foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await library.rescan() }
                    } label: {
                        Label("Обновить медиатеку", systemImage: "arrow.clockwise")
                    }
                    Button { showHelp = true } label: {
                        Label("Как добавить музыку", systemImage: "questionmark.circle")
                    }
                }

                Section {
                    HStack {
                        Text("Версия")
                        Spacer()
                        Text(appVersion).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("«Эхо» — твой личный плеер. Музыка хранится на телефоне и играет без интернета. Тексты песен — из бесплатной базы LRCLIB, радио — из открытого каталога radio-browser.info.")
                }
            }
            .navigationTitle("Ещё")
            .task {
                let bytes = await Task.detached { () -> Int64 in
                    Self.musicFolderSize()
                }.value
                storage = bytes
            }
            .sheet(isPresented: $showHelp) { ImportHelpView() }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    nonisolated private static func musicFolderSize() -> Int64 {
        let fm = FileManager.default
        let root = Library.musicDir
        guard let subs = fm.subpaths(atPath: root.path) else { return 0 }
        var total: Int64 = 0
        for sub in subs {
            if let attrs = try? fm.attributesOfItem(atPath: root.appendingPathComponent(sub).path),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }
}

// MARK: - Итоги (как Spotify Wrapped, только всегда под рукой)

struct StatsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let minutes = Int(library.totalListeningSeconds / 60)
        let topTracks = Array(library.mostPlayed.prefix(10))
        let topArtists = library.topArtists(limit: 5)
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let weekPlays = library.listening(since: weekAgo)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    statCard(value: "\(minutes)", label: "минут музыки", icon: "headphones")
                    statCard(value: "\(weekPlays)", label: "треков за неделю", icon: "calendar")
                }
                HStack(spacing: 12) {
                    statCard(value: "\(library.tracks.count)", label: "треков в медиатеке", icon: "music.note")
                    statCard(value: "\(library.likedTracks.count)", label: "с лайком", icon: "heart.fill")
                }

                if !topArtists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Любимые исполнители").font(.title3.bold())
                        ForEach(Array(topArtists.enumerated()), id: \.offset) { i, a in
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(.title2.weight(.heavy)).foregroundStyle(.tint).frame(width: 30)
                                Text(a.name).font(.body.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Text("\(a.plays) прослуш.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !topTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Топ треков").font(.title3.bold())
                            Spacer()
                            Button {
                                player.playTracks(topTracks.map(\.id))
                            } label: {
                                Label("Слушать", systemImage: "play.fill").font(.subheadline.weight(.semibold))
                            }
                        }
                        ForEach(Array(topTracks.enumerated()), id: \.element.id) { i, t in
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(.headline).foregroundStyle(.secondary).frame(width: 26)
                                ArtworkView(trackID: t.id, size: 44, corner: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(t.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("\(t.playCount)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Послушай немного музыки — здесь появится твой топ.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("Мои итоги")
    }

    private func statCard(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(.tint)
            Text(value).font(.system(size: 30, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}
