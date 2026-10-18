import AppKit
import QuartzCore
import SwiftUI

/// The two needles and the lit PEAK lamps as Core Animation layers, driven by the display link.
///
/// Each frame only sets two rotation transforms and two opacities, with implicit animations
/// off: no SwiftUI view update and no redraw. Measured at about a quarter of the CPU of the
/// equivalent SwiftUI TimelineView (review of 84e35f2).
struct NeedleLayers: NSViewRepresentable {
    var tap: LevelTap
    var mode: MeterMode
    /// Levels are read only while playing; otherwise the needles fall back to rest.
    var playing: Bool
    /// Display link runs only while something can move and the window is visible.
    var live: Bool
    var color: Color

    func makeNSView(context: Context) -> NeedleLayerView { NeedleLayerView() }

    func updateNSView(_ view: NeedleLayerView, context: Context) {
        view.tap = tap
        view.mode = mode
        view.playing = playing
        view.needleColor = NSColor(color)
        view.live = live
    }
}

final class NeedleLayerView: NSView {
    var tap: LevelTap?
    var mode = MeterMode.vu
    var playing = false
    var live = false { didSet { link?.isPaused = !live } }
    var needleColor = NSColor.black {
        didSet { needles.forEach { $0.sublayers?.last?.backgroundColor = needleColor.cgColor } }
    }

    private let animator = MeterAnimator()
    private var link: CADisplayLink?
    private var needles: [CALayer] = []
    private var lamps: [CALayer] = []

    private static let face = CGRect(origin: .zero, size: MeterWindow.face)
    private static let length = MeterRenderer.radius + 16

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        for centerX in MeterRenderer.meterCenters(Self.face) {
            let pivot = ScaleGeometry(window: Self.face, centerX: centerX).pivot
            let needle = CALayer()
            needle.bounds = CGRect(x: 0, y: 0, width: 12, height: Self.length)
            needle.anchorPoint = CGPoint(x: 0.5, y: 1)
            needle.position = pivot
            // Shadow cast on the scale plate (two soft strokes), then the needle itself.
            for (width, dx, dy, alpha) in [(4.0, 4.0, 6.0, 0.07), (2.0, 4.0, 6.0, 0.12), (1.8, 0.0, 0.0, 1.0)] {
                let stroke = CALayer()
                stroke.frame = CGRect(x: 6 - width / 2 + dx, y: dy, width: width, height: Self.length)
                stroke.cornerRadius = width / 2
                stroke.backgroundColor = alpha < 1 ? NSColor.black.withAlphaComponent(alpha).cgColor : needleColor.cgColor
                needle.addSublayer(stroke)
            }
            needle.setAffineTransform(Self.rotation(for: 0))
            layer?.addSublayer(needle)
            needles.append(needle)

            let lamp = CALayer()
            lamp.bounds = CGRect(x: 0, y: 0, width: 9, height: 9)
            lamp.position = MeterRenderer.peakLampCenter(Self.face, centerX: centerX)
            lamp.cornerRadius = 4.5
            lamp.backgroundColor = NSColor(red: 1, green: 0.22, blue: 0.12, alpha: 1).cgColor
            lamp.shadowColor = NSColor.red.cgColor
            lamp.shadowOpacity = 0.8
            lamp.shadowRadius = 5
            lamp.shadowOffset = .zero
            lamp.shadowPath = CGPath(ellipseIn: lamp.bounds, transform: nil)
            lamp.opacity = 0
            layer?.addSublayer(lamp)
            lamps.append(lamp)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        link.isPaused = !live
        self.link = link
    }

    deinit { link?.invalidate() }

    @objc private func step(_ link: CADisplayLink) {
        let now = Date()
        animator.advance(to: now, tap: playing ? tap : nil, mode: mode)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        needles[0].setAffineTransform(Self.rotation(for: animator.left.position))
        needles[1].setAffineTransform(Self.rotation(for: animator.right.position))
        lamps[0].opacity = now < animator.peakUntil.left ? 1 : 0
        lamps[1].opacity = now < animator.peakUntil.right ? 1 : 0
        CATransaction.commit()
    }

    private static func rotation(for position: Double) -> CGAffineTransform {
        let degrees = -MeterRenderer.halfSweep + 2 * MeterRenderer.halfSweep * position
        return CGAffineTransform(rotationAngle: degrees * .pi / 180)
    }
}
