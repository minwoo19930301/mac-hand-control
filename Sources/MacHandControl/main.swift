import AppKit
import AVFoundation
import Vision
import ApplicationServices
import CoreGraphics
import CoreImage
import Darwin

private let minimumPointConfidence: VNConfidence = 0.28
private let minimumHandPointCount = 8
private let handEdgeMargin: CGFloat = 0.004
private let mirrorCameraFeed = true

private enum GesturePhase: String {
    case idle
    case pinched = "pinched"
    case swipe = "swipe"
    case pointer = "pointer"
    case click = "click"
    case scroll = "scroll"
    case fired = "fired"
    case cooldown
}

private enum GestureCommand: String {
    case none
    case enterFullscreen = "fullscreen: enter"
    case exitFullscreen = "fullscreen: exit"
    case moveLeft = "space: left"
    case moveRight = "space: right"
    case moveUp = "ignored: up"
    case moveDown = "ignored: down"
    case splitLeft = "split: left"
    case splitRight = "split: right"

    var requiresAccessibility: Bool {
        switch self {
        case .enterFullscreen, .exitFullscreen, .moveLeft, .moveRight, .splitLeft, .splitRight:
            return true
        case .none, .moveUp, .moveDown:
            return false
        }
    }
}

private enum KeyboardShortcut: String {
    case fullscreen = "Ctrl+Cmd+F"
    case spaceLeft = "Ctrl+Left"
    case spaceRight = "Ctrl+Right"

    var keyCode: CGKeyCode {
        switch self {
        case .fullscreen:
            return 3
        case .spaceLeft:
            return 123
        case .spaceRight:
            return 124
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .fullscreen:
            return [.maskControl, .maskCommand]
        case .spaceLeft, .spaceRight:
            return [.maskControl]
        }
    }

    var shouldActivateTargetApp: Bool {
        true
    }

    var appleScript: String {
        switch self {
        case .fullscreen:
            return #"tell application "System Events" to key code 3 using {control down, command down}"#
        case .spaceLeft:
            return #"tell application "System Events" to key code 123 using control down"#
        case .spaceRight:
            return #"tell application "System Events" to key code 124 using control down"#
        }
    }
}

private struct HandPose {
    let points: [VNHumanHandPoseObservation.JointName: CGPoint]

    func point(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
        points[joint]
    }

    var center: CGPoint? {
        let joints: [VNHumanHandPoseObservation.JointName] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let available = joints.compactMap { point($0) }

        guard !available.isEmpty else {
            return nil
        }

        let total = available.reduce(CGPoint.zero) { current, next in
            CGPoint(x: current.x + next.x, y: current.y + next.y)
        }

        return CGPoint(x: total.x / CGFloat(available.count), y: total.y / CGFloat(available.count))
    }
}

private struct GestureSnapshot {
    let phase: GesturePhase
    let command: GestureCommand
    let handCount: Int
    let details: String
    let canSendKeys: Bool

    func withPointerState(_ pointerState: (GesturePhase?, String?)) -> GestureSnapshot {
        guard command == .none,
              let pointerPhase = pointerState.0,
              let pointerDetails = pointerState.1
        else {
            return self
        }

        return GestureSnapshot(
            phase: pointerPhase,
            command: command,
            handCount: handCount,
            details: pointerDetails,
            canSendKeys: canSendKeys
        )
    }
}

private final class GesturePreferences {
    static let shared = GesturePreferences()

    private enum Key {
        static let pointer = "gestures.pointer.enabled"
        static let clicks = "gestures.clicks.enabled"
        static let scroll = "gestures.scroll.enabled"
        static let fullscreen = "gestures.fullscreen.enabled"
        static let space = "gestures.space.enabled"
        static let split = "gestures.split.enabled"
        static let gestureSensitivity = "gestures.sensitivity"
        static let pointerSensitivity = "gestures.pointer.sensitivity"
        static let scrollSensitivity = "gestures.scroll.sensitivity"
    }

    var pointerEnabled: Bool {
        get { bool(for: Key.pointer, defaultValue: true) }
        set { set(newValue, for: Key.pointer) }
    }

    var clicksEnabled: Bool {
        get { bool(for: Key.clicks, defaultValue: true) }
        set { set(newValue, for: Key.clicks) }
    }

    var scrollEnabled: Bool {
        get { bool(for: Key.scroll, defaultValue: true) }
        set { set(newValue, for: Key.scroll) }
    }

    var fullscreenEnabled: Bool {
        get { bool(for: Key.fullscreen, defaultValue: true) }
        set { set(newValue, for: Key.fullscreen) }
    }

    var spaceEnabled: Bool {
        get { bool(for: Key.space, defaultValue: true) }
        set { set(newValue, for: Key.space) }
    }

    var splitEnabled: Bool {
        get { bool(for: Key.split, defaultValue: true) }
        set { set(newValue, for: Key.split) }
    }

    var gestureSensitivity: Double {
        get { double(for: Key.gestureSensitivity, defaultValue: 1.55) }
        set { set(clamp(newValue, min: 0.60, max: 8.00), for: Key.gestureSensitivity) }
    }

    var pointerSensitivity: Double {
        get { double(for: Key.pointerSensitivity, defaultValue: 1.42) }
        set { set(clamp(newValue, min: 0.70, max: 2.40), for: Key.pointerSensitivity) }
    }

    var scrollSensitivity: Double {
        get { double(for: Key.scrollSensitivity, defaultValue: 1.85) }
        set { set(clamp(newValue, min: 0.50, max: 3.00), for: Key.scrollSensitivity) }
    }

    private init() {}

    private func bool(for key: String, defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultValue
        }

        return UserDefaults.standard.bool(forKey: key)
    }

    private func double(for key: String, defaultValue: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultValue
        }

        return UserDefaults.standard.double(forKey: key)
    }

    private func set(_ value: Bool, for key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func set(_ value: Double, for key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.min(Swift.max(value, lower), upper)
    }
}

private func poseDistance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
    hypot(first.x - second.x, first.y - second.y)
}

private func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
    guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else {
        return bounds
    }

    let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
    let width = contentSize.width * scale
    let height = contentSize.height * scale

    return CGRect(
        x: bounds.midX - width / 2,
        y: bounds.midY - height / 2,
        width: width,
        height: height
    )
}

private func aspectFillRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
    guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else {
        return bounds
    }

    let scale = max(bounds.width / contentSize.width, bounds.height / contentSize.height)
    let width = contentSize.width * scale
    let height = contentSize.height * scale

    return CGRect(
        x: bounds.midX - width / 2,
        y: bounds.midY - height / 2,
        width: width,
        height: height
    )
}

private final class CameraDisplayState {
    static let shared = CameraDisplayState()

    private let lock = NSLock()
    private var visibleRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    private init() {}

    var visibleNormalizedRect: CGRect {
        lock.lock()
        defer { lock.unlock() }
        return visibleRect
    }

    func updateVisibleNormalizedRect(imageRect: CGRect, bounds: CGRect) {
        guard imageRect.width > 0, imageRect.height > 0, bounds.width > 0, bounds.height > 0 else {
            return
        }

        let minX = max(0, (bounds.minX - imageRect.minX) / imageRect.width)
        let maxX = min(1, (bounds.maxX - imageRect.minX) / imageRect.width)
        let minY = max(0, (bounds.minY - imageRect.minY) / imageRect.height)
        let maxY = min(1, (bounds.maxY - imageRect.minY) / imageRect.height)
        let visible = CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )

        lock.lock()
        visibleRect = visible
        lock.unlock()
    }
}

private func displayPoint(_ point: CGPoint) -> CGPoint {
    mirrorCameraFeed ? CGPoint(x: 1 - point.x, y: point.y) : point
}

private func displayCenter(for hand: HandPose) -> CGPoint? {
    hand.center.map(displayPoint)
}

private func thumbIndexAnchorPoint(for hand: HandPose) -> CGPoint? {
    guard let thumbTip = hand.point(.thumbTip),
          let indexTip = hand.point(.indexTip)
    else {
        return nil
    }

    return CGPoint(
        x: (thumbTip.x + indexTip.x) / 2,
        y: (thumbTip.y + indexTip.y) / 2
    )
}

private final class OverlayWindowRegistry {
    static let shared = OverlayWindowRegistry()

    weak var window: NSWindow?

    private init() {}

    func hideBriefly(duration: TimeInterval = 0.65) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.hideBriefly(duration: duration)
            }
            return
        }

        guard let window, window.isVisible else {
            return
        }

        window.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            window.orderFrontRegardless()
        }
    }
}

private func isPinchedPose(_ hand: HandPose) -> Bool {
    guard
        let thumbTip = hand.point(.thumbTip),
        let indexTip = hand.point(.indexTip),
        let indexMCP = hand.point(.indexMCP),
        let littleMCP = hand.point(.littleMCP)
    else {
        return false
    }

    let pinchDistance = poseDistance(thumbTip, indexTip)
    let palmWidth = max(poseDistance(indexMCP, littleMCP), 0.001)
    return pinchDistance < palmWidth * 0.45
}

private func isOpenPose(_ hand: HandPose) -> Bool {
    guard
        let wrist = hand.point(.wrist),
        let indexTip = hand.point(.indexTip),
        let indexPIP = hand.point(.indexPIP),
        let indexMCP = hand.point(.indexMCP),
        let middleTip = hand.point(.middleTip),
        let middlePIP = hand.point(.middlePIP),
        let ringTip = hand.point(.ringTip),
        let ringPIP = hand.point(.ringPIP),
        let littleTip = hand.point(.littleTip),
        let littlePIP = hand.point(.littlePIP)
    else {
        return false
    }

    let palmScale = max(poseDistance(wrist, indexMCP), 0.001)
    let openStates = [
        poseDistance(wrist, indexTip) > poseDistance(wrist, indexPIP) + palmScale * 0.12,
        poseDistance(wrist, middleTip) > poseDistance(wrist, middlePIP) + palmScale * 0.1,
        poseDistance(wrist, ringTip) > poseDistance(wrist, ringPIP) + palmScale * 0.08,
        poseDistance(wrist, littleTip) > poseDistance(wrist, littlePIP) + palmScale * 0.08
    ]

    return openStates.filter { $0 }.count >= 2
}

private func isFistPose(_ hand: HandPose) -> Bool {
    guard
        let curledCount = curledFingerCount(hand),
        fingerCurled(hand, tip: .indexTip, pip: .indexPIP, mcp: .indexMCP)
    else {
        return false
    }

    return curledCount >= 3
}

