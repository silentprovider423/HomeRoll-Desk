import AppKit
import AVKit
import CoreLocation
import MapKit
import SwiftUI
import Vision

/// Einzelansicht im selben Fenster (wie IPXOneUpViewerController): Leertaste/Esc/⌘↑ zurück, ←/→ blättern,
/// „.“ Favorit, ⌘I Infos. Erst die schnelle Vorschau, dann die volle Auflösung.
struct ViewerView: View {
    @Bindable var lib: Library
    let path: IndexPath
    @State private var live: LiveMode = .live
    @State private var hoverPlay = false
    @State private var isZoomed = false
    @State private var isUnlocked = false
    @State private var hasScrolledDown = false
    @State private var videoPlayer: AVPlayer?
    @State private var videoRatio: Double?
    @State private var resistanceDelta: CGFloat = 0
    @State private var peekOffset: CGFloat = 0
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        let a = lib.asset(at: path)
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let a {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            Group {
                                if a.isVideo {
                                    let r = videoRatio ?? (a.ratio > 0 ? a.ratio : (16.0 / 9.0))
                                    ZStack {
                                        Color(nsColor: .windowBackgroundColor)
                                        VideoPlayerView(asset: a, player: $videoPlayer, naturalRatio: $videoRatio)
                                            .aspectRatio(r, contentMode: .fit)
                                    }
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .background(Color(nsColor: .windowBackgroundColor))
                                    .id(a.id)
                                } else {
                                    StillView(asset: a, isZoomed: $isZoomed, live: $live, hoverPlay: hoverPlay)
                                        .frame(width: geo.size.width, height: geo.size.height)
                                        .id(a.id)
                                }
                            }

                            ViewerDetailsView(asset: a, lib: lib)
                                .frame(width: geo.size.width)
                                .background(Color(nsColor: .windowBackgroundColor))
                        }
                        .offset(y: peekOffset)
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { g in
                        g.contentOffset.y
                    } action: { oldOffset, newOffset in
                        if newOffset > 10 {
                            hasScrolledDown = true
                        } else if newOffset <= 8.0 && (hasScrolledDown || (isUnlocked && newOffset < oldOffset)) {
                            isUnlocked = false
                            hasScrolledDown = false
                            resistanceDelta = 0
                            peekOffset = 0
                            if a.isVideo {
                                if let item = videoPlayer?.currentItem, item.duration.isValid, item.currentTime() >= item.duration {
                                    videoPlayer?.seek(to: .zero)
                                }
                                videoPlayer?.play()
                            }
                        }
                    }
                    .scrollDisabled(isZoomed)
                    .id(a.id)
                } else { ProgressView() }
                KeyCatcher { key in handle(key) }.frame(width: 0, height: 0)
            }
            .overlay(alignment: .top) {
                if let a {
                    HStack(spacing: 14) {
                        Button { lib.closeViewer() } label: { Image(systemName: "chevron.left") }.help("Back (Space)")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Fmt.relativeDay(a.date, fallback: Fmt.dayLongMonthYear)).font(.headline)
                            Text([Fmt.time.string(from: a.date), a.city].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await lib.toggleFavorite() } } label: {
                            Image(systemName: a.isFavorite ? "heart.fill" : "heart")
                        }.disabled(!AccountStore.shared.canWrite).help("Favorite (.)")
                        Button { InfoWindow.show() } label: { Image(systemName: "info.circle") }.help("Info (⌘I)")
                        if a.isImage {
                            Button("Edit") { lib.edit() }.disabled(!AccountStore.shared.canWrite).help("Edit (↩)")
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.title3)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if let a, a.isLivePhoto, a.isImage {
                LiveBadge(mode: live, onHover: { hoverPlay = $0 && live == .live }) { m in
                    live = m; LiveMode.set(m, for: a.id); hoverPlay = false
                }
                .padding(.leading, 16).padding(.top, 62)
            }
        }
        .onAppear {
            lib.focused = a
            if let a { live = LiveMode.get(a.id) }
            setupKeyMonitor()
            setupScrollResistanceMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
            removeScrollResistanceMonitor()
            resetTask?.cancel()
            videoPlayer?.pause()
            videoPlayer = nil
        }
        .onChange(of: path) {
            lib.focused = lib.asset(at: path)
            hoverPlay = false
            if let a = lib.focused { live = LiveMode.get(a.id) }
            isZoomed = false
            isUnlocked = false
            hasScrolledDown = false
            videoPlayer?.pause()
            videoPlayer = nil
            videoRatio = nil
            resistanceDelta = 0
            peekOffset = 0
            resetTask?.cancel()
            setupKeyMonitor()
        }
    }

    private func setupKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if handle(event) { return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    private func setupScrollResistanceMonitor() {
        removeScrollResistanceMonitor()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // When zoomed in, StillView handles scroll panning
            if isZoomed { return event }

            // When already unlocked and scrolling through metadata, allow normal scrolling
            if isUnlocked { return event }

            let dy = event.scrollingDeltaY

            // Scrolling up (dy > 0) while at top: allow normal rubber-band or pass through
            if dy > 0 {
                return event
            }

            // Scrolling down (dy < 0): user is attempting to reveal metadata below
            if dy < 0 {
                videoPlayer?.pause()
                resetTask?.cancel()
                let isMouse = !event.hasPreciseScrollingDeltas
                let delta = isMouse ? abs(dy) * 35.0 : abs(dy)
                resistanceDelta += delta
                let threshold: CGFloat = isMouse ? 50.0 : 200.0

                if resistanceDelta < threshold {
                    // Dampened resistance: gives an elastic pulling sensation scaled to threshold
                    let progress = min(1.0, resistanceDelta / threshold)
                    let peek = -min(22, progress * 20.0)
                    withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.86)) {
                        peekOffset = peek
                    }

                    // On trackpad, gesture ended before reaching threshold -> snap back!
                    if event.phase == .ended || event.phase == .cancelled {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            peekOffset = 0
                            resistanceDelta = 0
                        }
                    } else if isMouse || event.phase == [] {
                        // On mouse wheel (no continuous phase), reset after pause
                        resetTask = Task { @MainActor in
                            try? await Task.sleep(for: isMouse ? .milliseconds(1200) : .milliseconds(600))
                            if !isUnlocked && resistanceDelta > 0 {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    peekOffset = 0
                                    resistanceDelta = 0
                                }
                            }
                        }
                    }
                    return nil // Block accidental opening!
                } else {
                    // Resistance OVERCOME!
                    resetTask?.cancel()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        peekOffset = 0
                        isUnlocked = true
                        resistanceDelta = 0
                    }

                    // Safety timeout: if user doesn't scroll down past threshold within 2.5s, re-lock
                    resetTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2.5))
                        if !hasScrolledDown && isUnlocked {
                            isUnlocked = false
                        }
                    }

                    return event // Normal scrolling resumes!
                }
            }

            return event
        }
    }

    private func removeScrollResistanceMonitor() {
        if let m = scrollMonitor {
            NSEvent.removeMonitor(m)
            scrollMonitor = nil
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        let plain = e.modifierFlags.intersection([.command, .option, .control]).isEmpty
        switch e.keyCode {
        case 123: videoPlayer?.pause(); go(-1); return true                         // ←
        case 124: videoPlayer?.pause(); go(1); return true                          // →
        case 49 where plain, 53: videoPlayer?.pause(); lib.closeViewer(); return true   // Leertaste, Esc
        case 126 where e.modifierFlags.contains(.command): videoPlayer?.pause(); lib.closeViewer(); return true   // ⌘↑
        case 36 where plain, 76 where plain: lib.edit(); return true                          // ↩ = Bearbeiten
        case 125 where plain: // ↓ Down arrow unlocks and scrolls down
            videoPlayer?.pause()
            if !isUnlocked {
                isUnlocked = true
                hasScrolledDown = true
            }
            return false
        default:
            if e.charactersIgnoringModifiers == "." && plain { Task { await lib.toggleFavorite() }; return true }
            if e.keyCode == 51 && plain && lib.source != .trash { Task { await lib.trash() }; return true }
            return false
        }
    }

    private func go(_ d: Int) {
        let current = lib.viewer ?? path
        guard let p = lib.step(current, by: d) else { return }
        lib.viewer = p
        if let a = lib.asset(at: p) { lib.selection = [a.id]; lib.focused = a }
    }
}

