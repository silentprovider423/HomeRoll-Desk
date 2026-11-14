import AppKit
import MapKit
import SwiftUI

// MARK: - Rückblicke

/// Rückblicke wie in Fotos (Immich erzeugt „Heute vor X Jahren“); Klick zeigt die Fotos des Rückblicks.
struct MemoriesOverview: View {
    @Bindable var lib: Library
    var body: some View {
        if lib.memories.isEmpty {
            ContentUnavailableView("No Memories for Today", systemImage: "clock.arrow.circlepath",
                                   description: Text("The server creates memories from photos taken on this day in previous years."))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18)], spacing: 18) {
                    ForEach(lib.memories) { m in
                        let title = Self.title(m)
                        Button { lib.open(.memory(m.id, title)) } label: {
                            Thumb(id: m.assets.first(where: { $0.type == "IMAGE" })?.id ?? m.assets.first?.id)
                                .frame(height: 300)
                                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom))
                                .overlay(alignment: .bottomLeading) {
                                    VStack(alignment: .leading) {
                                        Text(title).font(.title2.bold())
                                        Text(itemsText(m.assets.count)).font(.callout)
                                    }.foregroundStyle(.white).padding(14)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                    }
                }.padding(20)
            }
        }
    }

    static func title(_ m: MemoryDTO) -> String {
        guard let y = m.data.year else { return "Memory" }
        let n = Calendar.current.component(.year, from: Date()) - y
        return n == 1 ? "One Year Ago Today" : "\(n) Years Ago Today"
    }
}

// MARK: - Karte

/// Karte mit einem Punkt je Ort (Größe = Anzahl); Klick zeigt alle Fotos von dort.
struct MapOverview: View {
    @Bindable var lib: Library
    @State private var places: [Place] = []

    struct Place: Identifiable {
        let id: String
        let name: String
        let coord: CLLocationCoordinate2D
        let count: Int
        let sample: String
    }

    var body: some View {
        Map {
            ForEach(places) { p in
                Annotation(p.name, coordinate: p.coord) {
                    Button { lib.open(.city(p.name)) } label: {
                        Thumb(id: p.sample)
                            .frame(width: size(p), height: size(p))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
                            .overlay(alignment: .topTrailing) {
                                Text("\(p.count)").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.blue, in: Capsule()).foregroundStyle(.white).offset(x: 6, y: -6)
                            }
                            .shadow(radius: 3)
                    }.buttonStyle(.plain).help("\(p.name): \(itemsText(p.count))")
                }
            }
        }
        .task { await load() }
    }

    private func size(_ p: Place) -> CGFloat { min(64, 30 + CGFloat(log2(Double(p.count) + 1)) * 5) }

    private func load() async {
        let markers = (try? await ImmichClient.shared.mapMarkers()) ?? []
        let groups = Dictionary(grouping: markers.filter { $0.city != nil }) { $0.city! }
        places = groups.map { name, list in
            let lat = list.map(\.lat).reduce(0, +) / Double(list.count), lon = list.map(\.lon).reduce(0, +) / Double(list.count)
            return Place(id: name, name: name, coord: .init(latitude: lat, longitude: lon), count: list.count, sample: list[list.count / 2].id)
        }
    }
}

// MARK: - Duplikate

/// Doppelte Fotos (Immich erkennt sie per KI-Ähnlichkeit); „Zusammenführen“ behält den Vorschlag des Servers
/// (meist die größte Datei) und legt die anderen in „Zuletzt gelöscht“.
struct DuplicatesOverview: View {
    @Bindable var lib: Library
    @State private var groups: [DuplicateGroupDTO] = []
    @State private var loading = true
    @State private var busy = false