private func curledFingerCount(_ hand: HandPose) -> Int? {
    guard
        let wrist = hand.point(.wrist),
        let indexTip = hand.point(.indexTip),
        let indexPIP = hand.point(.indexPIP),
        let indexMCP = hand.point(.indexMCP),
        let middleTip = hand.point(.middleTip),
        let middlePIP = hand.point(.middlePIP),
        let ringTip = hand.point(.ringTip),
        let ringPIP = hand.point(.ringPIP),
        let littleTip = hand.point(.littleTip),
        let littlePIP = hand.point(.littlePIP)
    else { return nil }

    let palmScale = max(poseDistance(wrist, indexMCP), 0.001)
    let curledStates = [
        poseDistance(wrist, indexTip) < poseDistance(wrist, indexPIP) + palmScale * 0.12,
        poseDistance(wrist, middleTip) < poseDistance(wrist, middlePIP) + palmScale * 0.12,
        poseDistance(wrist, ringTip) < poseDistance(wrist, ringPIP) + palmScale * 0.12,
        poseDistance(wrist, littleTip) < poseDistance(wrist, littlePIP) + palmScale * 0.12
    ]

    return curledStates.filter { $0 }.count
}

private func isGesturePinchedPose(_ hand: HandPose) -> Bool {
    isPinchedPose(hand)
}

private func isSwipeOpenPose(_ hand: HandPose) -> Bool {
    isOpenPose(hand) && !isPinchedPose(hand) && !isFistPose(hand)
}

private struct TimedPoint {
    let time: CFTimeInterval
    let point: CGPoint
}

private func fingerExtended(
    _ hand: HandPose,
    tip: VNHumanHandPoseObservation.JointName,
    pip: VNHumanHandPoseObservation.JointName,
    mcp: VNHumanHandPoseObservation.JointName
) -> Bool {
    guard
        let wrist = hand.point(.wrist),
        let tipPoint = hand.point(tip),
        let pipPoint = hand.point(pip),
        let mcpPoint = hand.point(mcp)
    else {
        return false
    }

    let palmScale = max(poseDistance(wrist, mcpPoint), 0.001)
    return poseDistance(wrist, tipPoint) > poseDistance(wrist, pipPoint) + palmScale * 0.12
}

private func fingerStronglyExtended(
    _ hand: HandPose,
    tip: VNHumanHandPoseObservation.JointName,
    pip: VNHumanHandPoseObservation.JointName,
    mcp: VNHumanHandPoseObservation.JointName
) -> Bool {
    guard
        let wrist = hand.point(.wrist),
        let tipPoint = hand.point(tip),
        let pipPoint = hand.point(pip),
        let mcpPoint = hand.point(mcp)
    else {
        return false
    }

    let palmScale = max(poseDistance(wrist, mcpPoint), 0.001)
    let tipDistance = poseDistance(wrist, tipPoint)
    return tipDistance > poseDistance(wrist, pipPoint) + palmScale * 0.28
        && tipDistance > poseDistance(wrist, mcpPoint) + palmScale * 0.68
}

private func fingerCurled(
    _ hand: HandPose,
    tip: VNHumanHandPoseObservation.JointName,
    pip: VNHumanHandPoseObservation.JointName,
    mcp: VNHumanHandPoseObservation.JointName
) -> Bool {
    guard
        let wrist = hand.point(.wrist),
        let tipPoint = hand.point(tip),
        let pipPoint = hand.point(pip),
        let mcpPoint = hand.point(mcp)
    else {
        return false
    }

    let palmScale = max(poseDistance(wrist, mcpPoint), 0.001)
    return poseDistance(wrist, tipPoint) < poseDistance(wrist, pipPoint) + palmScale * 0.15
}

private func fingerNotExtendedForPointer(
    _ hand: HandPose,
    tip: VNHumanHandPoseObservation.JointName,
    pip: VNHumanHandPoseObservation.JointName,
    mcp: VNHumanHandPoseObservation.JointName,
    indexTipDistance: CGFloat
) -> Bool {
    guard
        let wrist = hand.point(.wrist),
        let tipPoint = hand.point(tip),
        let pipPoint = hand.point(pip),
        let mcpPoint = hand.point(mcp)
    else {
        return false
    }

    let palmScale = max(poseDistance(wrist, mcpPoint), 0.001)
    let tipDistance = poseDistance(wrist, tipPoint)
    return tipDistance < poseDistance(wrist, pipPoint) + palmScale * 0.10
        || tipDistance < indexTipDistance - palmScale * 0.36
}

private func palmWidth(for hand: HandPose) -> CGFloat? {
    guard let indexMCP = hand.point(.indexMCP),
          let littleMCP = hand.point(.littleMCP)
    else {
        return nil
    }

    return max(poseDistance(indexMCP, littleMCP), 0.001)
}

private func isThreeFingerPinchedPose(_ hand: HandPose) -> Bool {
    guard
        let thumbTip = hand.point(.thumbTip),
        let indexTip = hand.point(.indexTip),
        let middleTip = hand.point(.middleTip),
        let width = palmWidth(for: hand)
    else {
        return false
    }

    return poseDistance(thumbTip, indexTip) < width * 0.58
        && poseDistance(thumbTip, middleTip) < width * 0.64
        && poseDistance(indexTip, middleTip) < width * 0.70
}

private func isIndexPointerPose(_ hand: HandPose) -> Bool {
    isThumbIndexPointerPose(hand) && !isPinchedPose(hand) && !isFistPose(hand)
}

private func isThumbIndexPointerPose(_ hand: HandPose) -> Bool {
    guard
        let wrist = hand.point(.wrist),
        let thumbTip = hand.point(.thumbTip),
        let thumbIP = hand.point(.thumbIP),
        let thumbMP = hand.point(.thumbMP),
        let indexTip = hand.point(.indexTip),
        let indexMCP = hand.point(.indexMCP),
        let littleMCP = hand.point(.littleMCP),
        fingerExtended(hand, tip: .indexTip, pip: .indexPIP, mcp: .indexMCP)
    else {
        return false
    }

    let palmWidth = max(poseDistance(indexMCP, littleMCP), 0.001)
    let indexTipDistance = poseDistance(wrist, indexTip)
    let thumbIndexDistance = poseDistance(thumbTip, indexTip)
    let thumbReach = poseDistance(thumbTip, thumbMP)
    let thumbAwayFromPalm = poseDistance(thumbTip, indexMCP) > palmWidth * 0.75
    let thumbOpen = thumbIndexDistance > palmWidth * 1.05
        && thumbReach > poseDistance(thumbIP, thumbMP) + palmWidth * 0.18
        && thumbAwayFromPalm
    let foldedOtherFingers = [
        fingerNotExtendedForPointer(hand, tip: .middleTip, pip: .middlePIP, mcp: .middleMCP, indexTipDistance: indexTipDistance),
        fingerNotExtendedForPointer(hand, tip: .ringTip, pip: .ringPIP, mcp: .ringMCP, indexTipDistance: indexTipDistance),
        fingerNotExtendedForPointer(hand, tip: .littleTip, pip: .littlePIP, mcp: .littleMCP, indexTipDistance: indexTipDistance)
    ].filter { $0 }.count

    return thumbOpen && foldedOtherFingers >= 2
}

private enum PrimaryHandGesture {
    case none
    case pointer
    case pointerPinch
    case fist
    case open

    var label: String {
        switch self {
        case .none:
            return ""
        case .pointer:
            return "POINTER"
        case .pointerPinch:
            return "PINCH"
        case .fist:
            return "FIST"
        case .open:
            return "OPEN"
        }
    }

    var color: NSColor {
        switch self {
        case .none:
            return .clear
        case .pointer:
            return .systemBlue
        case .pointerPinch:
            return .systemYellow
        case .fist:
            return .systemRed
        case .open:
            return .systemGreen
        }
    }
}

private func primaryGesture(for hand: HandPose) -> PrimaryHandGesture {
    if isFistPose(hand) {
        return .fist
    }

    if isIndexPointerPose(hand) {
        return .pointer
    }

    if isSwipeOpenPose(hand) {
        return .open
    }

    return .none
}

private final class PointerGestureController {
    private let actionRunner: MacActionRunner
    private let preferences = GesturePreferences.shared
    private let requiredPointerStableFrames = 3
    private let pointerDeadzone: CGFloat = 0.006
    private let scrollHoldDelay: CFTimeInterval = 0.04
    private let scrollMoveThreshold: CGFloat = 0.010
    private let pointerGraceDuration: CFTimeInterval = 0.10
    private let pointerHoldDuration: CFTimeInterval = 0.80
    private let doublePinchInterval: CFTimeInterval = 0.36
    private let dragHoldDuration: CFTimeInterval = 1.50
    private let handScaleReference: CGFloat = 0.16

    private var wasPointerPinching = false
    private var pointerPinchStartedAt: CFTimeInterval = 0
    private var isDragging = false
    private var lastPinchReleaseAt: CFTimeInterval?
    private var pendingSingleClick: DispatchWorkItem?

    private var lastMoveAt: CFTimeInterval = 0
    private var pointerStableFrames = 0
    private var pointerLastSeenAt: CFTimeInterval = 0
    private var strictPointerLastSeenAt: CFTimeInterval = 0
    private var pointerFrozenUntil: CFTimeInterval = 0
    private var filteredPointerPoint: CGPoint?
    private var lastSentPointerPoint: CGPoint?
    private var lastStableCursorPoint: CGPoint?
    private var lastStableCursorPointAt: CFTimeInterval = 0
    private var activeClickPoint: CGPoint?
    private var pendingSingleClickPoint: CGPoint?
    private var calibratedHandScale: CGFloat?
    private var currentGestureSensitivity: CGFloat = CGFloat(GesturePreferences.shared.gestureSensitivity)

    private var isScrollingFist = false
    private var fistStartedAt: CFTimeInterval = 0
    private var lastFistPoint: CGPoint?
    private var lockedScrollDirection: CGFloat = 0
    private var lockedScrollDirectionUntil: CFTimeInterval = 0

    init(actionRunner: MacActionRunner) {
        self.actionRunner = actionRunner
    }

