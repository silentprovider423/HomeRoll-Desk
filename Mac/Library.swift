import AppKit
import Foundation
import Network

/// Was gerade im Raster steht – Einträge der Seitenleiste wie in Apple Fotos (macOS 15, siehe MAC-PLAN.md §2).
enum Source: Hashable {
    case library, recentlySaved, favorites, videos, livePhotos, hidden, trash
    case category(String)                  // Server-Tag „Kategorie/<name>“ (Kategorien-Add-on aus dem HomeRoll-Repo, server/)
    case album(String, String)             // ID, Name
    case person(String, String)            // ID, Name
    case search(String)
    case memory(String, String)            // Rückblick: ID, Titel
    case city(String)                      // Ort aus der Karte
    case smart(String, String)             // intelligentes Album: ID, Name
    case people, albums, memories, map, duplicates   // Übersichten (eigene Ansicht, kein Foto-Raster)

    var title: String {
        switch self {
        case .library: "Library"; case .recentlySaved: "Recently Saved"; case .favorites: "Favorites"
        case .videos: "Videos"; case .livePhotos: "Live Photos"; case .hidden: "Hidden"; case .trash: "Recently Deleted"
        case .category(let n): Self.displayName(tag: n); case .album(_, let n): n; case .person(_, let n): n.isEmpty ? "Unnamed" : n
        case .search(let q): "Search: “\(q)”"; case .people: "People"; case .albums: "Albums"
        case .memory(_, let t): t; case .city(let c): c; case .smart(_, let n): n
        case .memories: "Memories"; case .map: "Map"; case .duplicates: "Duplicates"
        }
    }
    var isOverview: Bool { [.people, .albums, .memories, .map, .duplicates].contains(self) }

    /// Medienarten, die der Kategorien-Dienst als Tag setzt (gleiche Namen wie Category.tag der iPhone-App).
    static let mediaTags = ["Selfies", "Porträt", "Panoramen", "Zeitraffer", "Slo-Mo", "Kino", "Serien",
                            "Bildschirmfotos", "Bildschirmaufnahmen", "Animiert", "RAW"]
    static let otherTags = ["Belege", "Dokumente", "Handschrift", "Illustrationen", "QR-Codes", "Importe"]
    /// Anzeigename eines Kategorien-Tags (der Tag-Name selbst bleibt deutsch, so steht er auf dem Server).
    static func displayName(tag: String) -> String {
        switch tag {
        case "Porträt": "Portrait"; case "Panoramen": "Panoramas"; case "Zeitraffer": "Time-lapse"; case "Slo-Mo": "Slo-mo"
        case "Kino": "Cinematic"; case "Serien": "Bursts"; case "Bildschirmfotos": "Screenshots"; case "Bildschirmaufnahmen": "Screen Recordings"
        case "Animiert": "Animated"; case "Belege": "Receipts"; case "Dokumente": "Documents"; case "Handschrift": "Handwriting"
        case "Illustrationen": "Illustrations"; case "QR-Codes": "QR Codes"; case "Importe": "Imports"
        default: tag
        }
    }
    static func icon(tag: String) -> String {
        switch tag {
        case "Selfies": "person.crop.square"; case "Porträt": "f.cursive.circle"; case "Panoramen": "pano"
        case "Zeitraffer": "timelapse"; case "Slo-Mo": "slowmo"; case "Kino": "film"; case "Serien": "square.stack.3d.down.right"
        case "Bildschirmfotos": "camera.viewfinder"; case "Bildschirmaufnahmen": "record.circle"
        case "Animiert": "square.stack.3d.forward.dottedline"; case "RAW": "r.square.on.square"
        case "Belege": "doc.text"; case "Dokumente": "doc"; case "Handschrift": "pencil.and.scribble"
        case "Illustrationen": "scribble.variable"; case "QR-Codes": "qrcode"; case "Importe": "square.and.arrow.down.on.square"
        default: "tag"
        }
    }
}

/// Ein Monat (Mediathek: erst beim Hinscrollen vom Server geladen) oder eine Ergebnisgruppe.
struct GridSection: Identifiable {
    let id: String
    let title: String
    var count: Int
    var bucket: String?          // nur Mediathek: Monat für GET /timeline/bucket
    var assets: [Asset]?         // nil = noch nicht geladen
}