/// Foto: Vorschau sofort, volle Auflösung danach; Zoomen per Trackpad/Scrollrad, Verschieben per Zwei-Finger-Geste oder Klick & Ziehen.
private struct StillView: View {
    let asset: Asset
    @Binding var isZoomed: Bool
    @Binding var live: LiveMode
    let hoverPlay: Bool
    @State private var image: CGImage?
    @State private var exposure: CGImage?
    /// Wie Fotos: beim Öffnen bewegt sich ein Live Photo einmal kurz, dann steht das Foto
    @State private var openingPlay = true
    @State private var hdr = false
    @State private var pan = ViewerPanState()
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @State private var monitor: Any?

    var body: some View {
        GeometryReader { g in
            let currentScale = pan.scale * pinch
            let rawOffset = CGSize(width: pan.offset.width + drag.width, height: pan.offset.height + drag.height)
            let currentOffset = pan.clamp(rawOffset, scale: currentScale)

            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .allowedDynamicRange(hdr ? .high : .standard)
                        .scaleEffect(currentScale)
                        .offset(currentOffset)
                        .frame(width: g.size.width, height: g.size.height)
                        .overlay {
                            liveLayer
                                .scaleEffect(currentScale)
                                .offset(currentOffset)
                                .allowsHitTesting(false)
                        }
                        .simultaneousGesture(
                            MagnifyGesture()
                                .updating($pinch) { v, s, _ in s = v.magnification }
                                .onEnded { v in
                                    let newScale = min(6, max(1, pan.scale * v.magnification))
                                    pan.scale = newScale
                                    if newScale <= 1 {
                                        pan.offset = .zero
                                    } else {
                                        pan.offset = pan.clamp(pan.offset, scale: newScale)
                                    }
                                    isZoomed = newScale > 1.01
                                }
                        )
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 1)
                                .updating($drag) { v, s, _ in
                                    if pan.scale * pinch > 1 {
                                        s = v.translation
                                    }
                                }
                                .onEnded { v in
                                    if pan.scale > 1 {
                                        pan.offset = pan.clamp(
                                            CGSize(width: pan.offset.width + v.translation.width, height: pan.offset.height + v.translation.height),
                                            scale: pan.scale
                                        )
                                    }
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.snappy) {
                                if pan.scale > 1 {
                                    pan.scale = 1
                                    pan.offset = .zero
                                    isZoomed = false
                                } else {
                                    pan.scale = 2.5
                                    isZoomed = true
                                }
                            }
                        }
                } else {
                    ProgressView().frame(width: g.size.width, height: g.size.height)
                }
            }
            .onAppear {
                pan.viewSize = g.size
                if let image {
                    pan.imageSize = CGSize(width: image.width, height: image.height)
                }
            }
            .onChange(of: g.size) { _, newSize in
                pan.viewSize = newSize
                pan.offset = pan.clamp(pan.offset, scale: pan.scale)
            }
            .onChange(of: image) { _, newImg in
                if let newImg {
                    pan.imageSize = CGSize(width: newImg.width, height: newImg.height)
                    pan.offset = pan.clamp(pan.offset, scale: pan.scale)
                }
            }
            .onChange(of: pan.scale) { _, newScale in
                isZoomed = newScale > 1.01
            }
            .onChange(of: pinch) { _, newPinch in
                if pan.scale * newPinch > 1.01 {
                    isZoomed = true
                }
            }
        }
        .task(id: live) {
            guard live == .longExposure, exposure == nil, let v = asset.livePhotoVideoId else { return }
            exposure = await LiveClip.longExposure(v)
        }
        .task {
            if let t = ImageCache.shared.get(asset.id, .preview) ?? ImageCache.shared.get(asset.id, .thumbnail) { image = t }
            if let p = await ImageCache.shared.load(asset.id, .preview) { image = p }
            // GitHub HomeRoll #36: Immichs Vorschauen sind ohne HDR → Original mit Gain-Map selbst dekodieren
            if UserDefaults.standard.object(forKey: "mac.alwaysOriginal") as? Bool ?? true, asset.isImage,
               let f = await Self.original(asset.id) { image = f; hdr = true; return }
            if let f = await ImageCache.shared.load(asset.id, .fullsize) { image = f }
        }
        .onAppear {
            setupScrollMonitor()
        }
        .onDisappear {
            removeScrollMonitor()
        }
    }

    private func setupScrollMonitor() {
        removeScrollMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak pan] event in
            guard let pan, pan.scale > 1.0 else { return event }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard dx != 0 || dy != 0 else { return event }
            pan.handleScroll(dx: dx, dy: dy)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    @ViewBuilder private var liveLayer: some View {
        if let v = asset.livePhotoVideoId, asset.isImage {
            switch live {
            case .loop: LiveVideo(videoID: v, style: .loop).id("loop\(v)")
            case .bounce: LiveVideo(videoID: v, style: .bounce).id("bounce\(v)")
            case .longExposure:
                if let exposure { Image(decorative: exposure, scale: 1).resizable().aspectRatio(contentMode: .fit) }
                else { ProgressView().controlSize(.small) }
            case .live:
                if hoverPlay { LiveVideo(videoID: v, style: .loop).id("hover\(v)") }
                else if openingPlay {
                    LiveVideo(videoID: v, style: .once) { withAnimation(.easeOut(duration: 0.3)) { openingPlay = false } }
                        .id("open\(v)").transition(.opacity)
                }
            case .off: EmptyView()
            }
        }
    }

    /// Original vom Server als HDR-Bild (Gain-Map/HDR-Format), höchstens 6000 px; nil = nicht dekodierbar.
    static func original(_ id: String) async -> CGImage? {
        guard let url = ImmichClient.shared.originalURL(id), let data = try? await ImmichClient.shared.data(url) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 6000, kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
        }.value
    }
}