    func update(hands: [HandPose], now: CFTimeInterval = CACurrentMediaTime()) -> (GesturePhase?, String?) {
        guard let hand = hands.first else {
            resetPointer()
            resetFistScroll()
            finishPointerPinch(now: now)
            resetDistanceCalibration()
            return (nil, nil)
        }

        var phase: GesturePhase? = nil
        var details: String? = nil
        let gestureSensitivity = calibratedGestureSensitivity(for: hand)

        let pointerPose = isIndexPointerPose(hand)
        let pinchPose = isPinchedPose(hand)
        if pointerPose {
            strictPointerLastSeenAt = now
        }

        let hasRecentPointerAnchor = lastStableCursorPoint != nil
            && now - lastStableCursorPointAt <= pointerHoldDuration
        let clickPinchPose = pinchPose
            && (wasPointerPinching || (hasRecentPointerAnchor && now - strictPointerLastSeenAt <= pointerHoldDuration))
        let shouldTrackPointer = now >= pointerFrozenUntil && pointerPose
        let fistPose = (isFistPose(hand) || (pinchPose && !clickPinchPose)) && !shouldTrackPointer

        if clickPinchPose {
            if !wasPointerPinching {
                activeClickPoint = lastStableCursorPoint
                pointerPinchStartedAt = now
            }
            resetPointer()
            resetFistScroll()
            wasPointerPinching = true
            pointerFrozenUntil = max(pointerFrozenUntil, now + 0.20)
            phase = .click
            details = "pinch: click"
            if now - pointerPinchStartedAt >= dragHoldDuration {
                startOrUpdateDrag(hand: hand, sensitivity: gestureSensitivity)
                details = "pinch hold: drag"
            }
        } else {
            finishPointerPinch(now: now)
        }

        if preferences.pointerEnabled, shouldTrackPointer, let point = thumbIndexAnchorPoint(for: hand).map(displayPoint) {
            resetFistScroll()
            pointerLastSeenAt = now
            pointerStableFrames = min(pointerStableFrames + 1, requiredPointerStableFrames)
            if pointerStableFrames >= requiredPointerStableFrames {
                if now - lastMoveAt > 1.0 / 50.0 {
                    let filtered = filteredPointer(for: point)
                    if shouldSendPointer(filtered) {
                        if let cursorPoint = actionRunner.moveCursor(to: filtered, sensitivity: gestureSensitivity) {
                            lastStableCursorPoint = cursorPoint
                            lastStableCursorPointAt = now
                        }
                        lastSentPointerPoint = filtered
                    }
                    lastMoveAt = now
                }
                if phase == nil {
                    phase = .pointer
                    details = "thumb-index pointer: move cursor"
                }
            } else {
                if phase == nil {
                    phase = .pointer
                    details = "hold thumb-index pointer"
                }
            }
        } else if !clickPinchPose, now - pointerLastSeenAt > pointerGraceDuration {
            resetPointer()
        }

        if preferences.scrollEnabled, fistPose, let center = displayCenter(for: hand) {
            resetPointer()
            handleFistScroll(center, now: now, sensitivity: gestureSensitivity)
            phase = .scroll
            details = "fist: scroll"
        } else {
            resetFistScroll()
        }

        return (phase, details)
    }

    private func finishPointerPinch(now: CFTimeInterval) {
        guard wasPointerPinching else {
            return
        }

        wasPointerPinching = false
        pointerFrozenUntil = max(pointerFrozenUntil, now + doublePinchInterval + 0.12)
        let clickPoint = activeClickPoint ?? lastStableCursorPoint
        activeClickPoint = nil
        pointerPinchStartedAt = 0
        if isDragging {
            actionRunner.endDrag()
            isDragging = false
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            pendingSingleClickPoint = nil
            lastPinchReleaseAt = nil
            return
        }
        guard preferences.clicksEnabled else {
            return
        }

        if let lastPinchReleaseAt, now - lastPinchReleaseAt <= doublePinchInterval {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            let rightClickPoint = clickPoint ?? pendingSingleClickPoint
            pendingSingleClickPoint = nil
            self.lastPinchReleaseAt = nil
            actionRunner.rightClick(at: rightClickPoint)
            return
        }

        lastPinchReleaseAt = now
        let scheduledClickPoint = clickPoint
        pendingSingleClickPoint = scheduledClickPoint
        let click = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.actionRunner.leftClick(at: scheduledClickPoint)
            self.pendingSingleClick = nil
            self.pendingSingleClickPoint = nil
            self.lastPinchReleaseAt = nil
        }
        pendingSingleClick = click
        DispatchQueue.main.asyncAfter(deadline: .now() + doublePinchInterval, execute: click)
    }

    private func handleFistScroll(_ point: CGPoint, now: CFTimeInterval, sensitivity: CGFloat) {
        guard let last = lastFistPoint else {
            isScrollingFist = true
            fistStartedAt = now
            lastFistPoint = point
            return
        }

        let dy = point.y - last.y
        lastFistPoint = point

        guard isScrollingFist,
              now - fistStartedAt >= scrollHoldDelay,
              abs(dy) > scrollMoveThreshold
        else {
            return
        }

        let direction: CGFloat = dy > 0 ? 1 : -1
        if lockedScrollDirection != 0,
           direction != lockedScrollDirection,
           now < lockedScrollDirectionUntil {
            return
        }

        lockedScrollDirection = direction
        lockedScrollDirectionUntil = now + 0.50
        actionRunner.scroll(verticalDelta: dy, sensitivity: sensitivity)
    }

    private func startOrUpdateDrag(hand: HandPose, sensitivity: CGFloat) {
        guard let point = thumbIndexAnchorPoint(for: hand).map(displayPoint) else {
            return
        }

        if !isDragging {
            actionRunner.beginDrag(at: activeClickPoint ?? lastStableCursorPoint)
            isDragging = true
        }

        if let cursorPoint = actionRunner.drag(to: point, sensitivity: sensitivity) {
            lastStableCursorPoint = cursorPoint
            lastStableCursorPointAt = CACurrentMediaTime()
        }
    }

    private func resetPointer() {
        pointerStableFrames = 0
        filteredPointerPoint = nil
        lastSentPointerPoint = nil
    }

    private func resetDistanceCalibration() {
        calibratedHandScale = nil
        currentGestureSensitivity = CGFloat(preferences.gestureSensitivity)
    }

    private func calibratedGestureSensitivity(for hand: HandPose) -> CGFloat {
        if calibratedHandScale == nil, let scale = palmWidth(for: hand) {
            calibratedHandScale = scale
        }

        let base = CGFloat(preferences.gestureSensitivity)
        guard let calibratedHandScale else {
            currentGestureSensitivity = base
            return base
        }

        let distanceMultiplier = min(max(pow(calibratedHandScale / handScaleReference, 0.65), 0.65), 1.75)
        currentGestureSensitivity = base * distanceMultiplier
        return currentGestureSensitivity
    }

    private func resetFistScroll() {
        isScrollingFist = false
        lastFistPoint = nil
    }

    private func filteredPointer(for point: CGPoint) -> CGPoint {
        let smoothing: CGFloat = 0.38
        guard let current = filteredPointerPoint else {
            filteredPointerPoint = point
            return point
        }

        let filtered = CGPoint(
            x: current.x + (point.x - current.x) * smoothing,
            y: current.y + (point.y - current.y) * smoothing
        )
        filteredPointerPoint = filtered
        return filtered
    }

    private func shouldSendPointer(_ point: CGPoint) -> Bool {
        guard let lastSentPointerPoint else {
            return true
        }

        return poseDistance(point, lastSentPointerPoint) >= pointerDeadzone
    }
}

private final class GestureDetector {
    private let preferences = GesturePreferences.shared
    private var phase: GesturePhase = .idle
    private var armedAt: CFTimeInterval = 0
    private var cooldownUntil: CFTimeInterval = 0
    private var lastCommandUntil: CFTimeInterval = 0
    private var lastCommand: GestureCommand = .none
    private var twoHandPinchReady = false
    private var initialPinchSpan: CGFloat?
    private var openSwipeReady = false
    private var openSwipeInitialCenters: [CGPoint] = []
    private var swipeReady = false
    private var swipeTrail: [TimedPoint] = []

    func update(hands: [HandPose], now: CFTimeInterval = CACurrentMediaTime()) -> (GestureSnapshot, GestureCommand?) {
        if now > lastCommandUntil {
            lastCommand = .none
        }

        guard !hands.isEmpty else {
            if now > cooldownUntil {
                phase = .idle
                twoHandPinchReady = false
                initialPinchSpan = nil
                resetTwoHandOpenSwipeTracking()
            }
            return (snapshot(hands: hands, details: "show your hand"), nil)
        }

        if now < cooldownUntil {
            phase = .cooldown
            return (snapshot(hands: hands, details: "cooling down"), nil)
        }

        let visibleHands = Array(hands.prefix(2))
        let isTwoHandPinching = preferences.fullscreenEnabled && visibleHands.count >= 2 && visibleHands.allSatisfy(isGesturePinchedPose)
        let isTwoHandOpen = false
        let swipeHands = preferences.spaceEnabled && visibleHands.count == 1 ? visibleHands.filter(isSwipeOpenPose) : []

        if isTwoHandPinching, let pinchSpan = twoHandPinchSpan(for: visibleHands) {
            if phase != .pinched {
                phase = .pinched
                armedAt = now
                initialPinchSpan = pinchSpan
                twoHandPinchReady = false
                resetTwoHandOpenSwipeTracking()
            }

            if now - armedAt >= 0.06 {
                twoHandPinchReady = true
            }

            if twoHandPinchReady,
               let initialPinchSpan,
               let command = twoHandPinchCommand(from: initialPinchSpan, to: pinchSpan) {
                phase = .fired
                self.initialPinchSpan = nil
                twoHandPinchReady = false
                cooldownUntil = now + 1.15
                lastCommand = command
                lastCommandUntil = now + 1.0
                return (snapshot(hands: hands, details: command.rawValue), command)
            }

            let details = twoHandPinchReady ? "quick spread / squeeze" : "flick both pinches"
            return (snapshot(hands: hands, details: details), nil)
        }

        if phase == .pinched {
            phase = .idle
            initialPinchSpan = nil
            twoHandPinchReady = false
        }

        if swipeHands.count == 1,
           let swipeHand = swipeHands.first,
           let center = displayCenter(for: swipeHand) {
                if phase != .swipe {
                    phase = .swipe
                    armedAt = now
                    swipeReady = false
                    swipeTrail = [TimedPoint(time: now, point: center)]
                } else {
                    appendSwipePoint(center, now: now)
                }

                if now - armedAt >= 0.10 {
                    swipeReady = true
                }

                if swipeReady, let command = swipeCommandFromTrail() {
                    phase = .fired
                    resetTwoHandOpenSwipeTracking()
                    cooldownUntil = now + 1.05
                    lastCommand = command
                    lastCommandUntil = now + 1.0
                    return (snapshot(hands: hands, details: "one-hand space swipe"), command)
                }

                return (snapshot(hands: hands, details: swipeReady ? "one-hand open swipe" : "show open palm"), nil)
        }

        let lostSwipeHand = phase == .swipe && !isTwoHandOpen && swipeHands.count != 1
        if (phase == .pinched && now - armedAt > 2.0) || lostSwipeHand {
            phase = .idle
            twoHandPinchReady = false
            initialPinchSpan = nil
            resetTwoHandOpenSwipeTracking()
        }

        let details: String
        switch phase {
        case .pinched:
            details = "quick spread / squeeze"
        case .swipe:
            details = "open swipe"
        default:
            details = "pinch fullscreen / one-hand space / thumb-index pointer"
        }
        return (snapshot(hands: hands, details: details), nil)
    }