@MainActor @Observable
final class Library {
    static let shared = Library()
    let api = ImmichClient.shared

    var source: Source = .library
    private(set) var sections: [GridSection] = []
    private(set) var loading = false
    var error: String?
    /// Auswahl (IDs) und das zuletzt angeklickte Objekt (für ⌘I und die Einzelansicht)
    var selection: Set<String> = []
    var focused: Asset?
    var viewer: IndexPath?
    /// Zoomstufe des Rasters (Kantenlänge in Punkt), ⌘+ / ⌘−
    static let zoomSizes: [CGFloat] = [72, 104, 150, 210, 300]
    /// Monat oben im Raster (mitlaufende Kapsel, GitHub #7)
    var gridTitle = ""
    var zoom = UserDefaults.standard.object(forKey: "mac.zoom") as? Int ?? 2 { didSet { UserDefaults.standard.set(zoom, forKey: "mac.zoom") } }

    /// Mediathek wie Fotos: Jahre · Monate · Alle Fotos
    enum Granularity: String, CaseIterable { case years = "Years", months = "Months", all = "All Photos" }
    var granularity: Granularity = .all

    /// Gerade im Editor (ersetzt Raster/Einzelansicht)
    var editing: Asset?

    var albums: [AlbumDTO] = []
    var people: [PersonDTO] = []
    var memories: [MemoryDTO] = []
    var lastAlbumID: String? = UserDefaults.standard.string(forKey: "mac.lastAlbum") {
        didSet { UserDefaults.standard.set(lastAlbumID, forKey: "mac.lastAlbum") }
    }
    var status: String?            // Fortschritt (Import/Export) für die Symbolleiste
    var fileNames: [String: String] = [:]

    /// Das Raster (NSCollectionView) meldet sich hier an, um gezielt neu zu zeichnen.
    @ObservationIgnored var onReloadAll: (() -> Void)?
    @ObservationIgnored var onReloadSection: ((Int) -> Void)?
    @ObservationIgnored var onReloadItems: (([IndexPath]) -> Void)?
    @ObservationIgnored var onScrollToEnd: (() -> Void)?
    @ObservationIgnored var onScrollToSection: ((Int) -> Void)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inflight: Set<Int> = []
    @ObservationIgnored private var index: [String: IndexPath] = [:]
    @ObservationIgnored private var tagIDs: [String: String] = [:]
    /// Zu welcher Ansicht `sections` gerade gehört (bei Verbindungsaussetzern bleibt das Raster dann stehen)
    @ObservationIgnored private var sectionsSource: Source?
    /// Laden scheiterte an der Verbindung (kurzer WLAN-Aussetzer, Aufwachen, Server weg …) → kein Fehlerfenster,
    /// sondern Hinweis in der Symbolleiste und in der Fußzeile; die App versucht es selbst neu (2/5/15 s, danach
    /// jede Minute, sofort wenn das Netz zurück ist oder der Mac aufwacht). Fehler bei Aktionen bleiben Fenster.
    private(set) var offline = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    // MARK: Laden

    /// Aus Jahre/Monate in „Alle Fotos“ springen, an den Anfang dieses Monats.
    func jump(to section: Int) {
        granularity = .all
        ensureLoaded(section)
        DispatchQueue.main.async { self.onScrollToSection?(section) }
    }

    /// Zurück wie in Photos (GitHub-Issue HomeRoll-Desk #3): aus einer Übersicht (Alben, Personen, Rückblicke, Karte)
    /// Geöffnetes merkt sich, woher es kam. Ein Klick in der Seitenleiste fängt neu an.
    private(set) var backStack: [Source] = []
    var canGoBack: Bool { !backStack.isEmpty }

    /// Aus einer Übersicht hinein (Album, Person, Rückblick, Ort) – mit Zurück-Weg.
    func open(_ s: Source) {
        guard s != source else { return }
        backStack.append(source)
        select(s, keepHistory: true)
    }

    func goBack() {
        guard viewer == nil, let s = backStack.popLast() else { return }
        select(s, keepHistory: true)
    }

    func select(_ s: Source, keepHistory: Bool = false) {
        if !keepHistory { backStack = [] }
        if s != .library { granularity = .all }
        guard s != source || sections.isEmpty else { return }
        source = s
        viewer = nil
        selection = []
        focused = nil
        Task { await load() }
    }