@Observable
@MainActor
final class ViewerPanState {
    var scale: CGFloat = 1.0
    var offset: CGSize = .zero
    var viewSize: CGSize = .zero
    var imageSize: CGSize = .zero

    func handleScroll(dx: CGFloat, dy: CGFloat) {
        guard scale > 1.0 else { return }
        offset = clamp(CGSize(width: offset.width + dx, height: offset.height + dy), scale: scale)
    }

    func clamp(_ target: CGSize, scale s: CGFloat) -> CGSize {
        guard s > 1.0, viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }
        let aspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height
        let fitW: CGFloat
        let fitH: CGFloat
        if aspect > viewAspect {
            fitW = viewSize.width
            fitH = viewSize.width / aspect
        } else {
            fitH = viewSize.height
            fitW = viewSize.height * aspect
        }
        let scaledW = fitW * s
        let scaledH = fitH * s
        let maxOffsetX = max(0, (scaledW - viewSize.width) / 2)
        let maxOffsetY = max(0, (scaledH - viewSize.height) / 2)
        return CGSize(
            width: min(maxOffsetX, max(-maxOffsetX, target.width)),
            height: min(maxOffsetY, max(-maxOffsetY, target.height))
        )
    }
}

/// A container view that embeds an AVPlayerView and intercepts scroll events
/// to prevent AVKit from fast-forwarding the video via scrolling or trackpad input.
final class VideoContainerView: NSView {
    let playerView = AVPlayerView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .scrollWheel {
            return self
        }
        return hit
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// Video mit den Mac-Bedienelementen (AVPlayerView); nicht abspielbare Formate → Original/HLS wie auf dem iPhone.
private struct VideoPlayerView: NSViewRepresentable {
    let asset: Asset
    @Binding var player: AVPlayer?
    @Binding var naturalRatio: Double?

