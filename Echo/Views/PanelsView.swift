import SwiftUI

// MARK: - Тексты песен

struct LyricsView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss

    enum LoadState { case loading, loaded, notFound, instrumental }

    @State private var state: LoadState = .loading
    @State private var lines: [LyricLine] = []
    @State private var plain: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(white: 0.12), .black], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                switch state {
                case .loading:
                    ProgressView("Ищу текст…")
                case .notFound:
                    VStack(spacing: 14) {
                        Image(systemName: "text.badge.xmark").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("Текст не найден").font(.title3.bold())
                        Text("Проверь, что название и исполнитель трека указаны правильно (зажми трек → «Изменить название»).")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Искать снова") { Task { await load(force: true) } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(30)
                case .instrumental:
                    VStack(spacing: 12) {
                        Image(systemName: "pianokeys").font(.system(size: 44)).foregroundStyle(.tint)
                        Text("Инструментал — без слов").font(.title3.bold())
                    }
                case .loaded:
                    if !lines.isEmpty {
                        SyncedLyricsView(lines: lines, clock: player.clock) { player.seek(to: $0) }
                    } else {
                        ScrollView {
                            Text(plain)
                                .font(.title3.weight(.semibold))
                                .lineSpacing(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(24)
                        }
                    }
                }
            }
            .navigationTitle(player.currentTrack?.title ?? "Текст")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .task(id: player.currentTrackID) { await load(force: false) }
    }

    private func load(force: Bool) async {
        guard let track = player.currentTrack else {
            state = .notFound
            return
        }
        state = .loading
        let result = await LyricsService.load(track: track, fileURL: library.url(for: track), forceRefresh: force)
        guard let r = result else {
            state = .notFound
            return
        }
        if r.instrumental && (r.synced ?? "").isEmpty && (r.plain ?? "").isEmpty {
            state = .instrumental
            return
        }
        let parsed = LyricsService.parse(r.synced ?? "")
        lines = parsed
        plain = r.plain ?? (r.synced ?? "")
        state = (parsed.isEmpty && plain.isEmpty) ? .notFound : .loaded
    }
}

struct SyncedLyricsView: View {
    let lines: [LyricLine]
    @ObservedObject var clock: PlaybackClock
    let onTap: (Double) -> Void

    private var currentIndex: Int {
        lines.lastIndex(where: { $0.time <= clock.time + 0.3 }) ?? -1
    }

    var body: some View {
        let cur = currentIndex
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 27, weight: .bold))
                            .foregroundStyle(Color.white.opacity(line.id == cur ? 1 : (line.id < cur ? 0.3 : 0.45)))
                            .scaleEffect(line.id == cur ? 1.0 : 0.96, anchor: .leading)
                            .animation(.easeInOut(duration: 0.3), value: cur)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .id(line.id)
                            .onTapGesture { onTap(line.time) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 220)
            }
            .onChange(of: cur) { newValue in
                guard newValue >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onAppear {
                if cur >= 0 { proxy.scrollTo(cur, anchor: .center) }
            }
        }
    }
}

// MARK: - Очередь

