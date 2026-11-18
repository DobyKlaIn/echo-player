import SwiftUI
import UIKit
import AVKit

// MARK: - Обложка

struct ArtworkView: View {
    let trackID: String?
    var size: CGFloat? = nil
    var corner: CGFloat = 8
    var large = false

    var body: some View {
        content
            .frame(width: size, height: size)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        if let id = trackID, let img = (large ? ArtworkCache.shared.image(for: id) : ArtworkCache.shared.thumb(for: id)) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else if let id = trackID, let url = OnlineStore.shared.artworkURL(for: id, large: large) {
            RemoteImage(url: url, seed: id, iconScale: large ? 0.3 : 0.4)
        } else {
            PlaceholderArt(seed: trackID ?? "echo", iconScale: large ? 0.3 : 0.4)
        }
    }
}

/// Картинка из интернета с заглушкой, пока грузится
struct RemoteImage: View {
    let url: URL
    var seed: String
    var icon = "music.note"
    var iconScale: CGFloat = 0.4

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                PlaceholderArt(seed: seed, icon: icon, iconScale: iconScale)
            }
        }
    }
}

struct PlaceholderArt: View {
    let seed: String
    var icon = "music.note"
    var iconScale: CGFloat = 0.4

    var body: some View {
        let colors = ColorTools.seedColors(seed)
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(uiColor: colors.0), Color(uiColor: colors.1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: icon)
                    .font(.system(size: max(10, min(geo.size.width, geo.size.height) * iconScale), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

// MARK: - Строка трека

struct TrackRow: View {
    let track: Track
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var showArtwork = true
    var number: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let n = number {
                Text("\(n)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
            }
            if showArtwork {
                ZStack {
                    ArtworkView(trackID: track.id, size: 48, corner: 6)
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45)).frame(width: 48, height: 48)
                        EqualizerBars(animating: isPlaying)
                            .frame(width: 20, height: 16)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Text(track.displayArtist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if track.liked {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            Text(formatTime(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// Прыгающие столбики «сейчас играет»
struct EqualizerBars: View {
    var animating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !animating)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = t * (5 + Double(i) * 1.7) + Double(i) * 1.3
                    let h = animating ? 0.3 + 0.7 * abs(sin(phase)) : 0.35
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .scaleEffect(x: 1, y: h, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Меню трека

struct TrackMenuItems: View {
    let track: Track
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var library: Library
    var playlistContext: Playlist? = nil
    var onEdit: (() -> Void)? = nil

    var body: some View {
        Button { player.playNext(track.id) } label: {
            Label("Играть следующим", systemImage: "text.insert")
        }
        Button { player.addToQueue(track.id) } label: {
            Label("В конец очереди", systemImage: "text.append")
        }
        Divider()
        Button { player.toggleLike(track.id) } label: {
            Label(track.liked ? "Убрать лайк" : "Нравится", systemImage: track.liked ? "heart.slash" : "heart")
        }
        Menu {
            Button {
                if track.isOnline { OnlineStore.shared.remember(track.id) }
                library.createPlaylist(name: "Плейлист \(library.playlists.count + 1)", trackIDs: [track.id])
                library.toast = "Создан новый плейлист"
            } label: {
                Label("Новый плейлист", systemImage: "plus")
            }
            ForEach(library.playlists) { p in
                Button(p.name) {
                    if track.isOnline { OnlineStore.shared.remember(track.id) }
                    library.add(track.id, to: p.id)
                }
            }
        } label: {
            Label("Добавить в плейлист", systemImage: "music.note.list")
        }
        Button {
            if track.isOnline {
                OnlineStore.shared.toggleDislike(track.id)
            } else {
                library.toggleDislike(track.id)
            }
        } label: {
            Label(track.disliked ? "Вернуть в «Мою волну»" : "Не рекомендовать", systemImage: "hand.thumbsdown")
        }
        if track.isOnline {
            if let url = OnlineStore.shared.onlineTrack(track.id)?.webURL {
                Link(destination: url) {
                    Label("Открыть в Audius", systemImage: "arrow.up.right.square")
                }
            }
        } else {
            if let onEdit = onEdit {
                Button(action: onEdit) {
                    Label("Изменить название", systemImage: "pencil")
                }
            }
            Divider()
            Button(role: .destructive) {
                player.trackDeleted(track.id)
                library.deleteTrack(track.id)
            } label: {
                Label("Удалить с телефона", systemImage: "trash")
            }
        }
    }
}

// MARK: - Кнопки «Слушать / Перемешать»

struct PlayShuffleHeader: View {
    let ids: [String]
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.playTracks(ids, startAt: 0, shuffled: false)
            } label: {
                Label("Слушать", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(settings.accent.color))
                    .foregroundStyle(settings.accent.onAccent)
            }
            Button {
                let start = ids.isEmpty ? 0 : Int.random(in: 0..<ids.count)
                player.playTracks(ids, startAt: start, shuffled: true)
            } label: {
                Label("Перемешать", systemImage: "shuffle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1)))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .disabled(ids.isEmpty)
        .opacity(ids.isEmpty ? 0.5 : 1)
    }
}

// MARK: - AirPlay

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor.white.withAlphaComponent(0.85)
        v.activeTintColor = UIColor.white
        v.prioritizesVideoDevices = false
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Всплывающее уведомление

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}

// MARK: - Пустое состояние

struct EmptyStateView: View {
    let icon: String
    let title: String
    let text: String
    var buttonTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let buttonTitle = buttonTitle, let action = action {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(.tint))
                        .foregroundStyle(.black)
                }
                .padding(.top, 6)
            }
        }
        .padding(32)
    }
}