    func makeNSView(context: Context) -> VideoContainerView {
        let container = VideoContainerView()
        let v = container.playerView
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let api = ImmichClient.shared
        if let url = api.videoURL(asset.id) {
            let avAsset = api.avAsset(url)
            let item = AVPlayerItem(asset: avAsset)
            let p = AVPlayer(playerItem: item)
            v.player = p
            DispatchQueue.main.async {
                self.player = p
            }
            p.play()

            Task { @MainActor in
                if let track = try? await avAsset.loadTracks(withMediaType: .video).first {
                    let size = try? await track.load(.naturalSize)
                    let transform = try? await track.load(.preferredTransform)
                    if let size, size.width > 0, size.height > 0 {
                        let isRotated = transform.map { $0.a == 0 && abs($0.b) == 1 } ?? false
                        let w = isRotated ? size.height : size.width
                        let h = isRotated ? size.width : size.height
                        self.naturalRatio = Double(w / h)
                    }
                }
            }

            let id = asset.id
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if item.status == .failed, let alt = await api.playableFallback(for: id) {
                    let fallbackP = AVPlayer(playerItem: AVPlayerItem(asset: alt))
                    v.player = fallbackP
                    self.player = fallbackP
                    fallbackP.play()
                }
            }
        }
        return container
    }

