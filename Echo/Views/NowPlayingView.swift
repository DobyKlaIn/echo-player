import SwiftUI
import UIKit

enum PlayerPanel: String, Identifiable {
    case lyrics, queue, equalizer, sleep
    var id: String { rawValue }
}

/// Полноэкранный плеер
struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var radio: RadioStore
    @EnvironmentObject var online: OnlineStore
    @Environment(\.dismiss) private var dismiss
    @State private var bg: Color = Color(white: 0.2)
    @State private var panel: PlayerPanel? = nil

    var body: some View {
        ZStack {
            LinearGradient(colors: [bg, bg.opacity(0.55), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if player.source == .radio, let st = player.station {
                radioContent(st)
            } else if let track = player.currentTrack {
                trackContent(track)
            } else {
                VStack(spacing: 12) {
                    Text("Ничего не играет").font(.title2.bold())
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .task(id: player.source == .radio ? (player.station?.id ?? "radio") : (player.currentTrackID ?? "")) {
            await updateBackground()
        }
        .sheet(item: $panel) { p in
            panelView(p)
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(online)
                .tint(settings.accent.color)
                .preferredColorScheme(.dark)
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: Трек

    private func trackContent(_ track: Track) -> some View {
        VStack(spacing: 0) {
            header(title: player.isWave ? "Моя волна" : (track.isOnline ? "Audius · онлайн" : "Сейчас играет"))
            Spacer(minLength: 12)
            ArtworkView(trackID: track.id, corner: 18, large: true)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .scaleEffect(player.isPlaying ? 1 : 0.86)
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
                .padding(.horizontal, 28)
                .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                    if g.translation.width < -50 { player.next() }
                    else if g.translation.width > 50 { player.previous() }
                })
            Spacer(minLength: 20)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
                Button { player.dislikeCurrent() } label: {
                    Image(systemName: track.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                Button {
                    player.toggleLikeCurrent()
                } label: {
                    Image(systemName: track.liked ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundStyle(track.liked ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white))
                        .frame(width: 44, height: 44)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)

            SeekBar(clock: player.clock, duration: player.duration) { player.seek(to: $0) }
                .padding(.horizontal, 28)
                .padding(.top, 14)

            controls
                .padding(.horizontal, 28)
                .padding(.top, 6)

            bottomRow
                .padding(.horizontal, 36)
                .padding(.top, 18)
                .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
    }

    private func header(title: String) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 1) {
                Text(title.uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.75))
                if let end = player.sleepEndDate {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("Сон через \(formatTime(max(0, end.timeIntervalSince(ctx.date))))")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else if player.sleepAtTrackEnd {
                    Text("Сон после этого трека").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            Button { panel = .queue } label: {
                Image(systemName: "list.bullet")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var controls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(player.shuffle ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.75)))
            }
            .disabled(player.isWave)
            .opacity(player.isWave ? 0.3 : 1)
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 30))
            }
            Spacer()
            Button { player.togglePlay() } label: {
                ZStack {
                    Circle().fill(Color.white)
                    if player.isBuffering {
                        ProgressView().tint(.black).scaleEffect(1.3)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 78, height: 78)
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 30))
            }
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode.icon)
                    .font(.title3)
                    .foregroundStyle(player.repeatMode != .off ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.75)))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var bottomRow: some View {
        HStack {
            Button { panel = .lyrics } label: {
                Image(systemName: "quote.bubble").font(.title3)
            }
            Spacer()
            Button { panel = .equalizer } label: {
                Image(systemName: "slider.vertical.3")
                    .font(.title3)
                    .foregroundStyle(settings.eqEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white))
            }
            Spacer()
            AirPlayButton().frame(width: 30, height: 30)
            Spacer()
            Button { panel = .sleep } label: {
                Image(systemName: player.sleepEndDate != nil || player.sleepAtTrackEnd ? "moon.zzz.fill" : "moon.zzz")
                    .font(.title3)
                    .foregroundStyle(player.sleepEndDate != nil || player.sleepAtTrackEnd ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
    }

    // MARK: Радио

    private func radioContent(_ st: RadioStation) -> some View {
        VStack(spacing: 0) {
            header(title: "Радио")
            Spacer()
            StationLogo(station: st, size: 260)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .scaleEffect(player.isPlaying ? 1 : 0.88)
                .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
            Spacer()
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(player.radioBuffering ? "ЗАГРУЗКА…" : "В ЭФИРЕ")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                }
                Text(player.radioTitle ?? st.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(st.name)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(.horizontal, 28)
            HStack(spacing: 40) {
                Button { radio.toggleFavorite(st) } label: {
                    Image(systemName: radio.isFavorite(st) ? "star.fill" : "star")
                        .font(.title2)
                        .foregroundStyle(radio.isFavorite(st) ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white))
                }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 78, height: 78)
                        .background(Circle().fill(Color.white))
                }
                AirPlayButton().frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
        .foregroundStyle(.white)
    }

    // MARK: Панели

    @ViewBuilder
    private func panelView(_ p: PlayerPanel) -> some View {
        switch p {
        case .lyrics: LyricsView()
        case .queue: QueueView()
        case .equalizer: EqualizerView(inSheet: true)
        case .sleep: SleepTimerView()
        }
    }

    // MARK: Цвет фона

    private func updateBackground() async {
        var image: UIImage?
        if player.source == .local, let id = player.currentTrackID {
            if OnlineStore.isOnline(id) {
                await online.ensureArtwork(id)
            }
            image = ArtworkCache.shared.image(for: id)
        }
        let color: UIColor
        if let img = image, let avg = ColorTools.averageColor(of: img) {
            color = avg
        } else {
            let seed = player.currentTrackID ?? player.station?.id ?? "echo"
            color = ColorTools.seedColors(seed).0
        }
        withAnimation(.easeInOut(duration: 0.7)) {
            bg = Color(uiColor: color)
        }
    }
}

// MARK: - Полоса перемотки

struct SeekBar: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    let onSeek: (Double) -> Void
    @State private var dragValue: Double? = nil

    var body: some View {
        let value = dragValue ?? clock.time
        let p = duration > 0 ? min(max(value / duration, 0), 1) : 0
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = max(1, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    Capsule().fill(Color.white).frame(width: w * p)
                }
                .frame(height: dragValue == nil ? 5 : 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragValue = min(max(g.location.x / w, 0), 1) * duration
                        }
                        .onEnded { g in
                            let v = min(max(g.location.x / w, 0), 1) * duration
                            onSeek(v)
                            dragValue = nil
                        }
                )
            }
            .frame(height: 26)
            HStack {
                Text(formatTime(value))
                Spacer()
                Text("-" + formatTime(max(0, duration - value)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.65))
        }
        .animation(.easeOut(duration: 0.15), value: dragValue == nil)
    }
}
