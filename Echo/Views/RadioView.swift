import SwiftUI

struct RadioGenre: Identifiable, Hashable {
    let title: String
    let tag: String?
    var id: String { title }

    static let all: [RadioGenre] = [
        RadioGenre(title: "Популярное", tag: nil),
        RadioGenre(title: "Поп", tag: "pop"),
        RadioGenre(title: "Рок", tag: "rock"),
        RadioGenre(title: "Танцевальная", tag: "dance"),
        RadioGenre(title: "Хип-хоп", tag: "hip-hop"),
        RadioGenre(title: "Электроника", tag: "electronic"),
        RadioGenre(title: "Чилл", tag: "chillout"),
        RadioGenre(title: "Джаз", tag: "jazz"),
        RadioGenre(title: "Классика", tag: "classical"),
        RadioGenre(title: "Ретро", tag: "retro"),
        RadioGenre(title: "Шансон", tag: "chanson"),
        RadioGenre(title: "Новости", tag: "news")
    ]
}

struct RadioView: View {
    @EnvironmentObject var radio: RadioStore
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: AppSettings
    @State private var query = ""
    @State private var results: [RadioStation] = []
    @State private var loading = false
    @State private var genre: RadioGenre = RadioGenre.all[0]
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    if !radio.favorites.isEmpty {
                        Section("Избранное") {
                            ForEach(radio.favorites) { s in row(s) }
                        }
                    }
                    if !radio.recent.isEmpty {
                        Section("Недавние") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(radio.recent) { s in
                                        Button { play(s) } label: {
                                            VStack(spacing: 6) {
                                                StationLogo(station: s, size: 76)
                                                Text(s.name).font(.caption).lineLimit(1).frame(width: 80)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(RadioGenre.all) { g in
                                    let selected = g == genre
                                    Button {
                                        genre = g
                                        Task { await reload() }
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
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                }

                Section {
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if failed {
                        VStack(spacing: 8) {
                            Text("Не удалось загрузить станции").font(.headline)
                            Text("Проверь интернет и потяни список вниз.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else if results.isEmpty {
                        Text("Ничего не нашлось").foregroundStyle(.secondary)
                    }
                    ForEach(results) { s in row(s) }
                } header: {
                    Text(query.isEmpty ? (genre.tag == nil ? "Популярные станции" : genre.title) : "Результаты поиска")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Название станции")
            .onSubmit(of: .search) { Task { await reload() } }
            .onChange(of: query) { newValue in
                if newValue.isEmpty { Task { await reload() } }
            }
            .refreshable { await reload() }
            .task {
                if results.isEmpty { await reload() }
            }
            .navigationTitle("Радио")
        }
    }

    private func row(_ s: RadioStation) -> some View {
        let isCurrent = player.source == .radio && player.station?.id == s.id
        return Button { play(s) } label: {
            HStack(spacing: 12) {
                StationLogo(station: s, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    if !s.subtitle.isEmpty {
                        Text(s.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if isCurrent && player.isPlaying {
                    EqualizerBars(animating: true).frame(width: 18, height: 14).foregroundStyle(.tint)
                }
                Button {
                    radio.toggleFavorite(s)
                } label: {
                    Image(systemName: radio.isFavorite(s) ? "star.fill" : "star")
                        .foregroundStyle(radio.isFavorite(s) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderless)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func play(_ s: RadioStation) {
        if player.source == .radio && player.station?.id == s.id {
            player.togglePlay()
        } else {
            player.playStation(s)
            radio.markPlayed(s)
        }
    }

    private func reload() async {
        loading = true
        failed = false
        let q = query.trimmingCharacters(in: .whitespaces)
        let list: [RadioStation]
        if !q.isEmpty {
            list = await RadioService.search(name: q)
        } else if let tag = genre.tag {
            list = await RadioService.byTag(tag, countryCode: settings.radioCountry)
        } else {
            list = await RadioService.top(countryCode: settings.radioCountry)
        }
        results = list
        loading = false
        failed = list.isEmpty && q.isEmpty
    }
}

struct StationLogo: View {
    let station: RadioStation
    var size: CGFloat

    var body: some View {
        ZStack {
            PlaceholderArt(seed: station.id, icon: "dot.radiowaves.left.and.right", iconScale: 0.38)
            if let url = URL(string: station.favicon), !station.favicon.isEmpty {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}
