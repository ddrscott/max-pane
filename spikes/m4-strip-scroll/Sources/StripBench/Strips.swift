import AppKit

let LANE_GAP: CGFloat = 8

protocol Strip: AnyObject {
    var scrollView: NSScrollView { get }
    var widths: [CGFloat] { get }
    var contentWidth: CGFloat { get }
    var maxScrollX: CGFloat { get }
    /// Lane views currently attached to the view hierarchy.
    var liveLaneViewCount: Int { get }
    func build(widths: [CGFloat])
    func teardown()
    func insertLane(at index: Int, width: CGFloat)
    func resizeLane(at index: Int, to width: CGFloat)
    func setScrollX(_ x: CGFloat)
    var scrollX: CGFloat { get }
    func laneIndex(atX x: CGFloat) -> Int
}

extension Strip {
    var scrollX: CGFloat { scrollView.contentView.bounds.origin.x }
    var maxScrollX: CGFloat { max(0, contentWidth - scrollView.contentView.bounds.width) }
    func setScrollX(_ x: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Shared offset bookkeeping.
final class LaneModel {
    private(set) var widths: [CGFloat] = []
    private(set) var offsets: [CGFloat] = []
    private(set) var total: CGFloat = 0

    func set(_ w: [CGFloat]) { widths = w; recompute() }
    func insert(_ w: CGFloat, at i: Int) { widths.insert(w, at: i); recompute() }
    func resize(_ i: Int, to w: CGFloat) { widths[i] = w; recompute() }

    private func recompute() {
        offsets = []
        offsets.reserveCapacity(widths.count)
        var x: CGFloat = 0
        for w in widths { offsets.append(x); x += w + LANE_GAP }
        total = x
    }

    var count: Int { widths.count }

    func index(atX x: CGFloat) -> Int {
        guard !offsets.isEmpty else { return 0 }
        var lo = 0, hi = offsets.count - 1, ans = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if offsets[mid] <= x { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    /// [first, last] inclusive lane range intersecting the x span, expanded by `buffer` lanes.
    func range(x: CGFloat, width: CGFloat, buffer: Int) -> ClosedRange<Int> {
        guard count > 0 else { return 0...0 }
        let first = max(0, index(atX: x) - buffer)
        let last = min(count - 1, index(atX: x + width) + buffer)
        return first...max(first, last)
    }
}

final class StripDocumentView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - A-naive: every lane view instantiated and parented, no recycling

final class NaiveStrip: Strip {
    let scrollView = NSScrollView()
    let doc = StripDocumentView()
    let model = LaneModel()
    private var lanes: [LaneView] = []

    var widths: [CGFloat] { model.widths }
    var contentWidth: CGFloat { model.total }
    var liveLaneViewCount: Int { doc.subviews.count }

    init() { configureScrollView(scrollView, doc: doc) }

    func build(widths w: [CGFloat]) {
        model.set(w)
        lanes = (0..<model.count).map { i in
            let v = LaneView()
            v.configure(index: i)
            doc.addSubview(v)
            return v
        }
        applyFrames()
    }

    private func applyFrames() {
        let h = scrollView.contentView.bounds.height
        doc.frame = NSRect(x: 0, y: 0, width: model.total, height: h)
        for (i, v) in lanes.enumerated() {
            v.frame = NSRect(x: model.offsets[i], y: 0, width: model.widths[i], height: h)
        }
    }

    func teardown() {
        lanes.forEach { $0.removeFromSuperview() }
        lanes = []
        model.set([])
    }

    func insertLane(at index: Int, width: CGFloat) {
        model.insert(width, at: index)
        let v = LaneView()
        v.configure(index: index)
        doc.addSubview(v)
        lanes.insert(v, at: index)
        applyFrames()
    }

    func resizeLane(at index: Int, to width: CGFloat) {
        model.resize(index, to: width)
        applyFrames()
    }

    func laneIndex(atX x: CGFloat) -> Int { model.index(atX: x) }
}

// MARK: - A-recycled: NSScrollView + manual view recycling from a pool

final class RecycledStrip: Strip {
    let scrollView = NSScrollView()
    let doc = StripDocumentView()
    let model = LaneModel()
    let buffer: Int

    private var attached: [Int: LaneView] = [:]
    private var pool: [LaneView] = []
    private(set) var peakLive = 0
    private(set) var reconcileCount = 0
    private(set) var attachEvents = 0

    var widths: [CGFloat] { model.widths }
    var contentWidth: CGFloat { model.total }
    var liveLaneViewCount: Int { attached.count }
    var pooledCount: Int { pool.count }

    init(buffer: Int) {
        self.buffer = buffer
        configureScrollView(scrollView, doc: doc)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    @objc private func boundsChanged() { reconcile() }

    func build(widths w: [CGFloat]) {
        model.set(w)
        doc.frame = NSRect(x: 0, y: 0, width: model.total, height: scrollView.contentView.bounds.height)
        reconcile()
    }

    func reconcile() {
        reconcileCount += 1
        guard model.count > 0 else { return }
        let clip = scrollView.contentView.bounds
        let want = model.range(x: clip.origin.x, width: clip.width, buffer: buffer)
        let h = scrollView.contentView.bounds.height

        // Detach anything outside the window into the pool.
        let stale = attached.keys.filter { !want.contains($0) }
        for i in stale {
            if let v = attached.removeValue(forKey: i) {
                v.removeFromSuperview()
                pool.append(v)
            }
        }
        // Attach / position the wanted range.
        for i in want {
            let frame = NSRect(x: model.offsets[i], y: 0, width: model.widths[i], height: h)
            if let v = attached[i] {
                if v.frame != frame { v.frame = frame }
            } else {
                let v = pool.popLast() ?? LaneView()
                v.configure(index: i)
                v.frame = frame
                doc.addSubview(v)
                attached[i] = v
                attachEvents += 1
            }
        }
        peakLive = max(peakLive, attached.count)
    }

    func teardown() {
        attached.values.forEach { $0.removeFromSuperview() }
        attached = [:]
        pool = []
        model.set([])
    }

    func insertLane(at index: Int, width: CGFloat) {
        // Shift keys >= index, then re-reconcile.
        var shifted: [Int: LaneView] = [:]
        for (i, v) in attached {
            if i >= index { shifted[i + 1] = v; v.configure(index: i + 1) } else { shifted[i] = v }
        }
        attached = shifted
        model.insert(width, at: index)
        doc.frame = NSRect(x: 0, y: 0, width: model.total, height: scrollView.contentView.bounds.height)
        reconcile()
    }

    func resizeLane(at index: Int, to width: CGFloat) {
        model.resize(index, to: width)
        doc.frame = NSRect(x: 0, y: 0, width: model.total, height: scrollView.contentView.bounds.height)
        reconcile()
    }

    func laneIndex(atX x: CGFloat) -> Int { model.index(atX: x) }
}

// MARK: - B: NSCollectionView with a custom virtualizing layout for varied widths

final class StripLayout: NSCollectionViewLayout {
    var model = LaneModel()
    private var cachedHeight: CGFloat = 0
    private var attrs: [NSCollectionViewLayoutAttributes] = []

    override func prepare() {
        super.prepare()
        cachedHeight = collectionView?.enclosingScrollView?.contentView.bounds.height ?? 1000
        attrs = (0..<model.count).map { i in
            let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: i, section: 0))
            a.frame = NSRect(x: model.offsets[i], y: 0, width: model.widths[i], height: cachedHeight)
            return a
        }
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: model.total, height: cachedHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard model.count > 0 else { return [] }
        let first = max(0, model.index(atX: rect.minX) - 1)
        let last = min(model.count - 1, model.index(atX: rect.maxX) + 1)
        guard first <= last else { return [] }
        return Array(attrs[first...last])
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let i = indexPath.item
        return i >= 0 && i < attrs.count ? attrs[i] : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.height != cachedHeight
    }
}

final class CollectionStrip: NSObject, Strip, NSCollectionViewDataSource {
    let scrollView = NSScrollView()
    let collectionView = NSCollectionView()
    let layout = StripLayout()
    private(set) var peakLive = 0
    private(set) var insertUsedReload = false

    var widths: [CGFloat] { layout.model.widths }
    var contentWidth: CGFloat { layout.model.total }
    var liveLaneViewCount: Int {
        let n = collectionView.visibleItems().count
        peakLiveTrack(n)
        return n
    }
    private func peakLiveTrack(_ n: Int) { peakLive = max(peakLive, n) }

    override init() {
        super.init()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [NSColor(white: 0.04, alpha: 1)]
        collectionView.register(LaneItem.self, forItemWithIdentifier: LaneItem.identifier)
        configureScrollView(scrollView, doc: collectionView)
    }

    func build(widths w: [CGFloat]) {
        layout.model.set(w)
        collectionView.reloadData()
        layout.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()
    }

    func teardown() {
        layout.model.set([])
        collectionView.reloadData()
        layout.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()
    }

    func insertLane(at index: Int, width: CGFloat) {
        layout.model.insert(width, at: index)
        layout.invalidateLayout()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            collectionView.insertItems(at: [IndexPath(item: index, section: 0)])
        }
    }

    func resizeLane(at index: Int, to width: CGFloat) {
        layout.model.resize(index, to: width)
        layout.invalidateLayout()
    }

    func laneIndex(atX x: CGFloat) -> Int { layout.model.index(atX: x) }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        layout.model.count
    }
    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: LaneItem.identifier, for: indexPath) as! LaneItem
        item.lane.configure(index: indexPath.item)
        return item
    }
}

// MARK: - shared scroll view setup

func configureScrollView(_ sv: NSScrollView, doc: NSView) {
    sv.hasHorizontalScroller = true
    sv.hasVerticalScroller = false
    sv.horizontalScrollElasticity = .none
    sv.verticalScrollElasticity = .none
    sv.autohidesScrollers = true
    sv.scrollerStyle = .overlay
    sv.drawsBackground = true
    sv.backgroundColor = NSColor(white: 0.04, alpha: 1)
    sv.contentView.drawsBackground = true
    sv.documentView = doc
}