    func reset() {
        generation += 1
        sections = []; index = [:]; selection = []; focused = nil; viewer = nil; albums = []; people = []; memories = []
        SmartAlbums.shared.reload()
        tagIDs = [:]; fileNames = [:]; source = .library; sectionsSource = nil
        onReloadAll?()
    }

    /// `keepCurrent`: Neuversuch nach einem Verbindungsaussetzer – Raster nicht erst leeren (kein Flackern).
    func load(keepCurrent: Bool = false) async {
        generation += 1
        let g = generation
        let previous = sectionsSource == source ? sections : []
        if !keepCurrent {
            sections = []; index = [:]; sectionsSource = nil
            onReloadAll?()
        }
        inflight = []; error = nil
        guard ImmichClient.shared.isLoggedIn else { return }
        if source == .albums || albums.isEmpty { await loadAlbums() }
        if source == .people { await loadPeople(); return }
        if source == .memories { memories = (try? await api.memories()) ?? []; return }
        if source == .map || source == .duplicates || source == .albums { return }   // eigene Ansichten laden selbst
        loading = true
        defer { if g == generation { loading = false } }
        do {
            #if DEBUG
            // Lasttest ohne Server: FOTOS_FAKE=<Anzahl> erzeugt eine künstliche Mediathek (Monate à gleich viele Objekte)
            if source == .library, let n = Int(ProcessInfo.processInfo.environment["FOTOS_FAKE"] ?? "") {
                let months = 120, per = n / months
                sections = (0..<months).map { m in
                    let d = Calendar.wall.date(byAdding: .month, value: m - months, to: Date())!
                    return GridSection(id: "fake-\(m)", title: Fmt.monthYear.string(from: d), count: per, bucket: "fake-\(m)", assets: nil)
                }
                rebuildIndex(); onReloadAll?(); onScrollToEnd?()
                return
            }
            #endif
            if source == .library {
                let d = try await api.bucketsData()
                let buckets = try JSONDecoder().decode([TimeBucket].self, from: d)
                guard g == generation else { return }
                sections = buckets.sorted { $0.timeBucket < $1.timeBucket }.map {
                    GridSection(id: $0.timeBucket, title: Fmt.monthYear.string(from: $0.monthDate), count: $0.count,
                                bucket: $0.timeBucket, assets: nil)
                }
            } else {
                let list = try await fetch(source)
                guard g == generation else { return }
                if case .search(let q) = source {
                    sections = [GridSection(id: "q", title: "\(list.count == 1 ? "1 result" : "\(list.count) results") for “\(q)”", count: list.count, assets: list)]
                } else {
                    sections = Self.byMonth(list)
                }
            }
            sectionsSource = source
            rebuildIndex()
            onReloadAll?()
            if !keepCurrent || previous.isEmpty { onScrollToEnd?() }
            if offline { connectionBack() }
        } catch {
            guard g == generation else { return }
            if Self.isConnectionError(error) {
                // Raster von vorher stehen lassen (gleiche Ansicht), statt eine leere Mediathek zu zeigen
                if sections.isEmpty, !previous.isEmpty {
                    sections = previous; sectionsSource = source
                    rebuildIndex(); onReloadAll?(); onScrollToEnd?()
                }
                offline = true
                status = "Offline – retrying…"
                scheduleRetry()
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Verbindung

    static func isConnectionError(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed].contains(e.code)
    }

    private func connectionBack() {
        offline = false
        retryTask?.cancel(); retryTask = nil
        if status?.hasPrefix("Offline") == true { status = nil }
    }

    private func scheduleRetry() {
        startConnectivityWatch()
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let delay = attempt < 3 ? [2, 5, 15][attempt] : 60
                attempt += 1
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.offline else { break }
                await self.load(keepCurrent: true)
                if !self.offline { break }
            }
            self?.retryTask = nil
        }
    }