    private func snapshot(hands: [HandPose], details: String) -> GestureSnapshot {
        GestureSnapshot(
            phase: phase,
            command: lastCommand,
            handCount: hands.count,
            details: details,
            canSendKeys: MacActionRunner.hasAccessibilityPermission
        )
    }

    private func appendSwipePoint(_ point: CGPoint, now: CFTimeInterval) {
        swipeTrail.append(TimedPoint(time: now, point: point))
        swipeTrail = swipeTrail.filter { now - $0.time <= 0.85 }
    }

    private func resetSwipeTracking() {
        swipeReady = false
        swipeTrail.removeAll()
    }

    private func resetTwoHandOpenSwipeTracking() {
        openSwipeReady = false
        openSwipeInitialCenters.removeAll()
        resetSwipeTracking()
    }

    private func twoHandPinchSpan(for hands: [HandPose]) -> CGFloat? {
        guard hands.count >= 2,
              let first = displayCenter(for: hands[0]),
              let second = displayCenter(for: hands[1])
        else {
            return nil
        }

        return poseDistance(first, second)
    }

    private func twoHandPinchCommand(from initialSpan: CGFloat, to currentSpan: CGFloat) -> GestureCommand? {
        let delta = currentSpan - initialSpan
        let threshold = max(initialSpan * 0.16, 0.055)

        if delta > threshold {
            return .enterFullscreen
        }

        if delta < -threshold {
            return .exitFullscreen
        }

        return nil
    }

    private func twoHandCenters(for hands: [HandPose]) -> [CGPoint]? {
        guard hands.count >= 2,
              let first = displayCenter(for: hands[0]),
              let second = displayCenter(for: hands[1])
        else {
            return nil
        }

        return [first, second]
    }

    private func twoHandSplitCommand(from startCenters: [CGPoint], to currentCenters: [CGPoint]) -> GestureCommand? {
        guard startCenters.count >= 2, currentCenters.count >= 2 else {
            return nil
        }

        let firstDelta = CGPoint(
            x: currentCenters[0].x - startCenters[0].x,
            y: currentCenters[0].y - startCenters[0].y
        )
        let secondDelta = CGPoint(
            x: currentCenters[1].x - startCenters[1].x,
            y: currentCenters[1].y - startCenters[1].y
        )
        let averageDx = (firstDelta.x + secondDelta.x) / 2
        let averageDy = (firstDelta.y + secondDelta.y) / 2
        let threshold: CGFloat = 0.065

        guard abs(averageDx) > threshold,
              abs(averageDx) > abs(averageDy) * 1.45,
              firstDelta.x.sign == secondDelta.x.sign
        else {
            return nil
        }

        return averageDx < 0 ? .splitLeft : .splitRight
    }

    private func swipeCommandFromTrail() -> GestureCommand? {
        guard let first = swipeTrail.first, let last = swipeTrail.last, swipeTrail.count >= 3 else {
            return nil
        }

        let dx = last.point.x - first.point.x
        let dy = last.point.y - first.point.y
        let threshold: CGFloat = 0.085

        guard max(abs(dx), abs(dy)) > threshold else {
            return nil
        }

        guard abs(dx) > abs(dy) * 1.35 else {
            return nil
        }

        return dx > 0 ? .moveLeft : .moveRight
    }
}

private final class TargetAppTracker {
    static let shared = TargetAppTracker()

    private var lastExternalApp: NSRunningApplication?
    private let ownBundleIdentifier = Bundle.main.bundleIdentifier
    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier

    private init() {}

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    func activateLastExternalIfNeeded() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownBundleIdentifier else {
            return false
        }

        guard let target = targetApplication() else {
            return false
        }

        return target.activate(options: [])
    }

    func targetApplication() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != ownBundleIdentifier {
            return frontmost
        }

        return topVisibleExternalApplication() ?? lastExternalApp
    }

    private func topVisibleExternalApplication() -> NSRunningApplication? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard
                let pidNumber = window[kCGWindowOwnerPID as String] as? NSNumber,
                pidNumber.intValue != ownProcessIdentifier,
                let layerNumber = window[kCGWindowLayer as String] as? NSNumber,
                layerNumber.intValue == 0
            else {
                continue
            }

            if let alphaNumber = window[kCGWindowAlpha as String] as? NSNumber,
               alphaNumber.doubleValue <= 0 {
                continue
            }

            if let bounds = window[kCGWindowBounds as String] as? [String: Any],
               let width = bounds["Width"] as? NSNumber,
               let height = bounds["Height"] as? NSNumber,
               (width.doubleValue < 160 || height.doubleValue < 120) {
                continue
            }

            if let app = NSRunningApplication(processIdentifier: pidNumber.int32Value),
               app.bundleIdentifier != ownBundleIdentifier {
                return app
            }
        }

        return nil
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.bundleIdentifier != ownBundleIdentifier
        else {
            return
        }

        lastExternalApp = app
    }
}

private final class SpaceSwitcher {
    static let shared = SpaceSwitcher()

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SetCurrentSpace = @convention(c) (Int32, CFString, UInt64) -> Int32