struct QueueView: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let t = player.currentTrack {
                    Section("Сейчас играет") {
                        TrackRow(track: t, isCurrent: true, isPlaying: player.isPlaying)
                    }
                }
                let up = player.upcoming
                Section {
                    if up.isEmpty {
                        Text("Дальше ничего нет").foregroundStyle(.secondary)
                    }
                    ForEach(Array(up.enumerated()), id: \.offset) { offset, id in
                        if let t = library.track(id) {
                            Button {
                                player.jump(toQueueIndex: player.index + 1 + offset)
                            } label: {
                                TrackRow(track: t)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onMove { player.moveUpcoming(from: $0, to: $1) }
                    .onDelete { player.removeUpcoming(at: $0) }
                } header: {
                    HStack {
                        Text(player.isWave ? "Далее в «Моей волне»" : "Далее")
                        Spacer()
                        if !up.isEmpty && !player.isWave {
                            Button("Очистить") { player.clearUpcoming() }
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Очередь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }
}

// MARK: - Эквалайзер

struct EqualizerView: View {
    var inSheet = false
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    var body: some View {
        if inSheet {
            NavigationStack {
                content
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
                    }
            }
            .presentationDetents([.large])
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Toggle(isOn: $settings.eqEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Эквалайзер").font(.headline)
                        Text(settings.eqEnabled ? "Пресет: \(settings.eqPresetName)" : "Выключен")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(settings.accent.color)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(EQPreset.all) { preset in
                            let selected = settings.eqPresetName == preset.name && settings.eqEnabled
                            Button { settings.apply(preset) } label: {
                                Text(preset.name)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(selected ? AnyShapeStyle(settings.accent.color) : AnyShapeStyle(Color.white.opacity(0.1))))
                                    .foregroundStyle(selected ? settings.accent.onAccent : Color.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<10, id: \.self) { i in
                        VStack(spacing: 8) {
                            Text(gainText(settings.eqGains[i]))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            VerticalSlider(value: gainBinding(i), range: -12...12)
                                .frame(height: 220)
                            Text(labels[i])
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .opacity(settings.eqEnabled ? 1 : 0.4)
                .padding(.vertical, 8)

                Button {
                    settings.apply(EQPreset.all[0])
                } label: {
                    Label("Сбросить", systemImage: "arrow.counterclockwise")
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Плавный переход между треками").font(.headline)
                        Spacer()
                        Text(settings.crossfade == 0 ? "выкл" : "\(Int(settings.crossfade)) с")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.crossfade, in: 0...12, step: 1)
                        .tint(settings.accent.color)
                    Text("Конец одного трека мягко перетекает в начало следующего, как в Spotify.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("Звук")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func gainText(_ g: Float) -> String {
        let v = Int(g.rounded())
        return v > 0 ? "+\(v)" : "\(v)"
    }

    private func gainBinding(_ i: Int) -> Binding<Float> {
        Binding(
            get: { settings.eqGains.indices.contains(i) ? settings.eqGains[i] : 0 },
            set: { newValue in
                guard settings.eqGains.indices.contains(i) else { return }
                settings.eqGains[i] = newValue
                settings.eqPresetName = "Свой"
                if !settings.eqEnabled { settings.eqEnabled = true }
            }
        )
    }
}

struct VerticalSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = range.upperBound - range.lowerBound
            let p = CGFloat((value - range.lowerBound) / span)
            let mid = h / 2
            let y = h * (1 - p)
            ZStack(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 5)
                Rectangle()
                    .fill(.tint)
                    .frame(width: 5, height: abs(mid - y))
                    .offset(y: min(mid, y))
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: 14, height: 1).offset(y: mid)
                Circle()
                    .fill(Color.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(y: y - 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let pp = 1 - min(max(g.location.y / max(h, 1), 0), 1)
                    let raw = range.lowerBound + Float(pp) * span
                    value = (raw * 2).rounded() / 2
                }
            )
        }
    }
}

// MARK: - Таймер сна

struct SleepTimerView: View {
    @EnvironmentObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    struct SleepOption: Identifiable {
        let title: String
        let minutes: Int
        var id: Int { minutes }
    }

    private let options: [SleepOption] = [
        SleepOption(title: "5 минут", minutes: 5), SleepOption(title: "10 минут", minutes: 10),
        SleepOption(title: "15 минут", minutes: 15), SleepOption(title: "30 минут", minutes: 30),
        SleepOption(title: "45 минут", minutes: 45), SleepOption(title: "1 час", minutes: 60),
        SleepOption(title: "1,5 часа", minutes: 90), SleepOption(title: "2 часа", minutes: 120)
    ]

    var body: some View {
        NavigationStack {
            List {
                if player.sleepEndDate != nil || player.sleepAtTrackEnd {
                    Section {
                        if let end = player.sleepEndDate {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Label("Осталось \(formatTime(max(0, end.timeIntervalSince(ctx.date))))", systemImage: "moon.zzz.fill")
                            }
                        } else {
                            Label("Остановлю после этого трека", systemImage: "moon.zzz.fill")
                        }
                        Button(role: .destructive) {
                            player.setSleepTimer(minutes: nil)
                            dismiss()
                        } label: {
                            Text("Выключить таймер")
                        }
                    }
                }
                Section("Выключить музыку через") {
                    ForEach(options) { option in
                        Button(option.title) {
                            player.setSleepTimer(minutes: option.minutes)
                            dismiss()
                        }
                    }
                    Button("В конце трека") {
                        player.setSleepTimer(minutes: -1)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Таймер сна")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
