import SwiftUI
import UniformTypeIdentifiers

enum LibrarySort: String, CaseIterable, Identifiable {
    case added, title, artist, plays
    var id: String { rawValue }
    var title: String {
        switch self {
        case .added: return "Недавно добавленные"
        case .title: return "По названию"
        case .artist: return "По исполнителю"
        case .plays: return "По прослушиваниям"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: PlayerController
    @State private var search = ""
    @State private var showImporter = false
    @State private var importFolders = false
    @State private var showHelp = false
    @State private var editing: Track? = nil
    @AppStorage("librarySort") private var sortRaw = LibrarySort.added.rawValue

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .added }

    private var filtered: [Track] {
        var list = library.tracks
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) || $0.album.lowercased().contains(q)
            }
        }
        switch sort {
        case .added: list.sort { $0.addedAt > $1.addedAt }
        case .title: list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: list.sort { $0.displayArtist.localizedCaseInsensitiveCompare($1.displayArtist) == .orderedAscending }
        case .plays: list.sort { $0.playCount > $1.playCount }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            let items = filtered
            let ids = items.map(\.id)
            List {
                if search.isEmpty {
                    Section {
                        NavigationLink { PlaylistsView() } label: {
                            LibraryLinkLabel(title: "Плейлисты", icon: "music.note.list", count: library.playlists.count)
                        }
                        NavigationLink { SmartListView(kind: .liked) } label: {
                            LibraryLinkLabel(title: "Любимые треки", icon: "heart.fill", count: library.likedTracks.count)
                        }
                        NavigationLink { ArtistsView() } label: {
                            LibraryLinkLabel(title: "Исполнители", icon: "music.mic", count: nil)
                        }
                        NavigationLink { AlbumsView() } label: {
                            LibraryLinkLabel(title: "Альбомы", icon: "square.stack", count: nil)
                        }
                        NavigationLink { SmartListView(kind: .mostPlayed) } label: {
                            LibraryLinkLabel(title: "Часто слушаю", icon: "flame.fill", count: nil)
                        }
                        NavigationLink { SmartListView(kind: .forgotten) } label: {
                            LibraryLinkLabel(title: "Давно не слушал", icon: "clock.arrow.circlepath", count: nil)
                        }
                    }
                }

                if library.isScanning {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(library.scanStatus).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }

                if !items.isEmpty {
                    Section {
                        PlayShuffleHeader(ids: ids)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                            Button {
                                player.playTracks(ids, startAt: i)
                            } label: {
                                TrackRow(track: t,
                                         isCurrent: player.currentTrackID == t.id && player.source == .local,
                                         isPlaying: player.isPlaying)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { TrackMenuItems(track: t, onEdit: { editing = t }) }
                            .swipeActions(edge: .leading) {
                                Button { player.playNext(t.id) } label: {
                                    Label("Следующим", systemImage: "text.insert")
                                }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .trailing) {
                                Button { player.addToQueue(t.id) } label: {
                                    Label("В очередь", systemImage: "text.append")
                                }
                                .tint(.indigo)
                                Button { library.toggleLike(t.id) } label: {
                                    Label("Лайк", systemImage: t.liked ? "heart.slash" : "heart")
                                }
                                .tint(.pink)
                            }
                        }
                    } header: {
                        Text(search.isEmpty ? "Все треки · \(library.tracks.count)" : "Найдено · \(items.count)")
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Треки, исполнители, альбомы")
            .navigationTitle("Медиатека")
            .refreshable { await library.rescan() }
            .overlay {
                if library.tracks.isEmpty && !library.isScanning {
                    EmptyStateView(icon: "square.and.arrow.down.on.square",
                                   title: "Медиатека пуста",
                                   text: "Добавь mp3, m4a, flac или wav из «Файлов» или iCloud. Ещё можно в Telegram нажать на трек → «Поделиться» → «Эхо».",
                                   buttonTitle: "Добавить музыку") {
                        importFolders = false
                        showImporter = true
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            importFolders = false
                            showImporter = true
                        } label: { Label("Добавить файлы", systemImage: "doc.badge.plus") }
                        Button {
                            importFolders = true
                            showImporter = true
                        } label: { Label("Добавить папку", systemImage: "folder.badge.plus") }
                        Button { showHelp = true } label: {
                            Label("Другие способы", systemImage: "questionmark.circle")
                        }
                        Divider()
                        Picker("Сортировка", selection: $sortRaw) {
                            ForEach(LibrarySort.allCases) { s in
                                Text(s.title).tag(s.rawValue)
                            }
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: importFolders ? [.folder] : [.audio],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await library.importFiles(urls) }
                }
            }
            .sheet(isPresented: $showHelp) { ImportHelpView() }
            .sheet(item: $editing) { t in EditTrackView(track: t) }
        }
    }
}

struct LibraryLinkLabel: View {
    let title: String
    let icon: String
    let count: Int?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)
            Text(title).font(.body.weight(.medium))
            Spacer()
            if let c = count, c > 0 {
                Text("\(c)").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Список треков (альбом, исполнитель, подборка)

struct TrackListScreen: View {
    let title: String
    let tracks: [Track]
    var showNumbers = false
    var headerArtworkID: String? = nil
    var subtitle: String? = nil
    @EnvironmentObject var player: PlayerController
    @State private var editing: Track? = nil

    var body: some View {
        let ids = tracks.map(\.id)
        List {
            if let art = headerArtworkID {
                VStack(spacing: 10) {
                    ArtworkView(trackID: art, size: 220, corner: 14, large: true)
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                    Text(title).font(.title2.bold()).multilineTextAlignment(.center)
                    if let s = subtitle {
                        Text(s).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .padding(.vertical, 8)
            }
            PlayShuffleHeader(ids: ids)
                .listRowSeparator(.hidden)
            if tracks.isEmpty {
                Text("Здесь пока пусто")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                Button {
                    player.playTracks(ids, startAt: i)
                } label: {
                    TrackRow(track: t,
                             isCurrent: player.currentTrackID == t.id && player.source == .local,
                             isPlaying: player.isPlaying,
                             showArtwork: !showNumbers,
                             number: showNumbers ? i + 1 : nil)
                }
                .buttonStyle(.plain)
                .contextMenu { TrackMenuItems(track: t, onEdit: { editing = t }) }
                .swipeActions(edge: .leading) {
                    Button { player.playNext(t.id) } label: { Label("Следующим", systemImage: "text.insert") }
                        .tint(.orange)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(headerArtworkID == nil ? title : "")
        .navigationBarTitleDisplayMode(headerArtworkID == nil ? .large : .inline)
        .sheet(item: $editing) { t in EditTrackView(track: t) }
    }
}

enum SmartKind {
    case liked, mostPlayed, forgotten, recentlyAdded

    var title: String {
        switch self {
        case .liked: return "Любимые треки"
        case .mostPlayed: return "Часто слушаю"
        case .forgotten: return "Давно не слушал"
        case .recentlyAdded: return "Недавно добавленные"
        }
    }
}

struct SmartListView: View {
    let kind: SmartKind
    @EnvironmentObject var library: Library

    var body: some View {
        let tracks: [Track]
        switch kind {
        case .liked: tracks = library.likedTracks
        case .mostPlayed: tracks = library.mostPlayed
        case .forgotten: tracks = library.forgotten
        case .recentlyAdded: tracks = library.recentlyAdded
        }
        return TrackListScreen(title: kind.title, tracks: tracks)
    }
}

// MARK: - Исполнители и альбомы

struct ArtistsView: View {
    @EnvironmentObject var library: Library
    @State private var search = ""

    var body: some View {
        let q = search.lowercased()
        let list = library.artists.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        List(list) { a in
            NavigationLink {
                TrackListScreen(title: a.name, tracks: library.tracks(for: a.trackIDs))
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(trackID: a.trackIDs.first, size: 48, corner: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.body.weight(.medium)).lineLimit(1)
                        Text("Треков: \(a.trackIDs.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $search, prompt: "Найти исполнителя")
        .navigationTitle("Исполнители")
    }
}

struct AlbumsView: View {
    @EnvironmentObject var library: Library
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        let albums = library.albums
        ScrollView {
            if albums.isEmpty {
                Text("У треков нет информации об альбомах")
                    .foregroundStyle(.secondary)
                    .padding(.top, 60)
            }
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(albums) { album in
                    NavigationLink {
                        TrackListScreen(title: album.title, tracks: library.tracks(for: album.trackIDs),
                                        showNumbers: true, headerArtworkID: album.trackIDs.first,
                                        subtitle: album.artist)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ArtworkView(trackID: album.trackIDs.first, corner: 12, large: true)
                            Text(album.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .navigationTitle("Альбомы")
    }
}

// MARK: - Редактирование названия

struct EditTrackView: View {
    let track: Track
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Название") { TextField("Название", text: $title) }
                Section("Исполнитель") { TextField("Исполнитель", text: $artist) }
                Section("Альбом") { TextField("Альбом", text: $album) }
                Section {
                    Text("Файл: \(track.fileName)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Изменить")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        library.editInfo(track.id, title: title.trimmingCharacters(in: .whitespaces),
                                         artist: artist.trimmingCharacters(in: .whitespaces),
                                         album: album.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                title = track.title
                artist = track.artist
                album = track.album
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Как добавить музыку

struct ImportHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Из Telegram") {
                    Text("Нажми на аудиофайл → «⋯» или «Поделиться» → выбери «Эхо». Трек сразу появится в медиатеке.")
                }
                Section("Через приложение «Файлы»") {
                    Text("Открой «Файлы» → «На iPhone» → «Эхо» → «Музыка» и перетащи туда треки или целые папки. При следующем открытии «Эхо» найдёт их сам.")
                }
                Section("С компьютера") {
                    Text("Подключи iPhone к компьютеру. В Finder (Mac) или iTunes (Windows) открой «Файлы» → «Эхо» и перетащи музыку.")
                }
                Section("Тексты песен") {
                    Text("Тексты подгружаются автоматически из бесплатной базы LRCLIB. Если положить рядом с треком файл .lrc с тем же именем, будет использоваться он.")
                }
            }
            .navigationTitle("Как добавить музыку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Понятно") { dismiss() } }
            }
        }
    }
}