    private let mainConnection: MainConnection?
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpaces?
    private let setCurrentSpace: SetCurrentSpace?
    private let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            mainConnection = nil
            copyManagedDisplaySpaces = nil
            setCurrentSpace = nil
            return
        }

        mainConnection = dlsym(handle, "CGSMainConnectionID").map {
            unsafeBitCast($0, to: MainConnection.self)
        }
        copyManagedDisplaySpaces = dlsym(handle, "CGSCopyManagedDisplaySpaces").map {
            unsafeBitCast($0, to: CopyManagedDisplaySpaces.self)
        }
        setCurrentSpace = dlsym(handle, "CGSManagedDisplaySetCurrentSpace").map {
            unsafeBitCast($0, to: SetCurrentSpace.self)
        }
    }

    func moveHorizontally(_ offset: Int, targetApp: NSRunningApplication?) -> Bool {
        guard offset != 0,
              let mainConnection,
              let copyManagedDisplaySpaces,
              let setCurrentSpace
        else {
            return false
        }

        let connection = mainConnection()
        guard let rawDisplays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }

        var displays = rawDisplays
        if let preferredDisplay = preferredDisplayIdentifier(in: rawDisplays, targetApp: targetApp) ?? mainDisplayIdentifier(),
           let index = displays.firstIndex(where: { ($0["Display Identifier"] as? String) == preferredDisplay }) {
            let display = displays.remove(at: index)
            displays.insert(display, at: 0)
        }

        for display in displays {
            guard
                let displayIdentifier = display["Display Identifier"] as? String,
                let currentSpace = display["Current Space"] as? [String: Any],
                let currentSpaceID = managedSpaceID(from: currentSpace),
                let spaces = display["Spaces"] as? [[String: Any]]
            else {
                continue
            }

            let spaceIDs = spaces.compactMap(managedSpaceID)
            guard let currentIndex = spaceIDs.firstIndex(of: currentSpaceID) else {
                continue
            }

            let targetIndex = currentIndex + offset
            guard spaceIDs.indices.contains(targetIndex) else {
                continue
            }

            return setCurrentSpace(connection, displayIdentifier as CFString, spaceIDs[targetIndex]) == 0
        }

        return false
    }

    private func preferredDisplayIdentifier(in displays: [[String: Any]], targetApp: NSRunningApplication?) -> String? {
        let knownDisplayIdentifiers = Set(displays.compactMap { $0["Display Identifier"] as? String })

        if let bounds = windowBounds(for: targetApp),
           let identifier = displayIdentifier(containing: bounds),
           knownDisplayIdentifiers.contains(identifier) {
            return identifier
        }

        if let bounds = topVisibleExternalWindowBounds(),
           let identifier = displayIdentifier(containing: bounds),
           knownDisplayIdentifiers.contains(identifier) {
            return identifier
        }

        return nil
    }

    private func windowBounds(for app: NSRunningApplication?) -> CGRect? {
        guard let app else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = focusedWindow(in: appElement) ?? firstWindow(in: appElement),
              let origin = pointAttribute("AXPosition", from: window),
              let size = sizeAttribute("AXSize", from: window)
        else {
            return nil
        }

        return CGRect(origin: origin, size: size)
    }

    private func topVisibleExternalWindowBounds() -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard
                let pidNumber = window[kCGWindowOwnerPID as String] as? NSNumber,
                pidNumber.intValue != ownProcessIdentifier,
                let layerNumber = window[kCGWindowLayer as String] as? NSNumber,
                layerNumber.intValue == 0,
                let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                let x = boundsDictionary["X"] as? NSNumber,
                let y = boundsDictionary["Y"] as? NSNumber,
                let width = boundsDictionary["Width"] as? NSNumber,
                let height = boundsDictionary["Height"] as? NSNumber,
                width.doubleValue >= 160,
                height.doubleValue >= 120
            else {
                continue
            }

            return CGRect(
                x: x.doubleValue,
                y: y.doubleValue,
                width: width.doubleValue,
                height: height.doubleValue
            )
        }

        return nil
    }

    private func displayIdentifier(containing bounds: CGRect) -> String? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        for screen in NSScreen.screens {
            guard
                let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else {
                continue
            }

            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            guard CGDisplayBounds(displayID).contains(center),
                  let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
                  let identifier = CFUUIDCreateString(nil, uuid) as String?
            else {
                continue
            }

            return identifier
        }

        return nil
    }

    private func mainDisplayIdentifier() -> String? {
        guard
            let screen = NSScreen.main,
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }

        return CFUUIDCreateString(nil, uuid) as String?
    }

    private func managedSpaceID(from space: [String: Any]) -> UInt64? {
        (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }

    private func focusedWindow(in appElement: AXUIElement) -> AXUIElement? {
        elementAttribute("AXFocusedWindow", from: appElement)
    }

    private func firstWindow(in appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, "AXWindows" as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else {
            return nil
        }

        return windows.first
    }

    private func pointAttribute(_ name: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue((value as! AXValue), .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private func sizeAttribute(_ name: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue((value as! AXValue), .cgSize, &size) else {
            return nil
        }

        return size
    }

    private func elementAttribute(_ name: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let elementValue = value,
              CFGetTypeID(elementValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (elementValue as! AXUIElement)
    }
}

private final class MacActionRunner {
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    private var lastCursorPoint: CGPoint?

    func requestAccessibilityIfNeeded() {
        guard !Self.hasAccessibilityPermission else {
            return
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func sendKeyboardShortcut(_ shortcut: KeyboardShortcut, completion: @escaping (Bool) -> Void) {
        guard Self.hasAccessibilityPermission else {
            requestAccessibilityIfNeeded()
            completion(false)
            return
        }

        if shortcut.shouldActivateTargetApp {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion(false)
                    return
                }

                let targetApp = TargetAppTracker.shared.targetApplication()
                OverlayWindowRegistry.shared.hideBriefly(duration: 0.75)
                targetApp?.activate(options: [.activateAllWindows])

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
                    guard let self else {
                        completion(false)
                        return
                    }

                    self.sendShortcutWithSystemEvents(shortcut, completion: completion)
                }
            }
            return
        }

        sendShortcutWithSystemEvents(shortcut, completion: completion)
    }

    private func sendShortcutWithSystemEvents(_ shortcut: KeyboardShortcut, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", shortcut.appleScript]

            do {
                try process.run()
                process.waitUntilExit()
                DispatchQueue.main.async {
                    completion(process.terminationStatus == 0)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }

    func run(_ command: GestureCommand) {
        if command == .enterFullscreen || command == .exitFullscreen {
            setFullscreen(enter: command == .enterFullscreen)
            return
        }

        if command == .moveLeft {
            sendKeyboardShortcut(.spaceLeft) { _ in }
            return
        }

        if command == .moveRight {
            sendKeyboardShortcut(.spaceRight) { _ in }
            return
        }

        if command == .moveUp || command == .moveDown {
            return
        }

        if command == .splitLeft || command == .splitRight {
            tileTargetWindow(left: command == .splitLeft)
            return
        }

        guard Self.hasAccessibilityPermission else {
            return
        }

        let keyCode: CGKeyCode
        let flags: CGEventFlags

        switch command {
        case .none:
            return
        case .enterFullscreen, .exitFullscreen:
            keyCode = 3
            flags = [.maskControl, .maskCommand]
        case .moveLeft:
            keyCode = 123
            flags = [.maskControl]
        case .moveRight:
            keyCode = 124
            flags = [.maskControl]
        case .moveDown:
            keyCode = 125
            flags = [.maskControl]
        case .moveUp:
            keyCode = 126
            flags = [.maskControl]
        case .splitLeft, .splitRight:
            return
        }

        if command != .enterFullscreen && command != .exitFullscreen {
            pressHotKey(keyCode: keyCode, flags: flags)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            let targetApp = TargetAppTracker.shared.targetApplication()
            OverlayWindowRegistry.shared.hideBriefly()
            targetApp?.activate(options: [.activateAllWindows])

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self else {
                    return
                }

                self.pressHotKey(keyCode: keyCode, flags: flags)
            }
        }
    }

    private func setFullscreen(enter: Bool) {
        guard Self.hasAccessibilityPermission else {
            requestAccessibilityIfNeeded()
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            let targetApp = TargetAppTracker.shared.targetApplication()
            OverlayWindowRegistry.shared.hideBriefly()
            targetApp?.activate(options: [.activateAllWindows])

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self else {
                    return
                }

                if let targetApp,
                   let current = self.isFullscreen(in: targetApp),
                   current == enter {
                    return
                }

                if let targetApp,
                   self.pressFullScreenButton(in: targetApp) {
                    return
                }

                self.sendKeyboardShortcut(.fullscreen) { _ in }
            }
        }
    }

    private func tileTargetWindow(left: Bool) {
        guard Self.hasAccessibilityPermission else {
            requestAccessibilityIfNeeded()
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            let targetApp = TargetAppTracker.shared.targetApplication()
            OverlayWindowRegistry.shared.hideBriefly(duration: 0.45)
            targetApp?.activate(options: [.activateAllWindows])

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, let targetApp else {
                    return
                }

                _ = self.tileWindow(in: targetApp, left: left)
            }
        }
    }

    @discardableResult
    func moveCursor(to normalizedPoint: CGPoint, sensitivity: CGFloat? = nil) -> CGPoint? {
        guard Self.hasAccessibilityPermission,
              let screenPoint = screenPoint(from: normalizedPoint),
              let screen = NSScreen.main
        else {
            requestAccessibilityIfNeeded()
            return nil
        }

        let smoothed: CGPoint
        if let lastCursorPoint {
            let distance = hypot(screenPoint.x - lastCursorPoint.x, screenPoint.y - lastCursorPoint.y)
            let screenScale = max(screen.frame.width, screen.frame.height)
            let normalizedDistance = min(max(distance / max(screenScale * 0.20, 1), 0), 1)
            let sensitivity = sensitivity ?? CGFloat(GesturePreferences.shared.gestureSensitivity)
            let acceleration = pow(normalizedDistance, 1.35)
            let response = min(max((0.08 + acceleration * 0.78) * sensitivity / 1.42, 0.08), 0.92)
            smoothed = CGPoint(
                x: lastCursorPoint.x + (screenPoint.x - lastCursorPoint.x) * response,
                y: lastCursorPoint.y + (screenPoint.y - lastCursorPoint.y) * response
            )
        } else {
            smoothed = screenPoint
        }

        lastCursorPoint = smoothed
        CGWarpMouseCursorPosition(smoothed)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        return smoothed
    }

    func beginDrag(at location: CGPoint?) {
        guard Self.hasAccessibilityPermission else {
            requestAccessibilityIfNeeded()
            return
        }

        let location = location ?? CGEvent(source: nil)?.location ?? lastCursorPoint ?? NSEvent.mouseLocation
        lastCursorPoint = location
        CGWarpMouseCursorPosition(location)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
    }

    @discardableResult
    func drag(to normalizedPoint: CGPoint, sensitivity: CGFloat? = nil) -> CGPoint? {
        guard Self.hasAccessibilityPermission else {
            requestAccessibilityIfNeeded()
            return nil
        }

        guard let location = moveCursor(to: normalizedPoint, sensitivity: sensitivity) else {
            return nil
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: location, mouseButton: .left)
        drag?.post(tap: .cghidEventTap)
        return location
    }

    func endDrag() {
        guard Self.hasAccessibilityPermission else {
            requestAccessibilityIfNeeded()
            return
        }

        let location = CGEvent(source: nil)?.location ?? lastCursorPoint ?? NSEvent.mouseLocation
        let source = CGEventSource(stateID: .hidSystemState)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left)
        up?.post(tap: .cghidEventTap)
    }

    func leftClick() {
        leftClick(at: nil)
    }

    func leftClick(at location: CGPoint?) {
        click(typeDown: .leftMouseDown, typeUp: .leftMouseUp, button: .left, at: location)
    }

    func rightClick() {
        rightClick(at: nil)
    }

    func rightClick(at location: CGPoint?) {
        click(typeDown: .rightMouseDown, typeUp: .rightMouseUp, button: .right, at: location)
    }

    func scroll(verticalDelta: CGFloat, sensitivity: CGFloat? = nil) {
        guard Self.hasAccessibilityPermission else {
            requestAccessibilityIfNeeded()
            return
        }

        let sensitivity = sensitivity ?? CGFloat(GesturePreferences.shared.gestureSensitivity)
        let amount = Int32(max(min(verticalDelta * 4800 * sensitivity, 1200), -1200))
        guard amount != 0 else {
            return
        }

        let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .pixel,
            wheelCount: 1,
            wheel1: amount,
            wheel2: 0,
            wheel3: 0
        )
        event?.post(tap: .cghidEventTap)
    }

    private func click(typeDown: CGEventType, typeUp: CGEventType, button: CGMouseButton, at fixedLocation: CGPoint? = nil) {
        guard Self.hasAccessibilityPermission else {
            requestAccessibilityIfNeeded()
            return
        }

        let location = fixedLocation ?? CGEvent(source: nil)?.location ?? lastCursorPoint ?? NSEvent.mouseLocation
        if fixedLocation != nil {
            lastCursorPoint = location
            CGWarpMouseCursorPosition(location)
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: source, mouseType: typeDown, mouseCursorPosition: location, mouseButton: button)
        let up = CGEvent(mouseEventSource: source, mouseType: typeUp, mouseCursorPosition: location, mouseButton: button)
        down?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
        up?.post(tap: .cghidEventTap)
    }

    private func screenPoint(from normalizedPoint: CGPoint) -> CGPoint? {
        guard let screen = NSScreen.main else {
            return nil
        }

        let clampedX = min(max(normalizedPoint.x, 0), 1)
        let clampedY = min(max(normalizedPoint.y, 0), 1)
        let frame = screen.frame
        return CGPoint(
            x: frame.minX + clampedX * frame.width,
            y: frame.maxY - clampedY * frame.height
        )
    }

    private func pressHotKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        var modifierKeyCodes: [CGKeyCode] = []

        if flags.contains(.maskControl) {
            modifierKeyCodes.append(59)
        }

        if flags.contains(.maskCommand) {
            modifierKeyCodes.append(55)
        }

        for modifierKeyCode in modifierKeyCodes {
            postKey(modifierKeyCode, keyDown: true, flags: flags, source: source)
        }

        Thread.sleep(forTimeInterval: 0.045)
        postKey(keyCode, keyDown: true, flags: flags, source: source)
        Thread.sleep(forTimeInterval: 0.035)
        postKey(keyCode, keyDown: false, flags: flags, source: source)
        Thread.sleep(forTimeInterval: 0.035)

        for modifierKeyCode in modifierKeyCodes.reversed() {
            postKey(modifierKeyCode, keyDown: false, flags: [], source: source)
        }
    }

    private func postKey(_ keyCode: CGKeyCode, keyDown: Bool, flags: CGEventFlags, source: CGEventSource?) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func pressFullScreenButton(in app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = focusedWindow(in: appElement) ?? firstWindow(in: appElement),
              let button = elementAttribute("AXFullScreenButton", from: window) ?? elementAttribute("AXZoomButton", from: window)
        else {
            return false
        }

        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private func isFullscreen(in app: NSRunningApplication) -> Bool? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = focusedWindow(in: appElement) ?? firstWindow(in: appElement) else {
            return nil
        }

        return boolAttribute("AXFullScreen", from: window)
    }

    private func boolAttribute(_ name: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value
        else {
            return nil
        }

        return value as? Bool
    }

    private func tileWindow(in app: NSRunningApplication, left: Bool) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = focusedWindow(in: appElement) ?? firstWindow(in: appElement) else {
            return false
        }

        let currentBounds: CGRect
        if let origin = pointAttribute("AXPosition", from: window),
           let size = sizeAttribute("AXSize", from: window) {
            currentBounds = CGRect(origin: origin, size: size)
        } else {
            currentBounds = NSScreen.main?.visibleFrame ?? .zero
        }

        let screen = screen(containing: currentBounds) ?? NSScreen.main
        guard let screen else {
            return false
        }

        let frame = screen.visibleFrame
        let target = CGRect(
            x: left ? frame.minX : frame.midX,
            y: frame.minY,
            width: frame.width / 2,
            height: frame.height
        )

        return setSize(target.size, for: window) && setPoint(target.origin, for: window)
    }

    private func screen(containing bounds: CGRect) -> NSScreen? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.screens.first
    }

    private func pointAttribute(_ name: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue((value as! AXValue), .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private func sizeAttribute(_ name: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue((value as! AXValue), .cgSize, &size) else {
            return nil
        }

        return size
    }

    private func setPoint(_ point: CGPoint, for element: AXUIElement) -> Bool {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else {
            return false
        }

        return AXUIElementSetAttributeValue(element, "AXPosition" as CFString, value) == .success
    }

    private func setSize(_ size: CGSize, for element: AXUIElement) -> Bool {
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else {
            return false
        }

        return AXUIElementSetAttributeValue(element, "AXSize" as CFString, value) == .success
    }

    private func focusedWindow(in appElement: AXUIElement) -> AXUIElement? {
        elementAttribute("AXFocusedWindow", from: appElement)
    }

    private func firstWindow(in appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, "AXWindows" as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else {
            return nil
        }

        return windows.first
    }

    private func elementAttribute(_ name: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let elementValue = value,
              CFGetTypeID(elementValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (elementValue as! AXUIElement)
    }
}

private final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    private let request = VNDetectHumanHandPoseRequest()
    private let imageContext = CIContext()
    private let queue = DispatchQueue(label: "local.codex.hand-control.camera")
    private let detector = GestureDetector()
    private let actionRunner = MacActionRunner()
    private lazy var pointerController = PointerGestureController(actionRunner: actionRunner)
    private var lastFrameAt: CFTimeInterval = 0
    private var hasPublishedFirstFrame = false

    var onFrame: ((CGImage) -> Void)?
    var onHands: (([HandPose], GestureSnapshot) -> Void)?

    override init() {
        super.init()
        request.maximumHandCount = 2
    }

    func start() {
        publish(hands: [], snapshot: GestureSnapshot(
            phase: .idle,
            command: .none,
            handCount: 0,
            details: startupPermissionDetails(),
            canSendKeys: MacActionRunner.hasAccessibilityPermission
        ))

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else {
                    self?.publish(hands: [], snapshot: GestureSnapshot(phase: .idle, command: .none, handCount: 0, details: "camera blocked", canSendKeys: MacActionRunner.hasAccessibilityPermission))
                    return
                }
                self?.configureAndStart()
            }
        default:
            publish(hands: [], snapshot: GestureSnapshot(phase: .idle, command: .none, handCount: 0, details: "camera blocked", canSendKeys: MacActionRunner.hasAccessibilityPermission))
        }
    }

    private func startupPermissionDetails() -> String {
        let cameraStatus: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraStatus = "camera:on"
        case .notDetermined:
            cameraStatus = "camera:ask"
        case .denied, .restricted:
            cameraStatus = "camera:off"
        @unknown default:
            cameraStatus = "camera:unknown"
        }

        return "\(cameraStatus) / \(MacActionRunner.hasAccessibilityPermission ? "AX:on" : "AX:off")"
    }

    private func configureAndStart() {
        queue.async { [weak self] in
            guard let self else {
                return
            }

            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(.hd1280x720) {
                self.session.sessionPreset = .hd1280x720
            } else if self.session.canSetSessionPreset(.high) {
                self.session.sessionPreset = .high
            } else {
                self.session.sessionPreset = .medium
            }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video)
            else {
                self.session.commitConfiguration()
                self.publish(hands: [], snapshot: GestureSnapshot(phase: .idle, command: .none, handCount: 0, details: "no camera", canSendKeys: MacActionRunner.hasAccessibilityPermission))
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                }

                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.queue)

                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                } else {
                    self.publish(hands: [], snapshot: GestureSnapshot(phase: .idle, command: .none, handCount: 0, details: "camera output unavailable", canSendKeys: MacActionRunner.hasAccessibilityPermission))
                }

                self.session.commitConfiguration()
                self.session.startRunning()
            } catch {
                self.session.commitConfiguration()
                self.publish(hands: [], snapshot: GestureSnapshot(phase: .idle, command: .none, handCount: 0, details: "camera setup failed", canSendKeys: MacActionRunner.hasAccessibilityPermission))
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrameAt > 1.0 / 24.0 else {
            return
        }
        lastFrameAt = now

        publishFrame(from: sampleBuffer)

        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([request])
            let hands = (request.results ?? []).compactMap(makeHandPose)
            let (snapshot, command) = detector.update(hands: hands, now: now)
            let pointerState: (GesturePhase?, String?)
            if hands.count >= 2 {
                pointerState = (nil, nil)
            } else {
                pointerState = pointerController.update(hands: hands, now: now)
            }

            if let command {
                actionRunner.run(command)
            }

            publish(hands: hands, snapshot: snapshot.withPointerState(pointerState))
        } catch {
            publish(hands: [], snapshot: GestureSnapshot(phase: .idle, command: .none, handCount: 0, details: "vision failed", canSendKeys: MacActionRunner.hasAccessibilityPermission))
        }
    }

    private func makeHandPose(from observation: VNHumanHandPoseObservation) -> HandPose? {
        guard let recognizedPoints = try? observation.recognizedPoints(.all) else {
            return nil
        }

        var points: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]

        for (joint, point) in recognizedPoints where point.confidence >= minimumPointConfidence {
            points[joint] = point.location
        }

        let hand = HandPose(points: points)
        return isInsideVisibleCameraFrame(hand) ? hand : nil
    }

    private func isInsideVisibleCameraFrame(_ hand: HandPose) -> Bool {
        guard hand.points.count >= minimumHandPointCount,
              let center = hand.center
        else {
            return false
        }

        let cameraRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let relaxedVisibleRect = cameraRect
            .insetBy(dx: -handEdgeMargin, dy: -handEdgeMargin)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let centerSafeRect = relaxedVisibleRect.insetBy(
            dx: min(handEdgeMargin, relaxedVisibleRect.width * 0.12),
            dy: min(handEdgeMargin, relaxedVisibleRect.height * 0.12)
        )
        guard centerSafeRect.contains(center) else {
            return false
        }

        let visiblePointCount = hand.points.values.filter { cameraRect.contains($0) }.count
        let requiredVisiblePoints = max(6, Int(Double(hand.points.count) * 0.48))
        return visiblePointCount >= requiredVisiblePoints
    }

    private func publish(hands: [HandPose], snapshot: GestureSnapshot) {
        DispatchQueue.main.async { [weak self] in
            self?.onHands?(hands, snapshot)
        }
    }

    private func publishFrame(from sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.hasPublishedFirstFrame = true
            self?.onFrame?(cgImage)
        }
    }
}

