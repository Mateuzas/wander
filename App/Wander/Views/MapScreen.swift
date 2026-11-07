import MapKit
import RouteEngine
import SwiftUI

/// Home, swipe walk, summary and walking states (PLAN.md §7, ADR 016) on one
/// full-bleed map. Home has no sheet, only the floating "Where to?" island (FE-17)
/// and "Start a walk"; the sheet appears for a place card, a dropped pin, the walk's
/// kinds and area, the summary, or the walk. The swipe deck covers the map. No tab
/// or navigation bar.
struct MapScreen: View {
    /// §10 Motion: the Wander line draws in over ~0.9 s.
    private static let drawDuration = 0.9

    @State private var location = LocationService()
    @State private var search = SearchService()
    @State private var store = POIStore()
    /// Fetches the nightly-published places (FE-15, ADR 013).
    @State private var updater = DataUpdater()
    @State private var recents = RecentDestinations()
    @State private var connectivity: Connectivity
    @State private var planner: PlannerModel
    /// Food nearby (FE-19): the closest good open place of a kind.
    @State private var food: FoodFinder

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var visiblePOIs: [POI] = []
    @State private var mapSize: CGSize = .zero
    @State private var detent: PresentationDetent = .medium
    @State private var selectedPOI: POI?
    /// The "Where to?" island expanded into the search panel (FE-17).
    @State private var searchOpen = false
    @State private var searchFocus = true
    /// What the sheet last showed, kept on screen while it slides away.
    @State private var lastCard: LastCard?
    /// The sheet height the open place or pin card needs (FE-17), measured by the card.
    @State private var cardHeight: CGFloat = 0
    @State private var debugOverlay = false
    @AppStorage(WanderMapStyle.storageKey) private var mapStyle = WanderMapStyle.map
    /// Reactions and walked places, on the phone (ADR 016 "Swipe memory").
    @State private var memory = SwipeMemoryStore()
    /// A swipe walk being built: kinds, area, deck (FE-23).
    @State private var session: SwipeSession?
    /// "Where to?" is open to set the swipe walk's destination, not to plan a walk.
    @State private var pickingDestination = false
    @State private var walk: WalkModel?
    @State private var rotation = MapRotation()

    // Dropped pin (FE-7): long-press on the map.
    @State private var droppedPin: DroppedPin?
    @State private var geocodeTask: Task<Void, Never>?
    /// Bumped on every drop, for the haptic.
    @State private var pinDrops = 0
    /// True while a long press is held, and when it last ended, so the lift isn't read as a tap.
    @State private var longPressing = false
    @State private var lastLongPress = Date.distantPast
    private static let mapSpace = NamedCoordinateSpace.named("map")