    /// Einmalig: Netz zurück bzw. Mac aufgewacht → sofort neu laden, wenn gerade offline.
    private func startConnectivityWatch() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                let lib = Library.shared
                if lib.offline { await lib.load(keepCurrent: true) }
            }
        }
        m.start(queue: DispatchQueue(label: "org.homeroll.desktop.network"))
        pathMonitor = m
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                // nach dem Aufwachen braucht das WLAN einen Moment
                try? await Task.sleep(for: .seconds(3))
                let lib = Library.shared
                if lib.offline { await lib.load(keepCurrent: true) }
            }
        }
    }

    private func fetch(_ s: Source) async throws -> [Asset] {
        func f(_ filter: [String: Any], _ size: Int = 5000) async throws -> [Asset] {
            try await api.search(filter: filter, size: size).map(\.asset)
        }
        switch s {
        case .favorites: return try await f(["isFavorite": ["eq": true]])
        case .videos: return try await f(["type": ["eq": "VIDEO"]])
        case .livePhotos: return try await f(["isMotion": ["eq": true]])
        case .hidden: return try await f(["visibility": ["eq": "archive"]])
        case .trash: return try await f(["trashedAt": ["ne": NSNull()]])
        case .recentlySaved:
            let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 86400))
            return try await f(["createdAt": ["gte": since]], 1000)
        case .category(let name):
            guard let id = await tagID(name) else { return [] }
            return try await f(["tagIds": ["any": [id]]])
        case .album(let id, _): return try await api.albumAssets(id).map(\.asset)
        case .person(let id, _): return try await f(["personIds": ["any": [id]]])
        case .search(let q): return try await api.smartSearch(q, size: 400).map(\.asset)
        case .memory(let id, _):
            if memories.isEmpty { memories = (try? await api.memories()) ?? [] }
            return memories.first { $0.id == id }?.assets.map(\.asset) ?? []
        case .city(let c): return try await f(["city": ["eq": c]])
        case .smart(let id, _):
            guard let sa = SmartAlbums.shared.albums.first(where: { $0.id == id }) else { return [] }
            return try await f(sa.filter, 5000)
        case .library, .people, .albums, .memories, .map, .duplicates: return []
        }
    }

    private func tagID(_ name: String) async -> String? {
        if tagIDs["Kategorie/\(name)"] == nil {
            for t in (try? await api.tags()) ?? [] { tagIDs[t.value] = t.id }
        }
        return tagIDs["Kategorie/\(name)"]
    }

    static func byMonth(_ list: [Asset]) -> [GridSection] {
        let cal = Calendar.wall
        let groups = Dictionary(grouping: list.sorted { $0.date < $1.date }) { cal.dateInterval(of: .month, for: $0.date)?.start ?? $0.date }
        return groups.keys.sorted().map { k in
            let a = groups[k]!
            return GridSection(id: "\(k.timeIntervalSince1970)", title: Fmt.monthYear.string(from: k), count: a.count, assets: a)
        }
    }

    /// Monat der Mediathek nachladen (sobald er ins Bild kommt).
    func ensureLoaded(_ s: Int) {
        guard sections.indices.contains(s), sections[s].assets == nil, let b = sections[s].bucket, !inflight.contains(s) else { return }
        inflight.insert(s)
        let g = generation
        Task {
            defer { inflight.remove(s) }
            #if DEBUG
            if b.hasPrefix("fake-") {
                let base = Calendar.wall.date(byAdding: .month, value: s - sections.count, to: Date())!
                var assets: [Asset] = []
                for i in 0..<sections[s].count {
                    let video = i % 17 == 0
                    let when = base.addingTimeInterval(Double(i) * 600)
                    assets.append(Asset(id: "\(b)-\(i)", isImage: !video, isFavorite: i % 23 == 0, date: when, ratio: 1,
                                        durationMs: video ? 12000 : nil, livePhotoVideoId: nil, city: nil, country: nil))
                }
                guard g == generation else { return }
                sections[s].assets = assets
                for (i, a) in assets.enumerated() { index[a.id] = IndexPath(item: i, section: s) }
                onReloadSection?(s)
                return
            }
            #endif
            guard let d = try? await api.bucketData(b) else { return }
            let assets = await Task.detached { ImmichClient.decodeBucket(d) ?? [] }.value
            guard g == generation, sections.indices.contains(s) else { return }
            sections[s].assets = assets
            sections[s].count = assets.count
            for (i, a) in assets.enumerated() { index[a.id] = IndexPath(item: i, section: s) }
            onReloadSection?(s)
        }
    }

    func loadAlbums() async { albums = ((try? await api.albums()) ?? []).sorted { $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending } }
    /// Benannte zuerst (wie Fotos), unbenannte dahinter.
    func loadPeople() async {
        let p = (try? await api.people()) ?? []
        var merged = p
        for local in people {
            if let idx = merged.firstIndex(where: { $0.id == local.id }) {
                if merged[idx].isFavorite == nil {
                    merged[idx].isFavorite = local.isFavorite
                }
            } else {
                merged.append(local)
            }
        }
        people = merged.filter { !$0.name.isEmpty } + merged.filter { $0.name.isEmpty }
    }

    func updatePerson(_ p: PersonDTO) {
        if let idx = people.firstIndex(where: { $0.id == p.id }) {
            var curr = people[idx]
            if !p.name.isEmpty {
                curr = PersonDTO(id: curr.id, name: p.name, isHidden: curr.isHidden, isFavorite: curr.isFavorite, birthDate: curr.birthDate)
            }
            if let fav = p.isFavorite {
                curr.isFavorite = fav
            }
            if let hidden = p.isHidden {
                curr = PersonDTO(id: curr.id, name: curr.name, isHidden: hidden, isFavorite: curr.isFavorite, birthDate: curr.birthDate)
            }
            people[idx] = curr
        } else {
            people.append(p)
        }
    }

    private func rebuildIndex() {
        index = [:]
        for (s, sec) in sections.enumerated() {
            for (i, a) in (sec.assets ?? []).enumerated() { index[a.id] = IndexPath(item: i, section: s) }
        }
    }

    // MARK: Zugriff

    func asset(at p: IndexPath) -> Asset? {
        guard sections.indices.contains(p.section), let a = sections[p.section].assets, a.indices.contains(p.item) else { return nil }
        return a[p.item]
    }
    func asset(_ id: String) -> Asset? { index[id].flatMap(asset(at:)) }
    func indexPath(_ id: String) -> IndexPath? { index[id] }
    var selectedAssets: [Asset] { selection.compactMap(asset(_:)).sorted { $0.date < $1.date } }
    /// Aktionen wirken auf die Auswahl, in der Einzelansicht auf das gezeigte Foto.
    var targets: [Asset] {
        if let v = viewer, let a = asset(at: v) { return [a] }
        return selectedAssets
    }
    var totalCount: Int { sections.reduce(0) { $0 + $1.count } }

    /// Nächstes/vorheriges Objekt über Monatsgrenzen (lädt den Nachbarmonat bei Bedarf).
    func step(_ p: IndexPath, by d: Int) -> IndexPath? {
        var s = p.section, i = p.item + d
        while sections.indices.contains(s) {
            if i >= 0 && i < sections[s].count { ensureLoaded(s); return IndexPath(item: i, section: s) }
            s += d > 0 ? 1 : -1
            guard sections.indices.contains(s) else { return nil }
            i = d > 0 ? 0 : sections[s].count - 1
        }
        return nil
    }

    func open(_ p: IndexPath) {
        guard let a = asset(at: p) else { return }
        focused = a
        selection = [a.id]
        viewer = p
    }
    func closeViewer() {
        if let v = viewer { onReloadItems?([v]) }
        viewer = nil
    }

    // MARK: Änderungen (nur wenn das Konto nicht auf „Nur ansehen“ steht)

    private var canWrite: Bool { AccountStore.shared.canWrite }

    private func mutate(_ ids: [String], _ change: (inout Asset) -> Void) {
        var paths: [IndexPath] = []
        for id in ids {
            guard let p = index[id], var list = sections[p.section].assets else { continue }
            change(&list[p.item]); sections[p.section].assets = list; paths.append(p)
            if focused?.id == id { focused = list[p.item] }
        }
        onReloadItems?(paths)
    }

    /// Objekte aus der aktuellen Ansicht nehmen (ausgeblendet, gelöscht, aus Album entfernt …).
    private func removeLocally(_ ids: Set<String>) {
        for s in sections.indices {
            guard let a = sections[s].assets else { continue }
            let kept = a.filter { !ids.contains($0.id) }
            if kept.count != a.count { sections[s].assets = kept; sections[s].count = kept.count }
        }
        sections.removeAll { $0.assets != nil && $0.count == 0 }
        selection.subtract(ids)
        if let v = viewer, let a = asset(at: v), ids.contains(a.id) { viewer = nil }
        rebuildIndex()
        onReloadAll?()
    }

    func toggleFavorite() async {
        let t = targets; guard canWrite, !t.isEmpty else { return }
        let v = !t.allSatisfy(\.isFavorite)
        do {
            try await api.update(t.map(\.id), ["isFavorite": v])
            mutate(t.map(\.id)) { $0.isFavorite = v }
            if source == .favorites && !v { removeLocally(Set(t.map(\.id))) }
        } catch { self.error = error.localizedDescription }
    }

    func toggleHidden() async {
        let t = targets; guard canWrite, !t.isEmpty else { return }
        let unhide = source == .hidden
        do {
            try await api.update(t.map(\.id), ["visibility": unhide ? "timeline" : "archive"])
            removeLocally(Set(t.map(\.id)))
        } catch { self.error = error.localizedDescription }
    }

    func trash() async {
        let t = targets; guard canWrite, !t.isEmpty, source != .trash else { return }
        do { try await api.trash(t.map(\.id)); removeLocally(Set(t.map(\.id))) }
        catch { self.error = error.localizedDescription }
    }

    func restore() async {
        let t = targets; guard canWrite, !t.isEmpty, source == .trash else { return }
        do { try await api.restore(t.map(\.id)); removeLocally(Set(t.map(\.id))) }
        catch { self.error = error.localizedDescription }
    }

    func deleteForever() async {
        let t = targets; guard canWrite, !t.isEmpty, source == .trash else { return }
        do { try await api.deleteForever(t.map(\.id)); removeLocally(Set(t.map(\.id))) }
        catch { self.error = error.localizedDescription }
    }

    func addToAlbum(_ id: String) async {
        let t = targets; guard canWrite, !t.isEmpty else { return }
        do {
            try await api.addToAlbum(id, t.map(\.id))
            lastAlbumID = id
            await loadAlbums()
        } catch { self.error = error.localizedDescription }
    }

    /// `assets` nil = die Auswahl kommt mit ins Album (wie Fotos), [] = leeres Album (aus der Alben-Übersicht)
    func createAlbum(_ name: String, assets: [String]? = nil) async {
        guard canWrite, !name.isEmpty else { return }
        do {
            let a = try await api.createAlbum(name, assets ?? targets.map(\.id))
            lastAlbumID = a.id
            await loadAlbums()
        } catch { self.error = error.localizedDescription }
    }

    func removeFromAlbum() async {
        guard canWrite, case .album(let id, _) = source else { return }
        let t = targets; guard !t.isEmpty else { return }
        do { try await api.removeFromAlbum(id, t.map(\.id)); removeLocally(Set(t.map(\.id))) }
        catch { self.error = error.localizedDescription }
    }

    /// Ausgewähltes Foto als Albumcover („Make Key Photo“ wie bei Apple) – auch in der Seitenleiste zu sehen.
    func makeKeyPhoto() async {
        guard canWrite, case .album(let id, _) = source, let a = targets.first, targets.count == 1 else { return }
        do { try await api.updateAlbum(id, ["albumThumbnailAssetId": a.id]); await loadAlbums() }
        catch { self.error = error.localizedDescription }
    }

    func deleteAlbum(_ id: String) async {
        guard canWrite else { return }
        do {
            try await api.deleteAlbum(id)
            if case .album(let cur, _) = source, cur == id { select(.library) }
            await loadAlbums()
        } catch { self.error = error.localizedDescription }
    }

    func renameAlbum(_ id: String, _ name: String) async {
        guard canWrite, !name.isEmpty else { return }
        try? await api.updateAlbum(id, ["albumName": name])
        await loadAlbums()
    }

    /// Drehen über die Server-Bearbeitung (nicht-destruktiv, Zuschnitt/Spiegeln bleiben). Uhrzeigersinn = +90°.
    func rotate(clockwise: Bool) async {
        let t = targets.filter(\.isImage); guard canWrite, !t.isEmpty else { return }
        for a in t {
            var edits: [[String: Any]] = []
            if let d = try? await api.raw("assets/\(a.id)/edits"),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let e = o["edits"] as? [[String: Any]] {
                edits = e.map { ["action": $0["action"] ?? "", "parameters": $0["parameters"] ?? [:]] }
            }
            var angle = 0
            if let i = edits.firstIndex(where: { $0["action"] as? String == "rotate" }) {
                angle = ((edits[i]["parameters"] as? [String: Any])?["angle"] as? Int) ?? 0
                edits.remove(at: i)
            }
            angle = (angle + (clockwise ? 90 : 270)) % 360
            if angle != 0 {
                // Reihenfolge wie vom Server verlangt: Zuschnitt zuerst, dann Drehen, dann Spiegeln
                let at = edits.firstIndex(where: { $0["action"] as? String == "mirror" }) ?? edits.count
                edits.insert(["action": "rotate", "parameters": ["angle": angle]], at: at)
            }
            do {
                if edits.isEmpty { try await api.removeEdits(a.id) }
                else { let body = api.json(["edits": edits]); try await api.raw("assets/\(a.id)/edits", method: "PUT", body: body) }
                ImageCache.shared.bump(a.id)
            } catch { self.error = error.localizedDescription }
        }
        // Server rechnet neue Vorschauen; kurz warten, dann neu zeichnen
        try? await Task.sleep(for: .seconds(2))
        for a in t { ImageCache.shared.bump(a.id) }
        mutate(t.map(\.id)) { _ in }
    }

    // MARK: Bearbeiten

    func edit() {
        guard AccountStore.shared.canWrite, let a = targets.first(where: \.isImage) else { return }
        editing = a
    }

    /// Nach dem Sichern: Monat neu laden (neue Fassung ersetzt das Original im Stapel) und sie zeigen.
    func afterEdit(old: Asset, new: Asset) async {
        editing = nil
        ImageCache.shared.bump(old.id); ImageCache.shared.bump(new.id)
        if let p = index[old.id], sections[p.section].bucket != nil {
            sections[p.section].assets = nil
            inflight.remove(p.section)
            ensureLoaded(p.section)
            for _ in 0..<40 where sections[p.section].assets == nil { try? await Task.sleep(for: .milliseconds(100)) }
        } else {
            await load()
        }
        if let np = index[new.id] ?? index[old.id] {
            selection = [new.id]; focused = asset(at: np)
            if viewer != nil { viewer = np }
        }
        onReloadAll?()
    }

    /// „Änderungen kopieren“ (⇧⌘C): Licht/Farbe/Filter/Stil des Fotos merken (gleiche Ablage wie am iPhone).
    func copyEdits() async {
        guard let a = targets.first(where: \.isImage) else { return }
        let s = EditSession(asset: a)
        await s.load()
        status = EditClipboard.copy(s.state) ? "Edits copied" : "This photo has no light or color adjustments"
    }

    /// „Änderungen einsetzen“ (⇧⌘V): auf jedes ausgewählte Foto rechnen und als bearbeitete Fassung sichern.
    func pasteEdits() async {
        guard canWrite, let clip = EditClipboard.current else { return }
        let photos = targets.filter(\.isImage)
        var done = 0
        for (i, a) in photos.enumerated() {
            status = "Pasting edits \(i + 1) of \(photos.count)…"
            let s = EditSession(asset: a)
            await s.load()
            guard s.error == nil, let base = s.base else { continue }
            EditClipboard.apply(clip, to: &s.state) { s.renderer.autoValues(for: base) }
            if (try? await s.save()) != nil { done += 1 }
        }
        status = done == 1 ? "Edits pasted" : "Edits pasted to \(done) photos"
        await load()
    }

    /// Dateinamen für Ziehen/Export (vom Server, gemerkt).
    func fileName(_ a: Asset) async -> String {
        if let n = fileNames[a.id] { return n }
        // Dateiname kommt vom Server (auch aus geteilten Alben): säubern, sonst könnte „../../“ beim Export oder Ziehen
        // in den Finder außerhalb des gewählten Ordners schreiben (HomeRoll-Issue #9)
        let n = safeFilename((try? await api.asset(a.id))?.originalFileName ?? "", fallback: "\(a.id).\(a.isVideo ? "mov" : "jpg")")
        fileNames[a.id] = n
        return n
    }
}