private final class CameraPreviewView: NSView {
    var frameImage: CGImage? {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()

        guard let frameImage, let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let imageSize = CGSize(width: frameImage.width, height: frameImage.height)
        let imageRect = aspectFitRect(contentSize: imageSize, in: bounds)
        CameraDisplayState.shared.updateVisibleNormalizedRect(imageRect: imageRect, bounds: bounds)

        context.saveGState()
        context.interpolationQuality = .high
        context.clip(to: bounds)

        if mirrorCameraFeed {
            context.translateBy(x: imageRect.midX, y: imageRect.midY)
            context.scaleBy(x: -1, y: 1)
            context.draw(
                frameImage,
                in: CGRect(x: -imageRect.width / 2, y: -imageRect.height / 2, width: imageRect.width, height: imageRect.height)
            )
        } else {
            context.draw(frameImage, in: imageRect)
        }

        context.restoreGState()
    }
}

private final class SkeletonOverlayView: NSView {
    var videoFrameSize: CGSize? {
        didSet {
            needsDisplay = true
        }
    }

    var hands: [HandPose] = [] {
        didSet {
            needsDisplay = true
        }
    }

    private let chains: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip],
        [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
    ]
    private var pointerReadoutUntil: CFTimeInterval = 0

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        for (index, hand) in hands.enumerated() {
            let color = index == 0 ? NSColor.systemCyan : NSColor.systemPink
            drawHand(hand, color: color)
        }
    }

    private func drawHand(_ hand: HandPose, color: NSColor) {
        color.withAlphaComponent(0.86).setStroke()

        for chain in chains {
            let path = NSBezierPath()
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            var started = false

            for joint in chain {
                guard let point = hand.point(joint) else {
                    continue
                }

                let converted = convertVisionPoint(point)

                if started {
                    path.line(to: converted)
                } else {
                    path.move(to: converted)
                    started = true
                }
            }

            path.stroke()
        }

        for point in hand.points.values {
            let converted = convertVisionPoint(point)
            let dot = NSBezierPath(ovalIn: NSRect(x: converted.x - 5.5, y: converted.y - 5.5, width: 11, height: 11))
            NSColor.white.withAlphaComponent(0.95).setFill()
            dot.fill()
        }

        drawPrimaryGestureReadout(for: hand)
    }

    private func drawPrimaryGestureReadout(for hand: HandPose) {
        let now = CACurrentMediaTime()
        if isIndexPointerPose(hand) {
            pointerReadoutUntil = now + 0.80
        }

        var gesture = primaryGesture(for: hand)
        if isPinchedPose(hand) {
            gesture = now <= pointerReadoutUntil ? .pointerPinch : .fist
        }

        guard gesture != .none,
              let anchor = gesture == .pointer || gesture == .pointerPinch
                ? thumbIndexAnchorPoint(for: hand)
                : hand.center
        else {
            return
        }

        let converted = convertVisionPoint(anchor)
        let halo = NSBezierPath(ovalIn: NSRect(x: converted.x - 18, y: converted.y - 18, width: 36, height: 36))
        gesture.color.withAlphaComponent(0.24).setFill()
        halo.fill()

        let text = gesture.label as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: gesture == .pointerPinch || gesture == .open ? NSColor.black : NSColor.white,
            .backgroundColor: gesture.color
        ]
        text.draw(at: CGPoint(x: converted.x + 12, y: converted.y + 8), withAttributes: attributes)
    }

    private func convertVisionPoint(_ point: CGPoint) -> CGPoint {
        let rect = aspectFitRect(contentSize: videoFrameSize ?? bounds.size, in: bounds)
        let displayed = displayPoint(point)
        return CGPoint(x: rect.minX + displayed.x * rect.width, y: rect.minY + displayed.y * rect.height)
    }
}