    // Draw-in state for the current plan.
    @State private var routeLine: [Coordinate] = []
    @State private var routeLengths: [Double] = []
    @State private var reveal: Double = 1
    @State private var routeOpacity: Double = 1
    @State private var drawTask: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let connectivity = Connectivity()
        _connectivity = State(initialValue: connectivity)
        let planner = PlannerModel(connectivity: connectivity)
        _planner = State(initialValue: planner)
        // Shares the planner's provider, so both keep to one MapKit rate limit.
        _food = State(initialValue: FoodFinder(provider: planner.provider))
    }

    /// The map with its controls, search panel, deck and sheet.
    private var screen: some View {
        map
            .accessibilityHidden(searchOpen)
            .overlay(alignment: .top) {
                if !searchOpen {
                    // VoiceOver reads the island and map controls before the map.
                    topControls.accessibilitySortPriority(1)
                }
            }
            .overlay(alignment: .bottom) {
                upAhead
                    .padding(.horizontal, Layout.margin)
                    .padding(.bottom, Layout.peekHeight + Layout.grid)
            }
            .overlay {
                if searchOpen {
                    SearchPanel(
                        search: search,
                        recents: recents,
                        locationDenied: location.access == .denied,
                        offline: !connectivity.isOnline,
                        placesGenerated: store.generated,
                        focusOnAppear: searchFocus,
                        cuisinesNearby: cuisinesNearby,
                        onChoose: choose,
                        onFood: findFood,
                        showsNearby: !pickingDestination,
                        onCancel: closeSearch)
                    .transition(.opacity)
                }
            }
            .overlay { deck }
            .sheet(isPresented: sheetPresented) {
                sheetContent
                    .presentationDetents(sheetDetents, selection: $detent)
                    .presentationBackground(.surface)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    // A card over the home map swipes away; over a plan or walk it closes with ✕.
                    .interactiveDismissDisabled(!isHomeCard)
            }
    }

    /// Step 3 of a swipe walk covers the map (and slides away when it's done).
    private var deck: some View {
        ZStack {
            if let session, session.step == .deck {
                SwipeDeckView(session: session, onDone: finishDeck, onBack: session.backToArea)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.35), value: session?.step)
    }

    var body: some View {
        chainTwo(chainOne(screen))
    }

    /// Split from `body`: one long modifier chain is too much for the type checker.
    private func chainOne(_ v: some View) -> some View {
        v
            .onChange(of: sheetKind) {
                if !sheetDetents.contains(detent) { detent = isCard ? cardDetent : .medium }
            }
            // The card's content grew or shrank (photo, Apple place info): follow it,
            // unless the user dragged the card to large.
            .onChange(of: cardDetent) { old, new in
                if isCard, detent == old { detent = new }
            }
            .onChange(of: selectedPOI) { _, poi in
                if let poi { lastCard = .poi(poi) }
            }
            .onChange(of: droppedPin) { _, pin in
                if let pin { lastCard = .pin(pin) }
            }
            .task {
                if let region = store.region {
                    position = .userLocation(fallback: .region(region))
                }
                location.requestAccess()
            }
            .onChange(of: location.access) { _, access in
                if access == .denied {
                    planner.originUnavailable()
                    food.locationDenied()
                    // Say why at once: open the search panel, which carries the message.
                    if sheetKind == nil, !searchOpen { openSearch(focus: false) }
                }
            }
            .onChange(of: location.location) { _, fix in
                guard let fix else { return }
                if let walk {
                    walk.handle(fix)
                } else {
                    planner.setOrigin(Coordinate(fix.coordinate))
                    food.setOrigin(Coordinate(fix.coordinate))
                    session?.userMoved(to: Coordinate(fix.coordinate))
                }
            }
    }

    private func chainTwo(_ v: some View) -> some View {
        v
            // The area step: frame the circle (or band) when the time or the end changes.
            .onChange(of: session?.length) { frameArea() }
            .onChange(of: session?.destination) { frameArea() }
            .onChange(of: session?.step) { _, step in
                if step == .area { frameArea() }
            }
            .onChange(of: foodResult) { _, poi in
                if let poi { showFood(poi) }
            }
            .onChange(of: displayedPlan) { _, plan in
                showPlan(plan)
            }
            .onChange(of: walk?.phase) { _, phase in
                if phase == .arrived || phase == .ended {
                    // Stops walked count as seen today in the next deck.
                    if let walk { memory.markWalked(walk.reached) }
                    selectedPOI = nil   // show the arrival / ended state, not a place card
                    location.setWalking(false)
                    detent = .medium
                }
            }
            // FE-9: compass on while the map is visible, off in the background.
            .onChange(of: scenePhase, initial: true) { _, phase in
                location.setHeadingActive(phase == .active)
                // FE-15: at launch and on foreground (the updater keeps to every 6 h).
                if phase == .active { checkForFreshPlaces() }
            }
            // A plan or walk ended: swap in places downloaded meanwhile.
            .onChange(of: isHome) { applyPendingPlaces() }
            .onChange(of: store.pois.count) { session?.update(pois: store.pois) }
            .onDisappear {
                walk?.tearDown()
                location.setHeadingActive(false)
            }
    }

    // MARK: - Map controls

    /// Home: the "Where to?" island, "Start a walk" under it on the left, and the
    /// map-style menu and location button on the right. Plan: just the two buttons.
    /// Walking: the turn card owns the top and the style menu hides; the location
    /// button sits under it.
    private var topControls: some View {
        let walking = walk?.phase == .walking
        return VStack(alignment: .trailing, spacing: Layout.grid) {
            if isHome {
                SearchIsland { openSearch() }
            }
            if let walk, walking {
                TurnCard(walk: walk)
            }
            HStack(alignment: .top, spacing: Layout.grid) {
                if isHome {
                    StartWalkButton { startSession() }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: Layout.grid) {
                    if walk == nil {
                        MapStyleControl(style: $mapStyle)
                    }
                    if location.access == .allowed {
                        LocationButton(mode: LocationFollowMode(position), action: locationTapped)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, Layout.margin)
        .padding(.top, walking ? Layout.grid : Layout.margin)
    }

    /// Centre on the user; when already following, turn with their heading; a third
    /// tap goes back to north up. Mid-walk this re-engages following after a pan.
    private func locationTapped() {
        switch LocationFollowMode(position) {
        case .none:
            recentre()
        case .follow:
            move(to: .userLocation(followsHeading: true, fallback: .automatic))
        case .followHeading:
            move(to: .userLocation(followsHeading: false, fallback: .automatic))
        }
    }

    /// Zoomed far out or right in, first fly to a street-level view of the user;
    /// MapKit then keeps that zoom while following.
    private func recentre() {
        let follow = MapCameraPosition.userLocation(followsHeading: false, fallback: .automatic)
        guard let here = location.location?.coordinate, let span = visibleRegion?.span,
              !(Self.followSpan ~= span.latitudeDelta) else {
            move(to: follow)
            return
        }
        let camera = MapCameraPosition.camera(MapCamera(centerCoordinate: here, distance: Self.recentreDistance))
        move(to: camera)
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 650))
            // Only if the user hasn't moved the map meanwhile.
            if position == camera { position = follow }
        }
    }

    /// Latitude spans (about 250 m to 4 km tall) where recentring keeps the zoom.
    private static let followSpan = 0.0025...0.04
    /// Camera distance for a street-level recentre.
    private static let recentreDistance: CLLocationDistance = 900

    // MARK: - Map

    private var map: some View {
        MapReader { proxy in
            mapContent(proxy)
                .coordinateSpace(Self.mapSpace)
                .onMapLongPress(in: Self.mapSpace, onPressing: { pressing in
                    longPressing = pressing
                    if !pressing { lastLongPress = .now }
                }, perform: { point in
                    longPress(at: point, proxy: proxy)
                })
                .simultaneousGesture(SpatialTapGesture(coordinateSpace: Self.mapSpace).onEnded { tap in
                    mapTapped(at: tap.location, proxy: proxy)
                })
                .sensoryFeedback(.impact(weight: .light), trigger: pinDrops)
                // VoiceOver can't long-press a point, so offer the centre instead.
                .accessibilityAction(named: "Drop pin at map centre") { dropPinAtCentre() }
        }
        .ignoresSafeArea()
        // Full-screen size, so the bead grid matches the region MapKit reports.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { mapSize = $0 }
    }

    private func mapContent(_ proxy: MapProxy) -> some View {
        Map(position: $position) {
            // The swipe walk's area (step 2): a circle, or a band to the destination.
            if let session, session.step == .area, let start = session.start {
                if let end = session.destination {
                    MapPolygon(coordinates: AreaShape.band(from: start, to: Coordinate(end.coordinate),
                                                           halfWidth: session.radius / 2).map(\.clLocation))
                        .foregroundStyle(Color.wander.opacity(0.08))
                        .stroke(Color.wander, lineWidth: 2)
                } else {
                    MapCircle(center: start.clLocation, radius: session.radius)
                        .foregroundStyle(Color.wander.opacity(0.08))
                        .stroke(Color.wander, lineWidth: 2)
                    Annotation("", coordinate: AreaShape.point(from: start, bearing: 90, distance: session.radius).clLocation,
                               anchor: .center) {
                        ResizeHandle(radius: session.radius, onAdjust: { session.setRadius($0) })
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
                                guard let c = proxy.convert(value.location, from: .global) else { return }
                                session.setRadius(start.distance(to: Coordinate(c)))
                            })
                    }
                    .annotationTitles(.hidden)
                }
                if session.startMoved {
                    Annotation("Walk starts here", coordinate: start.clLocation, anchor: .center) {
                        StartDot()
                    }
                    .annotationTitles(.hidden)
                }
            }

            // Before the dot, so the dot draws on top of its beam. The cone reads the
            // heading itself, so compass updates don't redraw the whole map.
            if let here = location.location {
                Annotation("", coordinate: here.coordinate, anchor: .center) {
                    HeadingCone(location: location, rotation: rotation)
                }
                .annotationTitles(.hidden)
            }
            // Tinted explicitly so the dot and the heading beam share one colour.
            UserAnnotation()
                .tint(Color.userLocation)

            if displayedPlan != nil {
                if mapStyle.isImagery {
                    // A casing keeps the line readable on imagery.
                    MapPolyline(coordinates: revealedRoute.map(\.clLocation))
                        .stroke(.white.opacity(0.9 * routeOpacity),
                                style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                }
                // Wander route: thick, solid, violet.
                MapPolyline(coordinates: revealedRoute.map(\.clLocation))
                    .stroke(Color.wander.opacity(routeOpacity),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }

            ForEach(beads) { bead in
                Annotation(bead.poi.name, coordinate: bead.poi.coordinate.clLocation, anchor: .center) {
                    Bead(category: bead.poi.category, glyph: bead.poi.glyph, isSelected: (selectedPOI ?? foodResult)?.id == bead.poi.id, isPopular: bead.poi.mapTier == 1, name: bead.poi.name)
                        .opacity(bead.dimmed ? 0.55 : 1)
                        .scaleEffect(bead.shown ? 1 : 0.01)
                        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.4), value: bead.shown)
                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                        .contentShape(Circle())
                        // During a walk only its highlights are drawn, and they open the card too (FE-10).
                        .onTapGesture { select(bead.poi) }
                        .accessibilityAddTraits(.isButton)
                }
                .annotationTitles(.hidden)
            }

            if let marker = planner.destinationMarker {
                Marker(marker.name, coordinate: marker.coordinate)
                    .tint(Color.wander)
            } else if let session, session.step == .area, let end = session.destination {
                Marker(end.name, coordinate: end.coordinate)
                    .tint(Color.wander)
            }

            if let pin = droppedPin {
                Annotation("", coordinate: pin.coordinate, anchor: .bottom) {
                    DroppedPinMarker()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(pin.place == nil ? "Dropped pin" : "Dropped pin, \(pin.title)")
                }
                .annotationTitles(.hidden)
            }

        }
        .mapStyle(mapStyle.mapStyle)
        .mapControls {}
        .onMapCameraChange(frequency: .continuous) { context in
            if rotation.heading != context.camera.heading { rotation.heading = context.camera.heading }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            search.region = context.region
            refreshBeads()
        }
        .onChange(of: beadInterests) { refreshBeads() }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if debugOverlay { tierReadout }
        }
        #endif
    }

    /// Downloads newer places if the nightly publish has them (FE-15). Silent on
    /// failure: the current data stays.
    private func checkForFreshPlaces() {
        Task {
            guard let update = await updater.refreshIfDue(current: store.baseline) else { return }
            store.stage(update)
            applyPendingPlaces()
        }
    }

    /// Reloads the places only on the home map, so an open plan or walk keeps the
    /// POIs it was built from; otherwise the update waits until it ends.
    private func applyPendingPlaces() {
        guard isHome, store.applyPending() else { return }
        refreshBeads()
    }

    /// Picks the POI beads for the visible region by zoom tier (ADR 012, FE-13).
    private func refreshBeads() {
        guard let region = visibleRegion else { return }
        visiblePOIs = store.beads(in: region, viewSize: mapSize, keeping: Set(visiblePOIs.map(\.id)),
                                  interests: beadInterests)
    }

    /// While a swipe walk is set up, beads follow its kinds; with a plan or walk, the
    /// walk's categories; the home map shows every category.
    private var beadInterests: Set<POICategory> {
        if let session { return DeckKind.categories(session.kinds) }
        return isHome ? Set(POICategory.allCases) : planner.interests
    }

    private struct BeadItem: Identifiable {
        let poi: POI
        /// Not on the planned route; drawn quieter so the route beads lead.
        let dimmed: Bool
        /// False until the draw-in passes it.
        let shown: Bool
        var id: String { poi.id }
    }

    /// Route highlights first, then the top POIs in view.
    private var beads: [BeadItem] {
        var items: [BeadItem] = []
        var seen: Set<String> = []
        if let plan = displayedPlan {
            let total = max(routeLengths.last ?? 1, 1)
            for highlight in plan.highlights where seen.insert(highlight.poi.id).inserted {
                items.append(BeadItem(poi: highlight.poi, dimmed: false,
                                      shown: highlight.distanceAlongRoute / total <= reveal + 0.001))
            }
        }
        // While walking, only the walk's highlights show.
        guard walk == nil else { return items }
        let dim = planner.plan != nil
        for poi in visiblePOIs where seen.insert(poi.id).inserted {
            items.append(BeadItem(poi: poi, dimmed: dim, shown: true))
        }
        if let selected = selectedPOI ?? foodResult, seen.insert(selected.id).inserted {
            items.append(BeadItem(poi: selected, dimmed: false, shown: true))
        }
        // MapKit draws annotations in order, so tier 1 beads go last to sit on top.
        return items.filter { $0.poi.mapTier != 1 } + items.filter { $0.poi.mapTier == 1 }
    }

    private var revealedRoute: [Coordinate] {
        guard reveal < 1, let total = routeLengths.last else { return routeLine }
        return RouteGeometry.prefix(routeLine, lengths: routeLengths, length: total * reveal)
    }

    // MARK: - Sheet

    /// The walk's (possibly rerouted) plan while walking, otherwise the planned walk.
    private var displayedPlan: WanderPlan? { walk?.plan ?? planner.plan }

    @ViewBuilder
    private var upAhead: some View {
        Group {
            if let walk, let nudge = walk.nudge {
                UpAheadCard(nudge: nudge, onSkip: walk.skipNudge)
                    .id(nudge.highlight.poi.id)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.3), value: walk?.nudge?.highlight.poi.id)
    }

    @ViewBuilder
    private var sheetContent: some View {
        if let walk {
            if walk.phase == .walking, let poi = selectedPOI {
                walkDetail(poi, walk: walk)
            } else {
                WalkSheet(walk: walk, onDone: finishWalk)
            }
        } else if let request = food.request, selectedPOI == nil {
            FoodCard(finder: food, request: request, onWalkHere: walkHere(to:), onClose: closeCard,
                     onHeight: setCardHeight)
        } else if let poi = selectedPOI {
            POIDetail(
                poi: poi,
                action: detailAction(for: poi),
                onAdd: { await add(poi) },
                onRemove: {
                    if let session { session.removeAdded(poi) } else { planner.remove(poi) }
                    selectedPOI = nil
                },
                // While a swipe walk is being built, the card offers "Add to walk" instead.
                onWalkHere: session == nil ? { walkHere(to: poi) } : nil,
                onClose: { selectedPOI = nil },
                onHeight: setCardHeight)
        } else if let pin = droppedPin {
            DroppedPinCard(pin: pin, onWalkHere: { walkHere(to: pin.destination) },
                           onStartWalk: { startSession(from: Coordinate(pin.coordinate)) },
                           onClose: clearPin, onHeight: setCardHeight)
        } else if let session, session.step != .deck {
            WalkSetupSheet(
                session: session,
                locationDenied: location.access == .denied,
                onPickDestination: pickDestination,
                onUseMyLocation: session.startMoved && location.location != nil ? useMyLocation : nil,
                onStartSwiping: session.beginDeck,
                onClose: closeSession,
                onHeight: setCardHeight)
        } else if planner.isActive {
            summarySheet
        } else {
            closingCard
        }
    }

    // MARK: - Sheet presentation (FE-17)

    private enum SheetKind: Equatable {
        case place, pin, setup, plan, walk, walkPlace, food
    }

    private enum LastCard {
        case poi(POI)
        case pin(DroppedPin)
    }

    /// What the sheet shows; nil means no sheet (home: map and search island).
    private var sheetKind: SheetKind? {
        if let walk { return walk.phase == .walking && selectedPOI != nil ? .walkPlace : .walk }
        if selectedPOI != nil { return .place }
        if food.request != nil { return .food }
        if droppedPin != nil { return .pin }
        if let session {
            // The deck covers the map; "Where to?" for the destination shows without the sheet.
            return session.step == .deck || searchOpen ? nil : .setup
        }
        if planner.isActive { return .plan }
        return nil
    }

    /// Place and pin cards open at half the screen or more, never a small peek.
    private var sheetDetents: Set<PresentationDetent> {
        switch sheetKind {
        case .place, .pin, .walkPlace, .food, .setup: [cardDetent, .large]
        case .plan: [.peek, .medium, .large]
        case .walk: [.peek, .medium]
        case nil: [.medium]
        }
    }

    private var isCard: Bool { [.place, .pin, .walkPlace, .food, .setup].contains(sheetKind) }

    /// Tall enough to show the whole card, at least half the screen, at most large;
    /// longer content scrolls with the actions pinned.
    private var cardDetent: PresentationDetent {
        let screen = max(mapSize.height, 1)
        // Whole points in 8 pt steps, so small layout changes don't move the sheet.
        let needed = (cardHeight / Layout.grid).rounded(.up) * Layout.grid
        let height = max(needed, screen / 2)
        return height >= screen * 0.88 ? .large : .height(height)
    }

    private func setCardHeight(_ height: CGFloat) {
        if abs(height - cardHeight) >= 1 { cardHeight = height }
    }

    /// Home state: no swipe walk, plan or walk, so the search island shows.
    private var isHome: Bool { walk == nil && session == nil && !planner.isActive }

    /// A place or pin card with nothing under it: closing it leaves no sheet.
    private var isHomeCard: Bool { isHome && [.place, .pin, .food].contains(sheetKind) }

    private var sheetPresented: Binding<Bool> {
        Binding(get: { sheetKind != nil }, set: { shown in
            if !shown { closeCard() }
        })
    }

    /// The card the sheet showed last, frozen while the sheet slides away.
    @ViewBuilder
    private var closingCard: some View {
        switch lastCard {
        case .poi(let poi):
            POIDetail(poi: poi, action: .none, onAdd: { .failed }, onRemove: {},
                      onWalkHere: {}, onClose: {})
                .allowsHitTesting(false)
        case .pin(let pin):
            DroppedPinCard(pin: pin, onWalkHere: {}, onClose: {})
                .allowsHitTesting(false)
        case nil:
            Color.clear
        }
    }

    private func closeCard() {
        selectedPOI = nil
        food.close()
        clearPin()
    }

    private func openSearch(focus: Bool = true) {
        closeCard()
        searchFocus = focus
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { searchOpen = true }
    }

    private func closeSearch() {
        pickingDestination = false
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { searchOpen = false }
    }

    /// A highlight's card over the walk (FE-10): the turn card stays, the walk goes
    /// on, and there is no Directions or Add to walk; only Skip while it's ahead.
    private func walkDetail(_ poi: POI, walk: WalkModel) -> some View {
        let skip: POIDetail.WalkSkip? = if walk.skipped.contains(poi.id) {
            .skipped
        } else if walk.canSkip(poi.id) {
            .available { walk.skip(poi.id) }
        } else {
            nil
        }
        return POIDetail(
            poi: poi, action: .none,
            onAdd: { .failed }, onRemove: {},
            onWalkHere: nil,
            walkSkip: skip,
            onClose: {
                selectedPOI = nil
                detent = .peek
            },
            onHeight: setCardHeight)
    }

    @ViewBuilder
    private var summarySheet: some View {
        #if DEBUG
        WalkSummarySheet(planner: planner, onClose: closePlan, onFocus: focus, onStartWalk: startWalk,
                         debugOverlay: $debugOverlay)
        #else
        WalkSummarySheet(planner: planner, onClose: closePlan, onFocus: focus, onStartWalk: startWalk)
        #endif
    }

    /// "Add to walk" while a swipe walk is set up or summarised; nothing otherwise.
    private func detailAction(for poi: POI) -> POIDetail.Action {
        if let session { return session.isAdded(poi) ? .remove : .add }
        guard planner.walk != nil else { return .none }
        return planner.contains(poi) ? .remove : .add
    }

    /// Setting up: the place becomes a must-visit stop of the walk to come.
    /// Summary: it is put into the walk where it costs the least.
    private func add(_ poi: POI) async -> PlannerModel.AddResult {
        if let session {
            session.add(poi)
            selectedPOI = nil
            return .added
        }
        let result = await planner.add(poi)
        if case .added = result { selectedPOI = nil }
        return result
    }

    // MARK: - Actions

    /// A place picked in "Where to?": the swipe walk's destination when that's what
    /// it was opened for, otherwise a walk there.
    private func choose(_ place: Destination) {
        searchOpen = false
        recents.add(place)
        if pickingDestination, let session {
            pickingDestination = false
            session.setDestination(place)
            detent = cardDetent
            return
        }
        walkHere(to: place)
    }

    /// "Walk here" (ADR 016): a walk to `place` with no swipes, then the summary.
    /// Replaces any walk already planned.
    private func walkHere(to place: Destination) {
        searchOpen = false
        selectedPOI = nil
        food.close()
        clearPin()
        session = nil
        let origin = location.location.map { Coordinate($0.coordinate) }
        planner.start(.walkHere(to: place, from: origin, pois: store.pois), origin: origin,
                      pois: store.pois, timeZone: store.timeZone)
        if location.access == .denied { planner.originUnavailable() }
        detent = .medium
        move(to: .camera(MapCamera(centerCoordinate: place.coordinate, distance: 2500)))
    }

    private func walkHere(to poi: POI) {
        let place = Destination(name: poi.name, subtitle: poi.category.spokenName,
                                coordinate: poi.coordinate.clLocation)
        recents.add(place)
        walkHere(to: place)
    }

    // MARK: - Swipe walk (FE-23)

    /// "Start a walk": the kinds step, from the user (or a dropped pin).
    private func startSession(from pin: Coordinate? = nil) {
        closeCard()
        planner.close()
        let start = pin ?? location.location.map { Coordinate($0.coordinate) }
        session = SwipeSession(start: start, startMoved: pin != nil, pois: store.pois, memory: memory)
        detent = cardDetent
    }

    private func closeSession() {
        session = nil
        pickingDestination = false
        detent = .medium
        move(to: .userLocation(fallback: .automatic))
    }

    /// "Somewhere specific": "Where to?" sets the walk's end.
    private func pickDestination() {
        selectedPOI = nil
        pickingDestination = true
        searchFocus = true
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { searchOpen = true }
    }

    private func useMyLocation() {
        guard let here = location.location else { return }
        session?.setStart(Coordinate(here.coordinate), moved: false)
        frameArea()
    }

    /// Frames the circle (or the band to the destination) above the sheet.
    private func frameArea() {
        guard let session, session.step == .area, let start = session.start else { return }
        var points = stride(from: 0.0, to: 360, by: 90).map {
            AreaShape.point(from: start, bearing: $0, distance: session.radius)
        }
        if let end = session.destination {
            points = AreaShape.band(from: start, to: Coordinate(end.coordinate), halfWidth: session.radius / 2)
        }
        if let region = Self.region(fitting: points) { move(to: .region(region)) }
    }

    /// The deck is done (Done, full, or out of cards): plan the walk and show the summary.
    private func finishDeck() {
        guard let session, let start = session.start else { return }
        let picked = Set((session.loved + session.liked).map(\.id))
        let noped = Set(session.swipes.filter { $0.reaction == .nope }.map(\.poi.id))
        let request = PlannerModel.Request(
            title: session.destination?.name ?? "Your walk",
            endName: session.destination?.name,
            end: session.end,
            mustVisit: session.loved,
            optional: session.liked,
            budget: session.budget,
            // Places dealt but not swiped away show as highlights when the walk passes them.
            passing: session.cards.filter { !picked.contains($0.id) && !noped.contains($0.id) },
            interests: DeckKind.categories(session.kinds),
            lovedIDs: Set(session.swipes.filter { $0.reaction == .love }.map(\.poi.id)),
            likedIDs: Set(session.liked.map(\.id)))
        planner.start(request, origin: start, pois: store.pois, timeZone: store.timeZone)
        self.session = nil
        detent = .medium
    }

    // MARK: - Food nearby (FE-19)

    /// The place the food card shows, open or (when nothing is) the nearest closed one.
    private var foodResult: POI? {
        switch food.phase {
        case .found(let result) where food.request != nil: result.poi
        case .nothingOpen(let closed) where food.request != nil: closed
        default: nil
        }
    }

    /// For the restaurant cuisine step; empty without a location.
    private func cuisinesNearby() -> [String] {
        guard let here = location.location else { return [] }
        return FoodPick.cuisines(pois: store.pois, near: Coordinate(here.coordinate))
    }

    private func findFood(_ kind: FoodKind, cuisine: String?) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { searchOpen = false }
        selectedPOI = nil
        clearPin()
        session = nil
        food.start(FoodFinder.Request(kind: kind, cuisine: cuisine),
                   origin: location.location.map { Coordinate($0.coordinate) },
                   locationDenied: location.access == .denied,
                   pois: store.pois, timeZone: store.timeZone)
        detent = cardDetent
    }

    /// Frames the user and the place above the card.
    private func showFood(_ poi: POI) {
        lastCard = .poi(poi)
        var line = [poi.coordinate]
        if let here = location.location { line.append(Coordinate(here.coordinate)) }
        if let region = Self.region(fitting: line) { move(to: .region(region)) }
    }

    /// ✕ on the plan sheet: no sheet left, the search island is back.
    private func closePlan() {
        planner.close()
        selectedPOI = nil
        detent = .medium
    }

    private func select(_ poi: POI) {
        // The food result's own bead: its card is already up.
        if poi.id == foodResult?.id { return }
        clearPin()
        food.close()
        selectedPOI = poi
        if detent != .large || !isCard { detent = cardDetent }
    }

    private func focus(_ poi: POI) {
        select(poi)
        move(to: .camera(MapCamera(centerCoordinate: poi.coordinate.clLocation, distance: 700)))
    }

    private func startWalk(_ plan: WanderPlan) {
        let walk = WalkModel(
            plan: plan, destinationName: planner.endName, provider: planner.provider,
            pois: store.pois, interests: planner.interests)
        self.walk = walk
        selectedPOI = nil
        clearPin()
        debugOverlay = false
        location.setWalking(true)
        if let fix = location.location { walk.handle(fix) }
        detent = .peek
        move(to: .userLocation(followsHeading: false, fallback: .automatic))
    }

    /// Done after arriving or ending: back to the home screen.
    private func finishWalk() {
        walk?.end()
        walk?.tearDown()
        walk = nil
        location.setWalking(false)
        closePlan()
        move(to: .userLocation(fallback: .automatic))
    }

    // MARK: - Dropped pin (FE-7)

    /// A long press on a bead selects it; anywhere else drops the pin. Nothing while walking.
    private func longPress(at point: CGPoint, proxy: MapProxy) {
        guard walk == nil else { return }
        // Setting up a swipe walk: the long press moves the circle there.
        if let session, session.step == .area {
            if let coordinate = proxy.convert(point, from: Self.mapSpace) {
                session.setStart(Coordinate(coordinate), moved: true)
                pinDrops += 1
            }
            return
        }
        if let poi = bead(at: point, proxy: proxy) {
            select(poi)
        } else if let coordinate = proxy.convert(point, from: Self.mapSpace) {
            dropPin(at: coordinate)
        }
    }

    /// The bead whose 44 pt touch target contains `point`, nearest first.
    private func bead(at point: CGPoint, proxy: MapProxy) -> POI? {
        beads
            .compactMap { item -> (poi: POI, distance: CGFloat)? in
                guard item.shown,
                      let p = proxy.convert(item.poi.coordinate.clLocation, to: Self.mapSpace) else { return nil }
                let distance = hypot(p.x - point.x, p.y - point.y)
                return distance <= Layout.minTouch / 2 ? (item.poi, distance) : nil
            }
            .min { $0.distance < $1.distance }?
            .poi
    }

    private func dropPin(at coordinate: CLLocationCoordinate2D) {
        geocodeTask?.cancel()
        let pin = DroppedPin(coordinate: coordinate)
        droppedPin = pin
        selectedPOI = nil
        food.close()
        pinDrops += 1
        if detent != .large || !isCard { detent = cardDetent }
        // Coordinates show at once; the name replaces them if and when it arrives.
        geocodeTask = Task {
            let place = await ReverseGeocoder.place(at: coordinate)
            guard !Task.isCancelled, let place, droppedPin?.id == pin.id else { return }
            droppedPin?.place = place
        }
    }

    private func dropPinAtCentre() {
        guard walk == nil, let center = visibleRegion?.center else { return }
        dropPin(at: center)
    }

    private func clearPin() {
        geocodeTask?.cancel()
        geocodeTask = nil
        droppedPin = nil
    }

    /// A tap elsewhere on the map closes the place card (not a tap on a bead).
    private func mapTapped(at point: CGPoint, proxy: MapProxy) {
        guard let poi = selectedPOI else { return clearPinOnTap(at: point, proxy: proxy) }
        guard bead(at: point, proxy: proxy) == nil else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !longPressing, Date.now.timeIntervalSince(lastLongPress) > 0.4,
                  selectedPOI?.id == poi.id else { return }
            selectedPOI = nil
            if walk != nil { detent = .peek }
        }
    }

    /// A tap elsewhere on the map clears the pin. Not a tap on the pin itself, and
    /// not the lift that ends a long press (checked a moment later, since the two
    /// gestures end on the same touch in no fixed order).
    private func clearPinOnTap(at point: CGPoint, proxy: MapProxy) {
        guard let pin = droppedPin else { return }
        if let p = proxy.convert(pin.coordinate, to: Self.mapSpace),
           hypot(point.x - p.x, point.y - (p.y - DroppedPinMarker.height / 2)) <= Layout.minTouch / 2 {
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !longPressing, Date.now.timeIntervalSince(lastLongPress) > 0.4,
                  droppedPin?.id == pin.id else { return }
            clearPin()
        }
    }

    private func move(to camera: MapCameraPosition) {
        if reduceMotion {
            position = camera
        } else {
            withAnimation(.easeInOut(duration: 0.6)) { position = camera }
        }
    }

    /// Frames the route above the medium sheet and runs the draw-in.
    private func showPlan(_ plan: WanderPlan?) {
        drawTask?.cancel()
        guard let plan else {
            routeLine = []
            routeLengths = []
            return
        }
        routeLine = plan.polyline
        routeLengths = RouteGeometry.cumulativeLengths(routeLine)
        if walk != nil {
            // A reroute mid-walk: no draw-in, and the camera keeps following the walker.
            reveal = 1
            routeOpacity = 1
            return
        }
        if let region = Self.region(fitting: routeLine) {
            move(to: .region(region))
        }

        if reduceMotion {
            // §10: replace the draw-in with a simple fade.
            reveal = 1
            routeOpacity = 0
            drawTask = animate(duration: 0.3) { routeOpacity = $0 }
        } else {
            routeOpacity = 1
            reveal = 0
            drawTask = animate(duration: Self.drawDuration) { t in
                reveal = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2  // ease in-out
            }
        }
    }

    /// Steps `update` from 0 to 1 over `duration`, once per frame. MapPolyline
    /// can't be trimmed with a SwiftUI animation, so the line is redrawn per frame.
    private func animate(duration: Double, update: @escaping (Double) -> Void) -> Task<Void, Never> {
        Task {
            let start = Date()
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(start) / duration)
                update(t)
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Region around `line` with the route in the top half, clear of the medium sheet.
    private static func region(fitting line: [Coordinate]) -> MKCoordinateRegion? {
        guard let first = line.first else { return nil }
        var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
        for c in line {
            minLat = min(minLat, c.lat); maxLat = max(maxLat, c.lat)
            minLon = min(minLon, c.lon); maxLon = max(maxLon, c.lon)
        }
        let latSpan = max(maxLat - minLat, 0.003) * 1.25
        let lonSpan = max(maxLon - minLon, 0.003) * 1.25
        let visibleLat = latSpan / 0.5  // route fills the top ~half of the screen
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2 - visibleLat * 0.22,
                                            longitude: (minLon + maxLon) / 2)
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: visibleLat, longitudeDelta: lonSpan))
    }

    // MARK: - Debug overlay

    #if DEBUG
    /// Zoom-layering tuning aid (FE-13): visible latitude span and beads drawn per tier.
    private var tierReadout: some View {
        let span = visibleRegion?.span.latitudeDelta ?? 0
        let counts = Dictionary(grouping: beads, by: \.poi.mapTier).mapValues(\.count)
        let tiers = (1...3).map { "t\($0) \(counts[$0] ?? 0)" }.joined(separator: "  ")
        let maxTier = ZoomTiers.standard.maxTier(latitudeSpan: span)
        return Text("span \(span, format: .number.precision(.fractionLength(4)))°  ≤t\(maxTier)\n\(tiers)")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.ink)
            .padding(6)
            .background(Color.surfaceRaised.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            .padding(.leading, 12)
            .padding(.top, 60)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    #endif
}

#Preview {
    MapScreen()
}
