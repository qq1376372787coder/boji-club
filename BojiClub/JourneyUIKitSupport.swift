import SwiftUI
import UIKit

/// Each onboarding step keeps its own offset. Selection changes do not trigger restoration.
@MainActor
final class ClubScrollMemory: ObservableObject {
    private weak var scrollView: UIScrollView?
    private var offsets: [String: CGPoint] = [:]
    private var currentKey: String?
    private var restoreTicket = UUID()
    private var fieldFocusKey: String?

    func capture() {
        fieldFocusKey = nil
        guard let key = currentKey, let scrollView else { return }
        offsets[key] = scrollView.contentOffset
    }

    func prepareForFieldFocus(key: String) {
        restoreTicket = UUID()
        fieldFocusKey = key
    }

    func attach(_ view: UIView, key: String) {
        var parent = view.superview
        while let candidate = parent, !(candidate is UIScrollView) { parent = candidate.superview }
        guard let scroll = parent as? UIScrollView else { return }
        guard currentKey != key || scrollView !== scroll else { return }
        scrollView = scroll; currentKey = key
        let ticket = UUID(); restoreTicket = ticket
        // An explicit validation target takes precedence over the saved scroll offset.
        guard fieldFocusKey != key else { return }
        // SwiftUI first lays out the new step; restore against its actual content size.
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, let scroll, self.restoreTicket == ticket, self.currentKey == key else { return }
            scroll.layoutIfNeeded()
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let desired = self.offsets[key]?.y ?? top
            scroll.setContentOffset(CGPoint(x: -scroll.adjustedContentInset.left,
                y: JourneyScrollRules.clamped(desired, minimum: top, maximum: bottom)), animated: false)
        }
    }
}

struct ClubScrollPositionProbe: UIViewRepresentable {
    let memory: ClubScrollMemory
    let key: String
    func makeUIView(context: Context) -> ClubLayoutProbeView { ClubLayoutProbeView(frame: .zero) }
    func updateUIView(_ view: ClubLayoutProbeView, context: Context) {
        view.changed = { [weak memory, weak view] in
            guard let memory, let view else { return }
            memory.attach(view, key: key)
        }
        view.scheduleCheck()
    }
}

@MainActor
final class ClubLayoutProbeView: UIView {
    var changed: (() -> Void)?
    private var scheduled = false
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layoutSubviews() { super.layoutSubviews(); scheduleCheck() }
    override func didMoveToWindow() { super.didMoveToWindow(); scheduleCheck() }
    override func didMoveToSuperview() { super.didMoveToSuperview(); scheduleCheck() }
    func scheduleCheck() {
        guard !scheduled else { return }; scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.scheduled = false; self.changed?()
        }
    }
}

/// Lifecycle alone cannot tell whether a loading card has scrolled out of view.
private struct ClubViewportProbe: UIViewRepresentable {
    let changed: (Bool) -> Void
    func makeUIView(context: Context) -> ClubViewportProbeView { ClubViewportProbeView(frame: .zero) }
    func updateUIView(_ view: ClubViewportProbeView, context: Context) {
        view.changed = changed; view.scheduleCheck()
    }
    static func dismantleUIView(_ view: ClubViewportProbeView, coordinator: ()) { view.stop() }
}

@MainActor
private final class ClubViewportProbeView: UIView {
    var changed: ((Bool) -> Void)?
    private var lastVisibility: Bool?
    private var observedScrolls: [ObjectIdentifier] = []
    private var observations: [NSKeyValueObservation] = []
    private var scheduled = false
    private var stopped = false
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layoutSubviews() { super.layoutSubviews(); scheduleCheck() }
    override func didMoveToWindow() { super.didMoveToWindow(); scheduleCheck() }
    override func didMoveToSuperview() { super.didMoveToSuperview(); scheduleCheck() }
    func stop() { stopped = true; observations.removeAll(); observedScrolls.removeAll(); changed = nil }
    func scheduleCheck() {
        guard !stopped, !scheduled else { return }; scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.scheduled = false; self.check()
        }
    }
    private func check() {
        guard !stopped else { return }
        guard window != nil else {
            observations.removeAll(); observedScrolls.removeAll()
            if lastVisibility != false { lastVisibility = false; changed?(false) }
            return
        }
        var ancestors: [UIView] = []; var parent = superview
        while let view = parent { ancestors.append(view); parent = view.superview }
        let scrolls = ancestors.compactMap { $0 as? UIScrollView }
        let identities = scrolls.map { ObjectIdentifier($0) }
        if identities != observedScrolls {
            observations.removeAll(); observedScrolls = identities
            observations = scrolls.map { scroll in
                scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.scheduleCheck() }
                }
            }
        }
        var visible = false
        if let window, !isHidden, !ancestors.contains(where: { $0.isHidden || $0.alpha < 0.01 }) {
            var region = window.bounds
            for ancestor in ancestors where ancestor.clipsToBounds || ancestor is UIScrollView {
                region = region.intersection(ancestor.convert(ancestor.bounds, to: window))
            }
            visible = JourneyVisibility.intersects(convert(bounds, to: window), region)
        }
        if lastVisibility != visible { lastVisibility = visible; changed?(visible) }
    }
}

extension View {
    func clubViewportVisibility(_ visible: Binding<Bool>) -> some View {
        background { ClubViewportProbe { value in if visible.wrappedValue != value { visible.wrappedValue = value } } }
    }
}

/// Wait for the previous native alert/sheet to finish dismissing before requesting a new sheet.
@MainActor
final class ClubPresentationGate: ObservableObject {
    private weak var root: UIViewController?
    func attach(_ view: UIView) { root = view.window?.rootViewController }
    private func hasPresentation(_ controller: UIViewController) -> Bool {
        controller.presentedViewController != nil || controller.isBeingPresented || controller.isBeingDismissed
            || controller.children.contains(where: hasPresentation)
    }
    func waitUntilReady() async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
            if let root, root.viewIfLoaded?.window != nil, !hasPresentation(root) { return true }
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return false }
        }
        return false
    }
}

struct ClubPresentationProbe: UIViewRepresentable {
    let gate: ClubPresentationGate
    func makeUIView(context: Context) -> ClubLayoutProbeView { ClubLayoutProbeView(frame: .zero) }
    func updateUIView(_ view: ClubLayoutProbeView, context: Context) {
        view.changed = { [weak gate, weak view] in if let view { gate?.attach(view) } }
        view.scheduleCheck()
    }
}
