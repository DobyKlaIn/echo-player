import SwiftUI

struct RootView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var radio: RadioStore
    @EnvironmentObject var online: OnlineStore

    var body: some View {
        TabView {
            WaveView()
                .withMiniPlayer()
                .tabItem { Label("Волна", systemImage: "waveform") }
            OnlineView()
                .withMiniPlayer()
                .tabItem { Label("Онлайн", systemImage: "globe") }
            LibraryView()
                .withMiniPlayer()
                .tabItem { Label("Медиатека", systemImage: "square.stack.fill") }
            RadioView()
                .withMiniPlayer()
                .tabItem { Label("Радио", systemImage: "dot.radiowaves.left.and.right") }
            SettingsView()
                .withMiniPlayer()
                .tabItem { Label("Ещё", systemImage: "ellipsis.circle.fill") }
        }
        .sheet(isPresented: $player.showNowPlaying) {
            NowPlayingView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(radio)
                .environmentObject(online)
                .tint(settings.accent.color)
                .preferredColorScheme(.dark)
        }
        .overlay(alignment: .top) {
            if let text = library.toast {
                ToastView(text: text)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        withAnimation { library.toast = nil }
                    }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: library.toast)
    }
}

extension View {
    func withMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerView()
        }
    }
}

struct MiniPlayerView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var library: Library
    @EnvironmentObject var online: OnlineStore

    var body: some View {
        if player.hasContent {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    artwork
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if player.source == .local, let id = player.currentTrackID {
                        let liked = player.isLiked(id)
                        Button {
                            player.toggleLike(id)
                        } label: {
                            Image(systemName: liked ? "heart.fill" : "heart")
                                .font(.title3)
                                .foregroundStyle(liked ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                                .frame(width: 36, height: 36)
                        }
                    }
                    Button {
                        player.togglePlay()
                    } label: {
                        ZStack {
                            if player.isBuffering || player.radioBuffering {
                                ProgressView()
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title2)
                            }
                        }
                        .frame(width: 36, height: 36)
                    }
                    if player.source == .local {
                        Button {
                            player.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.title3)
                                .frame(width: 36, height: 36)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                if player.source == .local {
                    MiniProgress(clock: player.clock, duration: player.duration)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08)))
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture { player.showNowPlaying = true }
            .gesture(DragGesture(minimumDistance: 20).onEnded { g in
                if g.translation.height < -30 { player.showNowPlaying = true }
                else if g.translation.width < -60 { player.next() }
                else if g.translation.width > 60 { player.previous() }
            })
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if player.source == .radio, let st = player.station {
            StationLogo(station: st, size: 44)
        } else {
            ArtworkView(trackID: player.currentTrackID, size: 44, corner: 8)
        }
    }

    private var title: String {
        if player.source == .radio { return player.radioTitle ?? player.station?.name ?? "Радио" }
        return player.currentTrack?.title ?? ""
    }

    private var subtitle: String {
        if player.source == .radio { return player.station?.name ?? "" }
        if player.isWave { return "Моя волна · " + (player.currentTrack?.displayArtist ?? "") }
        if player.isCurrentOnline { return "Audius · " + (player.currentTrack?.displayArtist ?? "") }
        return player.currentTrack?.displayArtist ?? ""
    }
}

struct MiniProgress: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double

    var body: some View {
        GeometryReader { geo in
            let p = duration > 0 ? min(1, max(0, clock.time / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(.tint).frame(width: geo.size.width * p)
            }
        }
        .frame(height: 2.5)
    }
}