private final class StatusOverlayView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Mac Hand Controller")
    private let stateLabel = NSTextField(labelWithString: "starting")
    private let pinchLabel = NSTextField(labelWithString: "gesture: waiting")
    private let detailLabel = NSTextField(labelWithString: "camera + accessibility permission required")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        layer?.cornerRadius = 10

        [titleLabel, stateLabel, pinchLabel, detailLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.textColor = .white
            $0.lineBreakMode = .byTruncatingTail
            addSubview($0)
        }

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        stateLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        pinchLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        pinchLabel.textColor = NSColor.systemYellow
        detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.76)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            stateLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stateLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            pinchLabel.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 4),
            pinchLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            pinchLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: pinchLabel.bottomAnchor, constant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ snapshot: GestureSnapshot, hands: [HandPose]) {
        stateLabel.stringValue = "\(snapshot.handCount) hands / \(snapshot.phase.rawValue)"
        pinchLabel.stringValue = pinchSummary(for: hands)
        let access = snapshot.canSendKeys ? "AX:on" : "AX:off"
        let detail: String
        if snapshot.command.requiresAccessibility && !snapshot.canSendKeys {
            detail = "blocked: \(snapshot.command.rawValue)"
        } else {
            detail = snapshot.command == .none ? snapshot.details : snapshot.command.rawValue
        }
        detailLabel.stringValue = "\(access) / \(detail)"
    }

    private func pinchSummary(for hands: [HandPose]) -> String {
        guard !hands.isEmpty else {
            return "gesture: no hands"
        }

        return hands.enumerated()
            .map { index, hand in
                let pointer = isIndexPointerPose(hand) ? "yes" : "no"
                let pinch = isGesturePinchedPose(hand) ? "yes" : "no"
                let fist = isFistPose(hand) ? "yes" : "no"
                let open = isSwipeOpenPose(hand) ? "yes" : "no"
                return "H\(index + 1): pt \(pointer) / pn \(pinch) / fi \(fist) / op \(open)"
            }
            .joined(separator: "  ")
    }
}

private final class ShortcutControlView: NSView {
    var onShortcut: ((KeyboardShortcut) -> Void)?
    var onEnableAccessibility: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Shortcut Test")
    private let statusLabel = NSTextField(labelWithString: "AX:checking")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 0

        let enableButton = makeButton(title: "Enable AX", action: #selector(enableAccessibility))
        let fullscreenButton = makeButton(title: "Ctrl Cmd F", action: #selector(pressFullscreen))
        let leftButton = makeButton(title: "Ctrl Left", action: #selector(pressLeft))
        let rightButton = makeButton(title: "Ctrl Right", action: #selector(pressRight))

        let buttonStack = NSStackView(views: [enableButton, fullscreenButton, leftButton, rightButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 10
        buttonStack.distribution = .fillEqually

        [titleLabel, statusLabel, buttonStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .labelColor
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            buttonStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 22),
            buttonStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            buttonStack.heightAnchor.constraint(equalToConstant: 44),
            statusLabel.topAnchor.constraint(equalTo: buttonStack.bottomAnchor, constant: 18),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            statusLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -28)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        return button
    }

    @objc private func enableAccessibility() {
        onEnableAccessibility?()
    }

    @objc private func pressFullscreen() {
        onShortcut?(.fullscreen)
    }

    @objc private func pressLeft() {
        onShortcut?(.spaceLeft)
    }

    @objc private func pressRight() {
        onShortcut?(.spaceRight)
    }
}

private final class ShortcutTestViewController: NSViewController {
    private let actionRunner = MacActionRunner()
    private let shortcutView = ShortcutControlView()
    private var statusTimer: Timer?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root

        shortcutView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(shortcutView)

        NSLayoutConstraint.activate([
            shortcutView.topAnchor.constraint(equalTo: root.topAnchor),
            shortcutView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            shortcutView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            shortcutView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        shortcutView.onEnableAccessibility = { [weak self] in
            self?.enableAccessibility()
        }
        shortcutView.onShortcut = { [weak self] shortcut in
            self?.sendShortcutFromButton(shortcut)
        }

        refreshAccessibilityStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.refreshAccessibilityStatus()
        }
    }

    private func enableAccessibility() {
        actionRunner.requestAccessibilityIfNeeded()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshAccessibilityStatus(prefix: "open Settings")
    }

    private func sendShortcutFromButton(_ shortcut: KeyboardShortcut) {
        shortcutView.setStatus("sending \(shortcut.rawValue)...")
        actionRunner.sendKeyboardShortcut(shortcut) { [weak self] sent in
            self?.refreshAccessibilityStatus(prefix: sent ? "sent \(shortcut.rawValue)" : "allow Accessibility")
        }
    }

    private func refreshAccessibilityStatus(prefix: String? = nil) {
        let access = MacActionRunner.hasAccessibilityPermission ? "AX:on" : "AX:off"
        if let prefix {
            shortcutView.setStatus("\(access) / \(prefix)")
        } else {
            shortcutView.setStatus(access)
        }
    }
}

private final class AccessibilityControlView: NSView {
    var onEnableAccessibility: (() -> Void)?

    private let button = NSButton(title: "Enable AX", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "AX:checking")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.52).cgColor
        layer?.cornerRadius = 10

        button.target = self
        button.action = #selector(enableAccessibility)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13, weight: .semibold)

        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byTruncatingTail

        [button, statusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            button.heightAnchor.constraint(equalToConstant: 30),
            statusLabel.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 7),
            statusLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStatus(_ status: String) {
        statusLabel.stringValue = status
    }

    @objc private func enableAccessibility() {
        onEnableAccessibility?()
    }
}

private final class SettingsOverlayView: NSView {
    var onOpenAccessibility: (() -> Void)?
    var onClose: (() -> Void)?

    private let panel = NSView()
    private let titleLabel = NSTextField(labelWithString: "Mac Hand Controller Setup")
    private let statusLabel = NSTextField(labelWithString: "AX:checking")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "v1.2 (Thumb-Index Pointer)")
    private let openAccessibilityButton = NSButton(title: "Open Accessibility Settings", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let pointerToggle = NSButton(checkboxWithTitle: "Pointer: thumb + index L-shape", target: nil, action: nil)
    private let clickToggle = NSButton(checkboxWithTitle: "Click: single pinch for left click, double pinch for right click", target: nil, action: nil)
    private let scrollToggle = NSButton(checkboxWithTitle: "Scroll: make a fist, move up/down", target: nil, action: nil)
    private let fullscreenToggle = NSButton(checkboxWithTitle: "Fullscreen: two-hand pinch spread/squeeze", target: nil, action: nil)
    private let spaceToggle = NSButton(checkboxWithTitle: "Space: one open-hand swipe left/right", target: nil, action: nil)
    private let sensitivityLabel = NSTextField(labelWithString: "Gesture sensitivity")
    private let sensitivityValueLabel = NSTextField(labelWithString: "")
    private let sensitivitySlider = NSSlider(value: 1.55, minValue: 0.60, maxValue: 8.00, target: nil, action: nil)
    private let preferences = GesturePreferences.shared

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.layer?.cornerRadius = 18
        panel.layer?.shadowOpacity = 0.28
        panel.layer?.shadowRadius = 24
        panel.layer?.shadowOffset = CGSize(width: 0, height: -8)
        addSubview(panel)

        [
            titleLabel, versionLabel, statusLabel, bodyLabel, openAccessibilityButton,
            pointerToggle, clickToggle, scrollToggle, fullscreenToggle, spaceToggle,
            sensitivityLabel, sensitivityValueLabel, sensitivitySlider,
            doneButton
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview($0)
        }

        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        versionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        versionLabel.textColor = .tertiaryLabelColor
        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        bodyLabel.font = .systemFont(ofSize: 14, weight: .regular)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 0
        openAccessibilityButton.bezelStyle = .rounded
        openAccessibilityButton.font = .systemFont(ofSize: 14, weight: .semibold)
        openAccessibilityButton.target = self
        openAccessibilityButton.action = #selector(openAccessibility)
        doneButton.bezelStyle = .rounded
        doneButton.font = .systemFont(ofSize: 14, weight: .semibold)
        doneButton.target = self
        doneButton.action = #selector(close)

        [pointerToggle, clickToggle, scrollToggle, fullscreenToggle, spaceToggle].forEach {
            $0.target = self
            $0.action = #selector(toggleChanged)
            $0.font = .systemFont(ofSize: 13, weight: .medium)
        }
        [sensitivityLabel].forEach {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textColor = .labelColor
        }
        [sensitivityValueLabel].forEach {
            $0.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            $0.textColor = .secondaryLabelColor
            $0.alignment = .right
        }
        [sensitivitySlider].forEach {
            $0.target = self
            $0.action = #selector(sensitivityChanged)
            $0.numberOfTickMarks = 6
            $0.allowsTickMarkValuesOnly = false
        }

        let panelWidth = panel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.85)
        panelWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelWidth,
            titleLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 30),

            versionLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            versionLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            versionLabel.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -30),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -30),

            bodyLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -30),

            openAccessibilityButton.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 18),
            openAccessibilityButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            openAccessibilityButton.heightAnchor.constraint(equalToConstant: 34),

            pointerToggle.topAnchor.constraint(equalTo: openAccessibilityButton.bottomAnchor, constant: 22),
            pointerToggle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            pointerToggle.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -30),

            clickToggle.topAnchor.constraint(equalTo: pointerToggle.bottomAnchor, constant: 10),
            clickToggle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            clickToggle.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -30),

            scrollToggle.topAnchor.constraint(equalTo: clickToggle.bottomAnchor, constant: 10),
            scrollToggle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            scrollToggle.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -30),

            fullscreenToggle.topAnchor.constraint(equalTo: scrollToggle.bottomAnchor, constant: 10),
            fullscreenToggle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            fullscreenToggle.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -30),

            spaceToggle.topAnchor.constraint(equalTo: fullscreenToggle.bottomAnchor, constant: 10),
            spaceToggle.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            spaceToggle.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -30),

            sensitivityLabel.topAnchor.constraint(equalTo: spaceToggle.bottomAnchor, constant: 18),
            sensitivityLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sensitivityValueLabel.centerYAnchor.constraint(equalTo: sensitivityLabel.centerYAnchor),
            sensitivityValueLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -30),
            sensitivityValueLabel.widthAnchor.constraint(equalToConstant: 64),
            sensitivitySlider.topAnchor.constraint(equalTo: sensitivityLabel.bottomAnchor, constant: 6),
            sensitivitySlider.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sensitivitySlider.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -30),

            doneButton.topAnchor.constraint(equalTo: sensitivitySlider.bottomAnchor, constant: 22),
            doneButton.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -30),
            doneButton.widthAnchor.constraint(equalToConstant: 96),
            doneButton.heightAnchor.constraint(equalToConstant: 34),
            doneButton.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -28)
        ])

        loadToggleStates()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        let access = MacActionRunner.hasAccessibilityPermission
        statusLabel.stringValue = access ? "AX:on / gestures ready" : "AX:off / waiting for Accessibility permission"
        bodyLabel.stringValue = access
            ? "Pointer uses the space between your thumb and index finger. Pinch from that pose to click. You can reopen this panel from the Settings button."
            : "Accessibility permission is required before Mac Hand Controller can move the mouse, click, switch Spaces, or control windows. Open System Settings and enable Mac Hand Controller, then return here."
        openAccessibilityButton.isHidden = access
        doneButton.isEnabled = access
        [
            pointerToggle, clickToggle, scrollToggle, fullscreenToggle, spaceToggle,
            sensitivitySlider
        ].forEach {
            $0.isEnabled = access
        }
    }

    private func loadToggleStates() {
        pointerToggle.state = preferences.pointerEnabled ? .on : .off
        clickToggle.state = preferences.clicksEnabled ? .on : .off
        scrollToggle.state = preferences.scrollEnabled ? .on : .off
        fullscreenToggle.state = preferences.fullscreenEnabled ? .on : .off
        spaceToggle.state = preferences.spaceEnabled ? .on : .off
        sensitivitySlider.doubleValue = preferences.gestureSensitivity
        updateSensitivityLabels()
    }

    @objc private func openAccessibility() {
        onOpenAccessibility?()
    }

    @objc private func close() {
        guard MacActionRunner.hasAccessibilityPermission else {
            return
        }

        onClose?()
    }

    @objc private func toggleChanged() {
        preferences.pointerEnabled = pointerToggle.state == .on
        preferences.clicksEnabled = clickToggle.state == .on
        preferences.scrollEnabled = scrollToggle.state == .on
        preferences.fullscreenEnabled = fullscreenToggle.state == .on
        preferences.spaceEnabled = spaceToggle.state == .on
    }

    @objc private func sensitivityChanged() {
        preferences.gestureSensitivity = sensitivitySlider.doubleValue
        updateSensitivityLabels()
    }

    private func updateSensitivityLabels() {
        sensitivityValueLabel.stringValue = String(format: "%.2fx", preferences.gestureSensitivity)
    }
}

