import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: PlayerController
    @State private var showNew = false
    @State private var newName = ""
    @State private var renaming: Playlist? = nil
    @State private var renameText = ""

    var body: some View {
        List {
            Button {
                newName = ""
                showNew = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 56, height: 56)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                    Text("Новый плейлист").font(.body.weight(.semibold))
                }
            }
            .buttonStyle(.plain)

            ForEach(library.playlists) { p in
                NavigationLink {
                    PlaylistDetailView(playlistID: p.id)
                } label: {
                    HStack(spacing: 14) {
                        PlaylistCover(ids: p.trackIDs, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(p.name).font(.body.weight(.medium)).lineLimit(1)
                            Text("Треков: \(p.trackIDs.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    Button {
                        player.playTracks(p.trackIDs)
                    } label: { Label("Слушать", systemImage: "play.fill") }
                    Button {
                        renameText = p.name
                        renaming = p
                    } label: { Label("Переименовать", systemImage: "pencil") }
                    Button(role: .destructive) {
                        library.deletePlaylist(p.id)
                    } label: { Label("Удалить", systemImage: "trash") }
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { library.playlists[$0].id }
                ids.forEach { library.deletePlaylist($0) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Плейлисты")
        .alert("Новый плейлист", isPresented: $showNew) {
            TextField("Название", text: $newName)
            Button("Создать") { library.createPlaylist(name: newName) }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Переименовать", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Название", text: $renameText)
            Button("Сохранить") {
                if let p = renaming { library.renamePlaylist(p.id, to: renameText) }
                renaming = nil
            }
            Button("Отмена", role: .cancel) { renaming = nil }
        }
    }
}

struct PlaylistCover: View {
    let ids: [String]
    let size: CGFloat

    var body: some View {
        let first = Array(ids.prefix(4))
        Group {
            if first.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkView(trackID: first[0], size: size / 2, corner: 0)
                        ArtworkView(trackID: first[1], size: size / 2, corner: 0)
                    }
                    HStack(spacing: 0) {
                        ArtworkView(trackID: first[2], size: size / 2, corner: 0)
                        ArtworkView(trackID: first[3], size: size / 2, corner: 0)
                    }
                }
            } else if let f = first.first {
                ArtworkView(trackID: f, size: size, corner: 0)
            } else {
                PlaceholderArt(seed: "playlist", icon: "music.note.list")
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
    }
}

struct PlaylistDetailView: View {
    let playlistID: String
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: PlayerController
    @State private var showAdd = false

    var body: some View {
        if let p = library.playlist(playlistID) {
            let tracks = library.tracks(for: p.trackIDs)
            let ids = tracks.map(\.id)
            List {
                VStack(spacing: 10) {
                    PlaylistCover(ids: p.trackIDs, size: 200)
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                    Text(p.name).font(.title2.bold())
                    Text("Треков: \(tracks.count) · \(formatTime(tracks.reduce(0) { $0 + $1.duration }))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .padding(.vertical, 8)

                PlayShuffleHeader(ids: ids)
                    .listRowSeparator(.hidden)

                Button { showAdd = true } label: {
                    Label("Добавить треки", systemImage: "plus.circle.fill")
                        .font(.body.weight(.semibold))
                }

                ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                    Button {
                        player.playTracks(ids, startAt: i)
                    } label: {
                        TrackRow(track: t,
                                 isCurrent: player.currentTrackID == t.id && player.source == .local,
                                 isPlaying: player.isPlaying)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { TrackMenuItems(track: t, playlistContext: p) }
                }
                .onDelete { library.removeFromPlaylist(p.id, offsets: $0) }
                .onMove { library.movePlaylistTracks(p.id, from: $0, to: $1) }
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
            .sheet(isPresented: $showAdd) {
                AddTracksView(playlistID: p.id)
            }
        } else {
            Text("Плейлист удалён").foregroundStyle(.secondary)
        }
    }
}

struct AddTracksView: View {
    let playlistID: String
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
            let inPlaylist = Set(library.playlist(playlistID)?.trackIDs ?? [])
            let q = search.lowercased()
            let list = library.tracks.filter {
                q.isEmpty || $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
            }
            List(list) { t in
                Button {
                    library.add(t.id, to: playlistID)
                } label: {
                    HStack {
                        TrackRow(track: t)
                        Image(systemName: inPlaylist.contains(t.id) ? "checkmark.circle.fill" : "plus.circle")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Найти трек")
            .navigationTitle("Добавить треки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }
}