    func updateNSView(_ container: VideoContainerView, context: Context) {
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.playerView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    static func dismantleNSView(_ container: VideoContainerView, coordinator: ()) {
        container.playerView.player?.pause()
        container.playerView.player = nil
    }
}

/// Nimmt Tasten an, solange die Einzelansicht offen ist (wird beim Erscheinen Ersthelfer).
struct KeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool
    func makeNSView(context: Context) -> KeyView {
        let v = KeyView(); v.onKey = onKey
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ v: KeyView, context: Context) { v.onKey = onKey }

    final class KeyView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with e: NSEvent) { if onKey?(e) != true { super.keyDown(with: e) } }
    }
}

// MARK: - Photo Metadata & Scrolling Details (Faces, Location, Places)

struct FaceItem: Identifiable, Sendable {
    let id: String
    let person: PersonDTO?
    let croppedImage: CGImage?
}

struct FaceThumbnailButton: View {
    let item: FaceItem
    @Bindable var lib: Library
    @State private var hovered = false
    @State private var thumbImg: CGImage?

    private var currentPerson: PersonDTO? {
        guard let p = item.person else { return nil }
        return lib.people.first(where: { $0.id == p.id }) ?? p
    }

    var body: some View {
        let p = currentPerson
        Button {
            if let p {
                lib.open(.person(p.id, p.name))
            }
        } label: {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let img = item.croppedImage ?? thumbImg {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(hovered ? Color.primary.opacity(0.7) : Color.primary.opacity(0.12), lineWidth: hovered ? 2 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if p?.isFavorite == true {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { h in hovered = h }
        .help(p?.name.isEmpty == false ? p!.name : (p != nil ? String(localized: "Unbenannte Person") : String(localized: "Gesicht")))
        .contextMenu {
            if let p {
                PeopleActions.menu(p, lib: lib)
            }
        }
        .task(id: item.id) {
            if item.croppedImage == nil, let p {
                if let u = ImmichClient.shared.personThumbURL(p.id),
                   let d = try? await ImmichClient.shared.data(u) {
                    thumbImg = ImageCache.decode(d)
                }
            }
        }
    }
}

struct ViewerDetailsView: View {
    let asset: Asset
    @Bindable var lib: Library
    @State private var dto: AssetDTO?
    @State private var faceItems: [FaceItem] = []
    @State private var address: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            // MARK: - People
            if !faceItems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Personen")
                        .font(.title3.bold())
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(faceItems) { item in
                                FaceThumbnailButton(item: item, lib: lib)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // MARK: - Places
            if let lat = dto?.exifInfo?.latitude, let lon = dto?.exifInfo?.longitude {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                let displayAddress = address ?? [dto?.exifInfo?.city, dto?.exifInfo?.state, dto?.exifInfo?.country].compactMap { $0 }.joined(separator: ", ")
                let cityName = dto?.exifInfo?.city ?? asset.city

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Orte")
                            .font(.title3.bold())
                            .foregroundStyle(.secondary)

                        if !displayAddress.isEmpty {
                            Button {
                                if let c = cityName, !c.isEmpty { lib.open(.city(c)) } else { lib.open(.map) }
                            } label: {
                                Text(displayAddress)
                                    .font(.callout)
                                    .foregroundStyle(.blue)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        Button {
                            if let c = cityName, !c.isEmpty { lib.open(.city(c)) } else { lib.open(.map) }
                        } label: {
                            Text("Fotos in der Nähe")
                                .font(.callout)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }

                    ZStack {
                        Map(initialPosition: .region(MKCoordinateRegion(center: coord, latitudinalMeters: 1000, longitudinalMeters: 1000)), interactionModes: []) {
                            Annotation("", coordinate: coord) {
                                Thumb(id: asset.id)
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .padding(3)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .shadow(color: .black.opacity(0.35), radius: 5, x: 0, y: 2)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture {
                        if let c = cityName, !c.isEmpty { lib.open(.city(c)) } else { lib.open(.map) }
                    }
                    .help("Auf Karte zeigen")
                }
            }

            // MARK: - Details (Camera / Video / File)
            let e = dto?.exifInfo
            let cam = [e?.make, e?.model].compactMap { $0 }.joined(separator: " ")
            let exp = [e?.fNumber.map { String(format: "ƒ%.1f", $0) }, e?.exposureTime.map { "\($0) s" },
                       e?.focalLength.map { String(format: "%.0f mm", $0) }, e?.iso.map { "ISO \(Int($0))" }].compactMap { $0 }.joined(separator: "   ")
            let dur = asset.isVideo ? Fmt.duration(asset.durationMs ?? dto?.duration) : ""
            let w = dto?.width ?? e?.exifImageWidth
            let h = dto?.height ?? e?.exifImageHeight
            let res = (w != nil && h != nil && w! > 0 && h! > 0) ? "\(Int(w!)) × \(Int(h!))" : nil

            if !cam.isEmpty || !exp.isEmpty || !dur.isEmpty || res != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        if !cam.isEmpty {
                            Label(cam, systemImage: "camera")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if !dur.isEmpty {
                            Label(dur, systemImage: "video")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let res {
                            Label(res, systemImage: "film")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if !exp.isEmpty {
                            Label(exp, systemImage: "dial.low")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 60)
        .frame(maxWidth: 860, alignment: .leading)
        .task(id: asset.id) {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        dto = nil
        faceItems = []
        address = nil

        let api = ImmichClient.shared
        let d = try? await api.asset(asset.id)
        let sFaces = await api.faces(asset.id)
        let cg = await ImageCache.shared.load(asset.id, .preview) ?? ImageCache.shared.get(asset.id, .thumbnail)
        dto = d

        var items: [FaceItem] = []
        if !sFaces.isEmpty {
            for f in sFaces {
                var crop: CGImage? = nil
                if let cg, let x1 = f.boundingBoxX1, let y1 = f.boundingBoxY1,
                   let x2 = f.boundingBoxX2, let y2 = f.boundingBoxY2 {
                    let iw = f.imageWidth ?? Double(cg.width)
                    let ih = f.imageHeight ?? Double(cg.height)
                    crop = cropFace(from: cg, x1: x1, y1: y1, x2: x2, y2: y2, imgW: iw, imgH: ih)
                }
                items.append(FaceItem(id: f.id, person: f.person, croppedImage: crop))
                if let p = f.person {
                    lib.updatePerson(p)
                }
            }
        } else if let people = d?.people, !people.isEmpty {
            for p in people {
                items.append(FaceItem(id: p.id, person: p, croppedImage: nil))
                lib.updatePerson(p)
            }
        } else if let cg {
            let vFaces = detectVisionFaces(on: cg)
            for (idx, vf) in vFaces.enumerated() {
                let crop = cropFaceVision(from: cg, boundingBox: vf.boundingBox)
                items.append(FaceItem(id: "vision-\(idx)", person: nil, croppedImage: crop))
            }
        }
        faceItems = items

        if let lat = d?.exifInfo?.latitude, let lon = d?.exifInfo?.longitude {
            address = await ReverseGeocoder.shared.address(latitude: lat, longitude: lon)
        }
        isLoading = false
    }
}

@MainActor
final class ReverseGeocoder {
    static let shared = ReverseGeocoder()
    private var cache: [String: String] = [:]
    private let geocoder = CLGeocoder()

    func address(latitude: Double, longitude: Double) async -> String? {
        let key = String(format: "%.4f,%.4f", latitude, longitude)
        if let cached = cache[key] { return cached }
        let loc = CLLocation(latitude: latitude, longitude: longitude)
        guard let marks = try? await geocoder.reverseGeocodeLocation(loc),
              let p = marks.first else { return nil }

        var parts: [String] = []
        let street = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
        if !street.isEmpty { parts.append(street) }

        var cityStateZip: [String] = []
        if let city = p.locality { cityStateZip.append(city) }
        let stateZip = [p.administrativeArea, p.postalCode].compactMap { $0 }.joined(separator: " ")
        if !stateZip.isEmpty { cityStateZip.append(stateZip) }
        if !cityStateZip.isEmpty { parts.append(cityStateZip.joined(separator: " ")) }

        if let country = p.country { parts.append(country) }

        let result = parts.joined(separator: ", ")
        if !result.isEmpty {
            cache[key] = result
            return result
        }
        return nil
    }
}

func cropFace(from cg: CGImage, x1: Double, y1: Double, x2: Double, y2: Double, imgW: Double, imgH: Double) -> CGImage? {
    guard imgW > 0, imgH > 0, x2 > x1, y2 > y1 else { return nil }
    let scaleX = CGFloat(cg.width) / CGFloat(imgW)
    let scaleY = CGFloat(cg.height) / CGFloat(imgH)

    let fx1 = CGFloat(x1) * scaleX
    let fy1 = CGFloat(y1) * scaleY
    let fx2 = CGFloat(x2) * scaleX
    let fy2 = CGFloat(y2) * scaleY

    let faceW = fx2 - fx1
    let faceH = fy2 - fy1
    let midX = fx1 + faceW / 2
    let midY = fy1 + faceH / 2

    let side = max(faceW, faceH) * 1.7
    let cropX = max(0, min(CGFloat(cg.width) - side, midX - side / 2))
    let cropY = max(0, min(CGFloat(cg.height) - side, midY - side / 2))
    let cropW = min(side, CGFloat(cg.width) - cropX)
    let cropH = min(side, CGFloat(cg.height) - cropY)
    let finalSide = min(cropW, cropH)
    guard finalSide > 0 else { return nil }

    return cg.cropping(to: CGRect(x: cropX, y: cropY, width: finalSide, height: finalSide))
}

func cropFaceVision(from cg: CGImage, boundingBox box: CGRect) -> CGImage? {
    let w = CGFloat(cg.width)
    let h = CGFloat(cg.height)
    let fx = box.minX * w
    let fy = (1.0 - box.maxY) * h
    let fw = box.width * w
    let fh = box.height * h
    let midX = fx + fw / 2
    let midY = fy + fh / 2

    let side = max(fw, fh) * 1.7
    let cropX = max(0, min(w - side, midX - side / 2))
    let cropY = max(0, min(h - side, midY - side / 2))
    let cropW = min(side, w - cropX)
    let cropH = min(side, h - cropY)
    let finalSide = min(cropW, cropH)
    guard finalSide > 0 else { return nil }

    return cg.cropping(to: CGRect(x: cropX, y: cropY, width: finalSide, height: finalSide))
}

func detectVisionFaces(on cg: CGImage) -> [VNFaceObservation] {
    let req = VNDetectFaceRectanglesRequest()
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    try? handler.perform([req])
    return req.results ?? []
}