    var body: some View {
        Group {
            if loading { ProgressView() }
            else if groups.isEmpty { ContentUnavailableView("No Duplicates", systemImage: "square.on.square") }
            else {
                List {
                    Section {
                        ForEach(groups) { g in row(g) }
                    } header: {
                        HStack {
                            Text("\(groups.count == 1 ? "1 group" : "\(groups.count) groups"), \(extraText(groups.reduce(0) { $0 + $1.assets.count - 1 }))")
                            Spacer()
                            Button("Merge All") { Task { await mergeAll() } }
                                .disabled(!AccountStore.shared.canWrite || busy)
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    private func row(_ g: DuplicateGroupDTO) -> some View {
        let keep = Set(g.suggestedKeepAssetIds ?? [g.assets.first?.id].compactMap { $0 })
        return HStack(alignment: .top, spacing: 10) {
            ForEach(g.assets, id: \.id) { a in
                VStack(spacing: 4) {
                    Thumb(id: a.id).frame(width: 110, height: 110).clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(keep.contains(a.id) ? Color.green : .clear, lineWidth: 3))
                    Text(a.exifInfo?.fileSizeInByte.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")
                        .font(.caption2).foregroundStyle(.secondary)
                    if keep.contains(a.id) { Text("keep").font(.caption2).foregroundStyle(.green) }
                }
            }
            Spacer()
            Button("Merge") { Task { await merge(g) } }.disabled(!AccountStore.shared.canWrite || busy)
        }.padding(.vertical, 6)
    }

    private func load() async {
        groups = (try? await ImmichClient.shared.duplicates()) ?? []
        loading = false
    }

    private func merge(_ g: DuplicateGroupDTO) async {
        busy = true; defer { busy = false }
        let keep = g.suggestedKeepAssetIds ?? [g.assets.first?.id].compactMap { $0 }
        do { try await ImmichClient.shared.resolveDuplicate(g, keep: keep); groups.removeAll { $0.id == g.id } }
        catch { lib.error = error.localizedDescription }
    }

    private func mergeAll() async {
        let a = NSAlert()
        a.messageText = "Merge all \(groups.count) groups?"
        a.informativeText = "In each group the suggestion marked in green is kept; the others are moved to Recently Deleted."
        a.addButton(withTitle: "Merge"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for g in groups { await merge(g) }
        lib.status = "Duplicates merged"
    }
}

// MARK: - Personen bearbeiten

@MainActor
enum PeopleActions {
    static func menu(_ p: PersonDTO, lib: Library) -> some View {
        PersonContextMenu(person: p, lib: lib)
    }

    static func update(_ p: PersonDTO, _ fields: [String: Any], _ lib: Library) async {
        var updated = lib.people.first(where: { $0.id == p.id }) ?? p
        if let fav = fields["isFavorite"] as? Bool {
            updated.isFavorite = fav
        }
        if let name = fields["name"] as? String {
            updated = PersonDTO(id: updated.id, name: name, isHidden: updated.isHidden, isFavorite: updated.isFavorite, birthDate: updated.birthDate)
        }
        if let hidden = fields["isHidden"] as? Bool {
            updated = PersonDTO(id: updated.id, name: updated.name, isHidden: hidden, isFavorite: updated.isFavorite, birthDate: updated.birthDate)
        }
        lib.updatePerson(updated)

        let api = ImmichClient.shared, body = api.json(fields)
        do {
            let data = try await api.raw("people/\(p.id)", method: "PUT", body: body)
            if let serverPerson = try? ImmichClient.shared.decoder.decode(PersonDTO.self, from: data) {
                lib.updatePerson(serverPerson)
            }
            await lib.loadPeople()
        }
        catch {
            lib.error = error.localizedDescription
            await lib.loadPeople()
        }
    }

    static func merge(_ p: PersonDTO, into o: PersonDTO, _ lib: Library) async {
        let a = NSAlert()
        a.messageText = "Merge “\(p.name.isEmpty ? "Unnamed" : p.name)” with “\(o.name)”?"
        a.informativeText = "All photos of this person will then belong to “\(o.name)”."
        a.addButton(withTitle: "Merge"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try await ImmichClient.shared.mergePeople(into: o.id, [p.id]); await lib.loadPeople() }
        catch { lib.error = error.localizedDescription }
    }
}

struct PersonContextMenu: View {
    let person: PersonDTO
    @Bindable var lib: Library

    private var current: PersonDTO {
        lib.people.first(where: { $0.id == person.id }) ?? person
    }

    var body: some View {
        let p = current
        let w = AccountStore.shared.canWrite
        let isFav = p.isFavorite ?? false
        Group {
            Button(p.name.isEmpty ? "Add Name…" : "Rename…") {
                if let n = Menus.ask(p.name.isEmpty ? "Who Is This?" : "Rename Person", info: "", value: p.name) {
                    Task { await PeopleActions.update(p, ["name": n], lib) }
                }
            }.disabled(!w)
            Button(isFav ? "Unfavorite" : "Favorite") {
                Task { await PeopleActions.update(p, ["isFavorite": !isFav], lib) }
            }.disabled(!w)
            Menu("Merge with") {
                ForEach(lib.people.filter { $0.id != p.id && !$0.name.isEmpty }) { o in
                    Button(o.name) { Task { await PeopleActions.merge(p, into: o, lib) } }
                }
            }.disabled(!w)
            Divider()
            Button("Hide from People") { Task { await PeopleActions.update(p, ["isHidden": true], lib) } }.disabled(!w)
        }
    }
}

// MARK: - Intelligente Alben

/// Regel-Album wie Fotos (69 Bedingungen bei Apple, hier die, die der Server filtern kann). Gespeichert je Konto
/// auf dem Mac; der Inhalt kommt immer frisch vom Server (Metadaten-Suche).
struct SmartAlbum: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name = "Smart Album"
    var conditions: [Condition] = [Condition()]

    struct Condition: Codable, Hashable, Identifiable {
        var id = UUID().uuidString
        var field: Field = .favorite
        var text = ""
        var number = 30
        var date = Date()
        var date2 = Date()
        var flag = true
    }

    enum Field: String, Codable, CaseIterable {
        case favorite = "Favorit", photo = "Medienart: Foto", video = "Medienart: Video", live = "Live Photo"
        case lastDays = "Aufgenommen in den letzten … Tagen", between = "Aufgenommen zwischen"
        case person = "Person", city = "Ort (Stadt)", country = "Land", make = "Kamerahersteller", model = "Kameramodell"
        case lens = "Objektiv", filename = "Dateiname enthält", tag = "Schlagwort/Kategorie", hidden = "Ausgeblendet"

        /// Anzeigename (rawValue bleibt deutsch, steht in gespeicherten intelligenten Alben).
        var title: String {
            switch self {
            case .favorite: "Favorite"; case .photo: "Media Type: Photo"; case .video: "Media Type: Video"; case .live: "Live Photo"
            case .lastDays: "Taken in the Last … Days"; case .between: "Taken Between"
            case .person: "Person"; case .city: "Place (City)"; case .country: "Country"; case .make: "Camera Make"; case .model: "Camera Model"
            case .lens: "Lens"; case .filename: "Filename Contains"; case .tag: "Keyword/Category"; case .hidden: "Hidden"
            }
        }
    }

    /// Alle Bedingungen müssen zutreffen (Immich verknüpft Filter mit UND).
    var filter: [String: Any] {
        var f: [String: Any] = [:]
        let iso = ISO8601DateFormatter()
        for c in conditions {
            switch c.field {
            case .favorite: f["isFavorite"] = ["eq": c.flag]
            case .photo: f["type"] = ["eq": "IMAGE"]
            case .video: f["type"] = ["eq": "VIDEO"]
            case .live: f["isMotion"] = ["eq": c.flag]
            case .lastDays: f["takenAt"] = ["gte": iso.string(from: Date().addingTimeInterval(-Double(c.number) * 86400))]
            case .between: f["takenAt"] = ["gte": iso.string(from: Calendar.current.startOfDay(for: c.date)),
                                           "lt": iso.string(from: Calendar.current.startOfDay(for: c.date2).addingTimeInterval(86400))]
            case .person: if !c.text.isEmpty { f["personIds"] = ["all": c.text.split(separator: ",").map(String.init)] }
            case .city: if !c.text.isEmpty { f["city"] = ["eq": c.text] }
            case .country: if !c.text.isEmpty { f["country"] = ["eq": c.text] }
            case .make: if !c.text.isEmpty { f["make"] = ["eq": c.text] }
            case .model: if !c.text.isEmpty { f["model"] = ["eq": c.text] }
            case .lens: if !c.text.isEmpty { f["lensModel"] = ["eq": c.text] }
            case .filename: if !c.text.isEmpty { f["originalFileName"] = ["like": "%\(c.text)%"] }
            case .tag: if !c.text.isEmpty { f["tagIds"] = ["any": [c.text]] }
            case .hidden: f["visibility"] = ["eq": c.flag ? "archive" : "timeline"]
            }
        }
        return f
    }
}

@MainActor @Observable
final class SmartAlbums {
    static let shared = SmartAlbums()
    private(set) var albums: [SmartAlbum] = []
    private var key: String { "mac.smartAlbums.\(AccountStore.shared.currentID ?? "-")" }

    init() { reload() }
    func reload() {
        albums = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([SmartAlbum].self, from: $0) } ?? []
    }
    func save(_ a: SmartAlbum) {
        if let i = albums.firstIndex(where: { $0.id == a.id }) { albums[i] = a } else { albums.append(a) }
        UserDefaults.standard.set(try? JSONEncoder().encode(albums), forKey: key)
    }
    func delete(_ id: String) {
        albums.removeAll { $0.id == id }
        UserDefaults.standard.set(try? JSONEncoder().encode(albums), forKey: key)
    }
}

/// Regel-Editor („Neues intelligentes Album“ ⌥⌘N).
struct SmartAlbumEditor: View {
    @State var album: SmartAlbum
    let onDone: (SmartAlbum?) -> Void
    @State private var people: [PersonDTO] = []
    @State private var tags: [TagDTO] = []
    @State private var preview: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Smart Album Name", text: $album.name).textFieldStyle(.roundedBorder).font(.title3)
            Text("Match all of the following conditions:").font(.callout).foregroundStyle(.secondary)
            ForEach($album.conditions) { $c in
                HStack {
                    Picker("", selection: $c.field) { ForEach(SmartAlbum.Field.allCases, id: \.self) { Text($0.title).tag($0) } }
                        .labelsHidden().frame(width: 260)
                    value($c)
                    Spacer()
                    Button { album.conditions.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).disabled(album.conditions.count == 1)
                    Button { album.conditions.append(SmartAlbum.Condition()) } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                if let preview { Text(preview == 1 ? "1 item matches" : "\(preview) items match").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") { onDone(album) }.keyboardShortcut(.defaultAction).disabled(album.name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task {
            people = ((try? await ImmichClient.shared.people()) ?? []).filter { !$0.name.isEmpty }
            tags = ((try? await ImmichClient.shared.tags()) ?? []).sorted { $0.value < $1.value }
        }
        .task(id: album.conditions) {
            try? await Task.sleep(for: .milliseconds(400))
            preview = (try? await ImmichClient.shared.search(filter: album.filter, size: 1000))?.count
        }
    }

    @ViewBuilder private func value(_ c: Binding<SmartAlbum.Condition>) -> some View {
        switch c.wrappedValue.field {
        case .favorite, .live, .hidden:
            Picker("", selection: c.flag) { Text("Yes").tag(true); Text("No").tag(false) }.labelsHidden().frame(width: 90)
        case .photo, .video: EmptyView()
        case .lastDays:
            TextField("Days", value: c.number, format: .number).frame(width: 70)
        case .between:
            DatePicker("", selection: c.date, displayedComponents: .date).labelsHidden()
            Text("–")
            DatePicker("", selection: c.date2, displayedComponents: .date).labelsHidden()
        case .person:
            Picker("", selection: c.text) {
                Text("Choose…").tag("")
                ForEach(people) { Text($0.name).tag($0.id) }
            }.labelsHidden().frame(width: 200)
        case .tag:
            Picker("", selection: c.text) {
                Text("Choose…").tag("")
                ForEach(tags, id: \.id) { Text($0.value).tag($0.id) }
            }.labelsHidden().frame(width: 220)
        default:
            TextField("Value", text: c.text).frame(width: 200)
        }
    }
}

@MainActor
enum SmartAlbumWindow {
    private static var window: NSWindow?
    static func show(_ album: SmartAlbum = SmartAlbum()) {
        window?.close()
        let w = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Smart Album"
        w.contentView = NSHostingView(rootView: SmartAlbumEditor(album: album) { result in
            if let result {
                SmartAlbums.shared.save(result)
                Library.shared.source = .library
                Library.shared.select(.smart(result.id, result.name))
            }
            window?.close(); window = nil
        })
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
