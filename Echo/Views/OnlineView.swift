import SwiftUI

/// Вкладка «Онлайн»: бесплатная музыка независимых артистов из Audius
struct OnlineView: View {
    @EnvironmentObject var online: OnlineStore
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: AppSettings

    @State private var query = ""
    @State private var results: [String] = []
    @State private var searching = false
    @State private var trending: [String] = []
    @State private var loadingTrending = false
    @State private var trendingFailed = false
    @State private var playlists: [OnlinePlaylist] = []
    @State private var genre: OnlineGenre = OnlineGenre.all[0]
    @State private var period = "week"

    var body: some View {
        NavigationStack {
            List {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchSection
                } else {
                    browseSections
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Поиск в Audius")
            .searchSuggestions {
                if query.isEmpty {
                    ForEach(online.recentSearches, id: \.self) { s in
                        Label(s, systemImage: "clock.arrow.circlepath").searchCompletion(s)
                    }
                }
            }
            .onSubmit(of: .search) { online.addSearch(query) }
            .task(id: query) { await debouncedSearch() }
            .task(id: "\(genre.id)|\(period)") { await loadTrending() }
            .task { if playlists.isEmpty { playlists = await AudiusAPI.trendingPlaylists() } }
            .refreshable {
                await loadTrending()
                playlists = await AudiusAPI.trendingPlaylists()
            }
            .navigationTitle("Онлайн")
        }
    }

    // MARK: Поиск

    @ViewBuilder
    private var searchSection: some View {
        let tracks = online.tracks(results)
        Section {
            if searching && tracks.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            } else if tracks.isEmpty {
                VStack(spacing: 6) {
                    Text("Ничего не нашлось").font(.headline)
                    Text("В Audius в основном независимые артисты. Попробуй жанр, настроение или английское название.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowSeparator(.hidden)
            }
            trackRows(tracks)
        } header: {
            Text("Треки")
        }
    }

    private func debouncedSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = []
            searching = false
            return
        }
        searching = true
        try? await Task.sleep(nanoseconds: 450_000_000)
        if Task.isCancelled { return }
        let found = await AudiusAPI.search(q)
        if Task.isCancelled { return }
        online.register(found)
        results = found.map(\.id)
        searching = false
    }

    // MARK: Обзор

    @ViewBuilder
    private var browseSections: some View {
        Section {
            NavigationLink { OnlineLikedView() } label: {
                LibraryLinkLabel(title: "Мои лайки из Audius", icon: "heart.fill", count: online.likedIDs.count)
            }
        }

        if !playlists.isEmpty && genre.apiName == nil {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(playlists) { p in
                            NavigationLink { OnlinePlaylistView(playlist: p) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Group {
                                        if let url = URL(string: p.artwork), !p.artwork.isEmpty {
                                            RemoteImage(url: url, seed: p.id, icon: "music.note.list")
                                        } else {
                                            PlaceholderArt(seed: p.id, icon: "music.note.list")
                                        }
                                    }
                                    .frame(width: 140, height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    Text(p.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(p.owner.isEmpty ? "Треков: \(p.trackCount)" : p.owner)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(width: 140)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowSeparator(.hidden)
            } header: {
                Text("Популярные плейлисты")
            }
        }

        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(OnlineGenre.all) { g in
                        let selected = g == genre
                        Button {
                            genre = g
                        } label: {
                            Text(g.title)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(selected ? AnyShapeStyle(settings.accent.color) : AnyShapeStyle(Color.white.opacity(0.1))))
                                .foregroundStyle(selected ? settings.accent.onAccent : Color.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowSeparator(.hidden)

            Picker("Период", selection: $period) {
                Text("Неделя").tag("week")
                Text("Месяц").tag("month")
                Text("Всё время").tag("allTime")
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
        }

        let tracks = online.tracks(trending)
        Section {
            if loadingTrending && tracks.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            } else if trendingFailed && tracks.isEmpty {
                VStack(spacing: 8) {
                    Text("Не удалось загрузить").font(.headline)
                    Text("Проверь интернет и потяни список вниз.").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowSeparator(.hidden)
            } else if !tracks.isEmpty {
                PlayShuffleHeader(ids: tracks.map(\.id))
                    .listRowSeparator(.hidden)
            }
            trackRows(tracks)
        } header: {
            Text(genre.apiName == nil ? "В тренде" : "В тренде · \(genre.title)")
        } footer: {
            Text("Бесплатная музыка независимых артистов из Audius. Слушай и поддерживай авторов — открыть трек в Audius можно, зажав его.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
        }
    }

    private func loadTrending() async {
        loadingTrending = true
        trendingFailed = false
        let list = await AudiusAPI.trending(genre: genre.apiName, time: period, limit: 60)
        if Task.isCancelled { return }
        online.register(list)
        trending = list.map(\.id)
        trendingFailed = list.isEmpty
        loadingTrending = false
    }

    // MARK: Строки

    @ViewBuilder
    private func trackRows(_ tracks: [Track]) -> some View {
        let ids = tracks.map(\.id)
        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
            Button {
                player.playTracks(ids, startAt: i)
            } label: {
                TrackRow(track: t,
                         isCurrent: player.currentTrackID == t.id && player.source == .local,
                         isPlaying: player.isPlaying)
            }
            .buttonStyle(.plain)
            .contextMenu { TrackMenuItems(track: t) }
            .swipeActions(edge: .leading) {
                Button { player.playNext(t.id) } label: {
                    Label("Следующим", systemImage: "text.insert")
                }
                .tint(.orange)
            }
            .swipeActions(edge: .trailing) {
                Button { player.toggleLike(t.id) } label: {
                    Label("Лайк", systemImage: t.liked ? "heart.slash" : "heart")
                }
                .tint(.pink)
            }
        }
    }
}

struct OnlineLikedView: View {
    @EnvironmentObject var online: OnlineStore

    var body: some View {
        TrackListScreen(title: "Лайки из Audius", tracks: online.likedTracks)
    }
}

struct OnlinePlaylistView: View {
    let playlist: OnlinePlaylist
    @EnvironmentObject var online: OnlineStore
    @State private var ids: [String] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading && ids.isEmpty {
                ProgressView("Загружаю плейлист…")
            } else {
                TrackListScreen(title: playlist.name, tracks: online.tracks(ids),
                                headerArtworkID: ids.first,
                                subtitle: playlist.owner.isEmpty ? nil : playlist.owner)
            }
        }
        .task {
            guard ids.isEmpty else { return }
            let list = await AudiusAPI.playlistTracks(playlist.id)
            online.register(list)
            ids = list.map(\.id)
            loading = false
        }
    }
}