private final class RootViewController: NSViewController {
    private let tracker: HandTracker
    private let actionRunner = MacActionRunner()
    private let previewView = CameraPreviewView()
    private let overlayView = SkeletonOverlayView()
    private let settingsButton = NSButton(title: "Settings", target: nil, action: nil)
    private let settingsOverlay = SettingsOverlayView()
    private var accessibilityTimer: Timer?
    private var didLockCameraAspectRatio = false

    init(tracker: HandTracker) {
        self.tracker = tracker
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        view = root

        settingsButton.target = self
        settingsButton.action = #selector(showSettings)
        settingsButton.bezelStyle = .rounded
        settingsButton.font = .systemFont(ofSize: 14, weight: .bold)
        settingsButton.wantsLayer = true
        settingsButton.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor
        settingsButton.layer?.cornerRadius = 8
        settingsButton.layer?.zPosition = 20
        settingsOverlay.wantsLayer = true
        settingsOverlay.layer?.zPosition = 30

        [previewView, overlayView, settingsButton, settingsOverlay].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: root.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            overlayView.topAnchor.constraint(equalTo: root.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            settingsButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            settingsButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            settingsButton.widthAnchor.constraint(equalToConstant: 116),
            settingsButton.heightAnchor.constraint(equalToConstant: 36),
            settingsOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            settingsOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            settingsOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            settingsOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tracker.onFrame = { [weak self] frameImage in
            self?.previewView.frameImage = frameImage
            self?.overlayView.videoFrameSize = CGSize(width: frameImage.width, height: frameImage.height)
            self?.lockWindowAspectRatioIfNeeded(width: frameImage.width, height: frameImage.height)
        }
        tracker.onHands = { [weak self] hands, _ in
            self?.overlayView.hands = hands
        }
        settingsOverlay.onOpenAccessibility = { [weak self] in
            self?.enableAccessibility()
        }
        settingsOverlay.onClose = { [weak self] in
            self?.hideSettingsIfAllowed()
        }
        refreshAccessibilityStatus()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.refreshAccessibilityStatus()
        }
        settingsOverlay.isHidden = false
        tracker.start()
    }

    private func enableAccessibility() {
        actionRunner.requestAccessibilityIfNeeded()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshAccessibilityStatus(prefix: "open Settings")
    }

    private func refreshAccessibilityStatus(prefix: String? = nil) {
        let access = MacActionRunner.hasAccessibilityPermission ? "AX:on" : "AX:off"
        settingsOverlay.refresh()
        settingsButton.isHidden = false
        if !MacActionRunner.hasAccessibilityPermission {
            settingsOverlay.isHidden = false
        }
        settingsButton.title = access == "AX:on" ? "Settings" : "Setup"
    }

    @objc private func showSettings() {
        settingsOverlay.refresh()
        settingsOverlay.isHidden = false
    }

    private func hideSettingsIfAllowed() {
        guard MacActionRunner.hasAccessibilityPermission else {
            return
        }

        settingsOverlay.isHidden = true
        settingsButton.isHidden = false
    }

    private func lockWindowAspectRatioIfNeeded(width: Int, height: Int) {
        guard !didLockCameraAspectRatio,
              width > 0,
              height > 0,
              let window = view.window
        else {
            return
        }

        didLockCameraAspectRatio = true
        let aspectRatio = max(CGFloat(width) / CGFloat(height), 0.1)
        window.contentAspectRatio = NSSize(width: aspectRatio, height: 1)

        let currentContentSize = window.contentLayoutRect.size
        guard currentContentSize.width > 0 else {
            return
        }

        let newContentSize = NSSize(width: currentContentSize.width, height: currentContentSize.width / aspectRatio)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: newContentSize))
        frame.origin.x = window.frame.maxX - frame.width
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let tracker = HandTracker()
    private let actionRunner = MacActionRunner()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        TargetAppTracker.shared.start()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(testFullscreenFromNotification),
            name: Notification.Name("local.codex.MacHandControl.testFullscreen"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(testMoveLeftFromNotification),
            name: Notification.Name("local.codex.MacHandControl.testMoveLeft"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(testMoveRightFromNotification),
            name: Notification.Name("local.codex.MacHandControl.testMoveRight"),
            object: nil
        )
        createStatusItem()
        showDebugWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDebugWindow()
        return true
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Hand"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Debug Window", action: #selector(showDebugWindowFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Test Enter Fullscreen", action: #selector(testEnterFullscreenFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Test Exit Fullscreen", action: #selector(testExitFullscreenFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Test Space Left", action: #selector(testMoveLeftFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Test Space Right", action: #selector(testMoveRightFromMenu), keyEquivalent: ""))
        let splitLeftItem = NSMenuItem(title: "Test Split Left", action: #selector(testSplitLeftFromMenu), keyEquivalent: "")
        let splitRightItem = NSMenuItem(title: "Test Split Right", action: #selector(testSplitRightFromMenu), keyEquivalent: "")
        menu.addItem(splitLeftItem)
        menu.addItem(splitRightItem)
        menu.addItem(NSMenuItem(title: "Request Accessibility Permission", action: #selector(requestAccessibilityFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func showDebugWindow() {
        if let window {
            if window.frame.width < 80 || window.frame.height < 80 {
                window.setFrame(defaultDebugWindowFrame(), display: true)
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let controller = RootViewController(tracker: tracker)
        let frame = defaultDebugWindowFrame()
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Mac Hand Controller"
        window.contentViewController = controller
        window.setFrame(frame, display: true)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hasShadow = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.minSize = NSSize(width: 80, height: 80)
        window.contentMinSize = NSSize(width: 1, height: 1)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        OverlayWindowRegistry.shared.window = window
        self.window = window
    }

    private func defaultDebugWindowFrame() -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let margin: CGFloat = 24
        let width = min(520, max(360, visibleFrame.width * 0.30))
        let height = width * 9 / 16
        return NSRect(
            x: visibleFrame.maxX - width - margin,
            y: visibleFrame.maxY - height - margin,
            width: width,
            height: height
        )
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? newFrame
        let aspectRatio = window.contentAspectRatio.width > 0 && window.contentAspectRatio.height > 0
            ? window.contentAspectRatio.width / window.contentAspectRatio.height
            : 16 / 9
        return largestAspectFrame(in: visibleFrame, aspectRatio: aspectRatio)
    }

    private func largestAspectFrame(in visibleFrame: NSRect, aspectRatio: CGFloat) -> NSRect {
        let widthFromHeight = visibleFrame.height * aspectRatio
        let width = min(visibleFrame.width, widthFromHeight)
        let height = width / aspectRatio
        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    @objc private func showDebugWindowFromMenu() {
        showDebugWindow()
    }

    @objc private func requestAccessibilityFromMenu() {
        MacActionRunner().requestAccessibilityIfNeeded()
    }

    @objc private func testEnterFullscreenFromMenu() {
        actionRunner.run(.enterFullscreen)
    }

    @objc private func testExitFullscreenFromMenu() {
        actionRunner.run(.exitFullscreen)
    }

    @objc private func testFullscreenFromNotification() {
        actionRunner.run(.enterFullscreen)
    }

    @objc private func testMoveLeftFromMenu() {
        actionRunner.run(.moveLeft)
    }

    @objc private func testMoveRightFromMenu() {
        actionRunner.run(.moveRight)
    }

    @objc private func testMoveLeftFromNotification() {
        actionRunner.run(.moveLeft)
    }

    @objc private func testMoveRightFromNotification() {
        actionRunner.run(.moveRight)
    }

    @objc private func testSplitLeftFromMenu() {
        actionRunner.run(.splitLeft)
    }

    @objc private func testSplitRightFromMenu() {
        actionRunner.run(.splitRight)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate

if CommandLine.arguments.contains("--test-space-left") {
    exit(SpaceSwitcher.shared.moveHorizontally(-1, targetApp: nil) ? 0 : 1)
}

if CommandLine.arguments.contains("--test-space-right") {
    exit(SpaceSwitcher.shared.moveHorizontally(1, targetApp: nil) ? 0 : 1)
}

application.run()
