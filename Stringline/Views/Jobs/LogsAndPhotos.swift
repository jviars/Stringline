import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Daily logs

struct DailyLogsView: View {
    @Environment(AppStore.self) private var store
    let jobID: UUID

    var body: some View {
        let logs = store.logsBinding(jobID)
        let entries = logs.wrappedValue.entries
        let option = store.estimates[jobID]?.selected
        let bidTons = option?.items.filter { $0.key == "surfaceMix" || $0.key == "baseMix" }.reduce(0) { $0 + $1.qty } ?? 0
        let bidHours = option?.items.filter { $0.key == "crewLabor" }.reduce(0) { $0 + $1.qty } ?? 0
        let tons = entries.reduce(0) { $0 + $1.tons }
        let hours = entries.reduce(0) { $0 + $1.hours }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    CardHeader(title: "How close was the bid?", subtitle: "Actuals from your logs compared with the estimate")
                    HStack(spacing: 24) {
                        compare("Tons laid", actual: tons, bid: bidTons, unit: "tn")
                        compare("Crew hours", actual: hours, bid: bidHours, unit: "hr")
                    }
                }
                .card(padding: 20)

                VStack(alignment: .leading, spacing: 4) {
                    CardHeader(title: "Daily logs") {
                        Button {
                            var entry = DailyLog()
                            entry.crewID = store.job(jobID)?.schedule.first(where: { $0.day.isSameDay(.now) })?.crewID ?? store.settings.crews.first?.id
                            if let forecast = store.weather.forecast(for: .now) {
                                entry.weather = "\(Int(forecast.high))° / \(Int(forecast.low))°, \(forecast.rainChance)% rain"
                            }
                            logs.wrappedValue.entries.insert(entry, at: 0)
                        } label: {
                            Label("Add today's log", systemImage: "plus")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .helpSpot("jobLogs.add")
                    }
                    .padding(.bottom, 8)
                    if entries.isEmpty {
                        Text("Log tons, hours and notes at the end of each day. It's how you learn what jobs really cost.")
                            .font(.ui(13)).foregroundStyle(Palette.secondary).padding(.vertical, 10)
                    }
                    ForEach(entries) { entry in
                        LogRow(entry: logBinding(entry.id)) {
                            logs.wrappedValue.entries.removeAll { $0.id == entry.id }
                        }
                        .overlay(alignment: .top) { Hairline() }
                    }
                }
                .card(padding: 20)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func logBinding(_ id: UUID) -> Binding<DailyLog> {
        Binding(
            get: { store.logs[jobID]?.entries.first { $0.id == id } ?? DailyLog() },
            set: { new in
                var logs = store.logs[jobID] ?? JobLogs()
                guard let i = logs.entries.firstIndex(where: { $0.id == id }) else { return }
                logs.entries[i] = new
                store.logsBinding(jobID).wrappedValue = logs
            })
    }

    private func compare(_ label: String, actual: Double, bid: Double, unit: String) -> some View {
        let ratio = bid > 0 ? actual / bid : 0
        return VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.ui(12)).foregroundStyle(Palette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.number(actual, decimals: actual == actual.rounded() ? 0 : 1)).font(.display(28)).monospacedDigit()
                Text("of \(bid > 0 ? Fmt.number(bid) : "—") \(unit) bid").font(.ui(12.5)).foregroundStyle(Palette.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.chip)
                    Capsule().fill(ratio > 1.05 ? Color(hex: 0xB42318) : Palette.ink)
                        .frame(width: proxy.size.width * CGFloat(min(ratio, 1)))
                }
            }
            .frame(height: 8)
            Text(bid == 0 ? "No estimate to compare yet" : (ratio > 1.05 ? "Over the bid by \(Int((ratio - 1) * 100))%" : "\(Int(ratio * 100))% of the bid used"))
                .font(.ui(12)).foregroundStyle(ratio > 1.05 ? Palette.noGoInk : Palette.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LogRow: View {
    @Environment(AppStore.self) private var store
    @Binding var entry: DailyLog
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                DatePicker("Day", selection: $entry.day, displayedComponents: .date).labelsHidden()
                Picker("Crew", selection: $entry.crewID) {
                    Text("No crew").tag(UUID?.none)
                    ForEach(store.settings.crews) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .labelsHidden()
                .frame(width: 140)
                Spacer()
                Button(action: onDelete) { Image(systemName: "trash").foregroundStyle(Palette.tertiary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete this log")
            }
            HStack(alignment: .top, spacing: 12) {
                NumberBox(label: "Tons laid", value: $entry.tons, unit: "tn", decimals: 1)
                NumberBox(label: "Crew hours", value: $entry.hours, unit: "hr", decimals: 1)
                TextBox(label: "Weather", text: $entry.weather, placeholder: "Sunny, 62°")
            }
            TextBox(label: "Notes", text: $entry.notes, placeholder: "Plant tickets, problems, change orders…")
        }
        .padding(.vertical, 14)
    }
}

// MARK: - Photos

struct PhotosView: View {
    @Environment(AppStore.self) private var store
    let jobID: UUID
    @State private var files: [URL] = []
    @State private var targeted = false

    private var folder: URL? { store.job(jobID).flatMap { store.photosFolder($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photos").font(.ui(15, weight: .bold))
                        Text("Before and after shots, plant tickets, problems on site. They're saved in this job's photos folder.")
                            .font(.ui(12.5)).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Button {
                        add(FilePicker.chooseImages(multiple: true))
                    } label: {
                        Label("Add photos", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .helpSpot("jobPhotos.add")
                    Button {
                        if let folder {
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    } label: {
                        Label("Show folder", systemImage: "folder")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                if files.isEmpty {
                    EmptyState(icon: "photo.on.rectangle", title: "Drop photos here",
                               message: "Drag them in from Photos, Finder or AirDrop, or use Add photos.")
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .background(targeted ? Palette.accentWash : Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: 0xC9C9C3), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                        ForEach(files, id: \.self) { url in
                            Thumbnail(url: url)
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                                .contextMenu {
                                    Button("Open") { NSWorkspace.shared.open(url) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) {
                                        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                                        reload()
                                    }
                                }
                        }
                    }
                    .padding(12)
                    .background(targeted ? Palette.accentWash : .clear, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { targeted = $0 }
        .onAppear(perform: reload)
    }

    private func reload() {
        guard let folder else { files = []; return }
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        files = all.filter { url in
            (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false)
        }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func add(_ urls: [URL]) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in urls where UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false {
            var target = folder.appending(path: url.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appending(path: "\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)")
                n += 1
            }
            do {
                try FileManager.default.copyItem(at: url, to: target)
            } catch {
                store.problem = "Couldn't add \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        reload()
    }
}

private struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Palette.chip
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(url.lastPathComponent).font(.ui(11.5)).foregroundStyle(Palette.secondary).lineLimit(1)
        }
        .task(id: url) {
            let path = url
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(path as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 480,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
        }
    }
}
