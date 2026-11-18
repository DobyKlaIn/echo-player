import SwiftUI

/// Главный экран: «Моя волна» как в Яндекс Музыке + быстрые подборки
struct WaveView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @State private var showImport = false

    private var waveActive: Bool { player.isWave && player.source == .local }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero
                    moodPicker
                    if !library.tracks.isEmpty {
                        mixes
                    }
                    if !library.recentlyPlayed.isEmpty {
                        shelf(title: "Недавно слушал", tracks: library.recentlyPlayed)
                    }
                    if !library.recentlyAdded.isEmpty {
                        shelf(title: "Недавно добавленные", tracks: Array(library.recentlyAdded.prefix(20)))
                    }
                    if library.tracks.isEmpty && !settings.waveOnline {
                        EmptyStateView(icon: "music.note.house",
                                       title: "Добавь свою музыку",
                                       text: "Открой вкладку «Медиатека» и нажми «+», или поделись mp3 из Telegram → «Эхо». «Моя волна» начнёт подбирать треки под тебя.")
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 24)
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(Color.black.ignoresSafeArea())
        }
    }

    // MARK: Волна

    private var hero: some View {
        ZStack {
            WaveBlob(active: waveActive && player.isPlaying, color: settings.accent.color)
                .frame(height: 360)
                .allowsHitTesting(false)
            VStack(spacing: 14) {
                Button {
                    if waveActive {
                        player.togglePlay()
                    } else {
                        player.startWave()
                    }
                } label: {
                    ZStack {
                        Circle().fill(settings.accent.color)
                        if player.isPreparingWave || (waveActive && player.isBuffering) {
                            ProgressView().tint(settings.accent.onAccent).scaleEffect(1.4)
                        } else {
                            Image(systemName: waveActive && player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(settings.accent.onAccent)
                        }
                    }
                    .frame(width: 84, height: 84)
                    .shadow(color: settings.accent.color.opacity(0.6), radius: 24)
                }
                .buttonStyle(.plain)
                Text("Моя волна")
                    .font(.system(size: 34, weight: .heavy))
                if waveActive, let t = player.currentTrack {
                    VStack(spacing: 2) {
                        Text(t.title).font(.headline).lineLimit(1)
                        Text(t.displayArtist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 40)
                    .onTapGesture { player.showNowPlaying = true }
                } else {
                    Text(settings.waveMood.hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
        }
        .padding(.top, 20)
    }

    private var moodPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Характер волны")
                .font(.headline)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WaveMood.allCases) { mood in
                        let selected = settings.waveMood == mood
                        Button {
                            settings.waveMood = mood
                            player.waveMoodChanged()
                        } label: {
                            Label(mood.title, systemImage: mood.icon)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(selected ? AnyShapeStyle(settings.accent.color) : AnyShapeStyle(Color.white.opacity(0.1))))
                                .foregroundStyle(selected ? settings.accent.onAccent : Color.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            Toggle(isOn: $settings.waveOnline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Открытия из Audius").font(.subheadline.weight(.semibold))
                    Text("Подмешивать в волну свежие онлайн-треки").font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(settings.accent.color)
            .padding(.horizontal, 20)
            .onChange(of: settings.waveOnline) { _ in player.waveMoodChanged() }
        }
    }

    // MARK: Подборки

    private var mixes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Подборки")
                .font(.title3.bold())
                .padding(.horizontal, 20)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                mixTile("Любимые", icon: "heart.fill", colors: [.pink, .purple], ids: library.likedTracks.map(\.id))
                mixTile("Всё вперемешку", icon: "shuffle", colors: [.blue, .teal], ids: library.tracks.map(\.id), shuffled: true)
                mixTile("Часто слушаю", icon: "flame.fill", colors: [.orange, .red], ids: library.mostPlayed.map(\.id))
                mixTile("Давно не слушал", icon: "clock.arrow.circlepath", colors: [.indigo, .mint], ids: library.forgotten.map(\.id), shuffled: true)
            }
            .padding(.horizontal, 20)
        }
    }

    private func mixTile(_ title: String, icon: String, colors: [Color], ids: [String], shuffled: Bool = false) -> some View {
        Button {
            if ids.isEmpty {
                library.toast = title == "Любимые" ? "Поставь лайки трекам ♥" : "Пока пусто — слушай больше"
            } else {
                let start = shuffled ? Int.random(in: 0..<ids.count) : 0
                player.playTracks(ids, startAt: start, shuffled: shuffled)
            }
        } label: {
            HStack {
                Image(systemName: icon).font(.title3)
                Text(title).font(.subheadline.weight(.bold)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(ids.isEmpty ? 0.45 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func shelf(title: String, tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                        Button {
                            player.playTracks(tracks.map(\.id), startAt: i)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(trackID: t.id, size: 132, corner: 12)
                                Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(t.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 132)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TrackMenuItems(track: t) }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

/// Переливающееся «облако» как у волны в Яндекс Музыке
struct WaveBlob: View {
    var active: Bool
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let speed = active ? 1.0 : 0.3
                let palette: [Color] = [color, .pink, .purple, .blue, color]
                for i in 0..<5 {
                    let fi = Double(i)
                    let phase = t * speed * (0.5 + fi * 0.13) + fi * 1.7
                    let base = min(size.width, size.height) * 0.26
                    let pulse = active ? 0.08 * sin(t * 3.2 + fi) : 0.03 * sin(t + fi)
                    let r = base * (1 + pulse + fi * 0.04)
                    let dx = cos(phase) * 46 * (1 + fi * 0.15)
                    let dy = sin(phase * 1.3) * 34
                    let rect = CGRect(x: c.x + dx - r, y: c.y + dy - r, width: r * 2, height: r * 2)
                    gc.fill(Path(ellipseIn: rect), with: .color(palette[i].opacity(active ? 0.55 : 0.35)))
                }
            }
            .blur(radius: 44)
        }
    }
}
