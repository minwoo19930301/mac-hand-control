import AppKit
import AVFoundation
import Vision
import ApplicationServices
import CoreGraphics
import CoreImage
import Darwin

private let minimumPointConfidence: VNConfidence = 0.28
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
    case fullscreen = "fullscreen"
    case moveLeft = "space: left"
    case moveRight = "space: right"
    case moveUp = "ignored: up"
    case moveDown = "ignored: down"

    var requiresAccessibility: Bool {
        self == .fullscreen || self == .moveLeft || self == .moveRight
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

private func displayPoint(_ point: CGPoint) -> CGPoint {
    mirrorCameraFeed ? CGPoint(x: 1 - point.x, y: point.y) : point
}

private func displayCenter(for hand: HandPose) -> CGPoint? {
    hand.center.map(displayPoint)
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
    guard let curledCount = curledFingerCount(hand) else {
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
    isPinchedPose(hand) && isOpenPose(hand) && !isFistPose(hand)
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
    fingerExtended(hand, tip: .indexTip, pip: .indexPIP, mcp: .indexMCP)
        && fingerCurled(hand, tip: .middleTip, pip: .middlePIP, mcp: .middleMCP)
        && fingerCurled(hand, tip: .ringTip, pip: .ringPIP, mcp: .ringMCP)
        && fingerCurled(hand, tip: .littleTip, pip: .littlePIP, mcp: .littleMCP)
        && !isPinchedPose(hand)
}

private enum PointerPinchKind {
    case leftClick
    case rightClick
}

private final class PointerGestureController {
    private let actionRunner: MacActionRunner
    private var activePinch: PointerPinchKind?
    private var pinchStartedAt: CFTimeInterval = 0
    private var pinchStartPoint: CGPoint?
    private var lastPinchPoint: CGPoint?
    private var didScrollDuringPinch = false
    private var lastMoveAt: CFTimeInterval = 0

    init(actionRunner: MacActionRunner) {
        self.actionRunner = actionRunner
    }

    func update(hands: [HandPose], now: CFTimeInterval = CACurrentMediaTime()) -> (GesturePhase?, String?) {
        guard hands.count == 1, let hand = hands.first else {
            resetPinch()
            return (nil, nil)
        }

        let displayedIndexTip = hand.point(.indexTip).map(displayPoint)
        let threePinch = isThreeFingerPinchedPose(hand)
        let twoPinch = isPinchedPose(hand) && !threePinch

        if threePinch || twoPinch, let point = displayedIndexTip {
            let kind: PointerPinchKind = threePinch ? .rightClick : .leftClick
            if activePinch != kind {
                activePinch = kind
                pinchStartedAt = now
                pinchStartPoint = point
                lastPinchPoint = point
                didScrollDuringPinch = false
            } else {
                handlePinchDrag(point, now: now)
            }

            actionRunner.moveCursor(to: point)
            return (didScrollDuringPinch ? .scroll : .click, threePinch ? "three-finger pinch: right click" : "pinch drag: click / scroll")
        }

        if let activePinch, let start = pinchStartPoint, let last = lastPinchPoint {
            let distance = poseDistance(start, last)
            let heldLongEnough = now - pinchStartedAt > 0.06
            if heldLongEnough && !didScrollDuringPinch && distance < 0.055 {
                switch activePinch {
                case .leftClick:
                    actionRunner.leftClick()
                case .rightClick:
                    actionRunner.rightClick()
                }
                resetPinch()
                return (.fired, activePinch == .leftClick ? "left click" : "right click")
            }
            resetPinch()
        }

        if isIndexPointerPose(hand), let point = displayedIndexTip {
            if now - lastMoveAt > 1.0 / 50.0 {
                actionRunner.moveCursor(to: point)
                lastMoveAt = now
            }
            return (.pointer, "index pointer: move cursor")
        }

        return (nil, nil)
    }

    private func handlePinchDrag(_ point: CGPoint, now: CFTimeInterval) {
        guard let last = lastPinchPoint else {
            lastPinchPoint = point
            return
        }

        let dy = point.y - last.y
        lastPinchPoint = point

        guard abs(dy) > 0.018 else {
            return
        }

        didScrollDuringPinch = true
        actionRunner.scroll(verticalDelta: dy)
    }

    private func resetPinch() {
        activePinch = nil
        pinchStartPoint = nil
        lastPinchPoint = nil
        didScrollDuringPinch = false
    }
}

private final class GestureDetector {
    private var phase: GesturePhase = .idle
    private var armedAt: CFTimeInterval = 0
    private var armedCenter: CGPoint?
    private var cooldownUntil: CFTimeInterval = 0
    private var lastCommandUntil: CFTimeInterval = 0
    private var lastCommand: GestureCommand = .none
    private var twoHandPinchReady = false
    private var initialPinchSpan: CGFloat?
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
                resetSwipeTracking()
            }
            return (snapshot(hands: hands, details: "show your hand"), nil)
        }

        if now < cooldownUntil {
            phase = .cooldown
            return (snapshot(hands: hands, details: "cooling down"), nil)
        }

        let visibleHands = Array(hands.prefix(2))
        let primaryHand = visibleHands[0]
        let isTwoHandPinching = visibleHands.count >= 2 && visibleHands.allSatisfy(isGesturePinchedPose)
        let swipeHands = visibleHands.filter(isSwipeOpenPose)

        if isTwoHandPinching, let pinchSpan = twoHandPinchSpan(for: visibleHands) {
            if phase != .pinched {
                phase = .pinched
                armedAt = now
                armedCenter = displayCenter(for: primaryHand)
                initialPinchSpan = pinchSpan
                twoHandPinchReady = false
                resetSwipeTracking()
            }

            if now - armedAt >= 0.18 {
                twoHandPinchReady = true
            }

            if twoHandPinchReady,
               let initialPinchSpan,
               let details = twoHandPinchCommandDetails(from: initialPinchSpan, to: pinchSpan) {
                phase = .fired
                self.initialPinchSpan = nil
                twoHandPinchReady = false
                cooldownUntil = now + 1.6
                lastCommand = .fullscreen
                lastCommandUntil = now + 1.2
                return (snapshot(hands: hands, details: details), .fullscreen)
            }

            let details = twoHandPinchReady ? "pinch spread / squeeze" : "hold both pinches"
            return (snapshot(hands: hands, details: details), nil)
        }

        if phase == .pinched {
            phase = .idle
            armedCenter = nil
            initialPinchSpan = nil
            twoHandPinchReady = false
        }

        if swipeHands.count == 1,
           let swipeHand = swipeHands.first,
           let center = displayCenter(for: swipeHand) {
                if phase != .swipe {
                    phase = .swipe
                    armedAt = now
                    armedCenter = center
                    swipeReady = false
                    swipeTrail = [TimedPoint(time: now, point: center)]
                } else {
                    appendSwipePoint(center, now: now)
                }

                if now - armedAt >= 0.12 {
                    swipeReady = true
                }

                if swipeReady, let command = swipeCommandFromTrail() {
                    phase = .fired
                    resetSwipeTracking()
                    cooldownUntil = now + 1.15
                    lastCommand = command
                    lastCommandUntil = now + 1.1
                    return (snapshot(hands: hands, details: "firing swipe"), command)
                }

                return (snapshot(hands: hands, details: swipeReady ? "swipe open hand" : "show open palm"), nil)
        }

        let lostSwipeHand = phase == .swipe && swipeHands.count != 1
        if (phase == .pinched && now - armedAt > 2.0) || lostSwipeHand {
            phase = .idle
            armedCenter = nil
            twoHandPinchReady = false
            initialPinchSpan = nil
            resetSwipeTracking()
        }

        let details: String
        switch phase {
        case .pinched:
            details = "pinch spread / squeeze"
        case .swipe:
            details = "swipe open hand"
        default:
            details = "pinch spread / open-hand swipe / index pointer"
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

    private func twoHandPinchSpan(for hands: [HandPose]) -> CGFloat? {
        guard hands.count >= 2,
              let first = displayCenter(for: hands[0]),
              let second = displayCenter(for: hands[1])
        else {
            return nil
        }

        return poseDistance(first, second)
    }

    private func twoHandPinchCommandDetails(from initialSpan: CGFloat, to currentSpan: CGFloat) -> String? {
        let delta = currentSpan - initialSpan
        let threshold = max(initialSpan * 0.30, 0.10)

        if delta > threshold {
            return "pinch spread fullscreen"
        }

        if delta < -threshold {
            return "pinch squeeze fullscreen"
        }

        return nil
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
        if command == .fullscreen {
            sendKeyboardShortcut(.fullscreen) { _ in }
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

        guard Self.hasAccessibilityPermission else {
            return
        }

        let keyCode: CGKeyCode
        let flags: CGEventFlags

        switch command {
        case .none:
            return
        case .fullscreen:
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
        }

        if command != .fullscreen {
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

                if command == .fullscreen,
                   let targetApp,
                   self.pressFullScreenButton(in: targetApp) {
                    return
                }

                self.pressHotKey(keyCode: keyCode, flags: flags)
            }
        }
    }

    func moveCursor(to normalizedPoint: CGPoint) {
        guard Self.hasAccessibilityPermission,
              let screenPoint = screenPoint(from: normalizedPoint)
        else {
            requestAccessibilityIfNeeded()
            return
        }

        let smoothed: CGPoint
        if let lastCursorPoint {
            smoothed = CGPoint(
                x: lastCursorPoint.x + (screenPoint.x - lastCursorPoint.x) * 0.34,
                y: lastCursorPoint.y + (screenPoint.y - lastCursorPoint.y) * 0.34
            )
        } else {
            smoothed = screenPoint
        }

        lastCursorPoint = smoothed
        CGWarpMouseCursorPosition(smoothed)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    }

    func leftClick() {
        click(typeDown: .leftMouseDown, typeUp: .leftMouseUp, button: .left)
    }

    func rightClick() {
        click(typeDown: .rightMouseDown, typeUp: .rightMouseUp, button: .right)
    }

    func scroll(verticalDelta: CGFloat) {
        guard Self.hasAccessibilityPermission else {
            requestAccessibilityIfNeeded()
            return
        }

        let amount = Int32(max(min(verticalDelta * 2200, 90), -90))
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

    private func click(typeDown: CGEventType, typeUp: CGEventType, button: CGMouseButton) {
        guard Self.hasAccessibilityPermission else {
            requestAccessibilityIfNeeded()
            return
        }

        let location = CGEvent(source: nil)?.location ?? lastCursorPoint ?? NSEvent.mouseLocation
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
            self.session.sessionPreset = .medium

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
            let pointerState = pointerController.update(hands: hands, now: now)

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

        return points.isEmpty ? nil : HandPose(points: points)
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

        drawPinchReadout(for: hand)
        drawOpenReadout(for: hand)
    }

    private func drawPinchReadout(for hand: HandPose) {
        guard
            let thumbTip = hand.point(.thumbTip),
            let indexTip = hand.point(.indexTip)
        else {
            return
        }

        let thumb = convertVisionPoint(thumbTip)
        let index = convertVisionPoint(indexTip)
        let isPinched = isGesturePinchedPose(hand)
        let pinchPath = NSBezierPath()
        pinchPath.lineWidth = isPinched ? 6 : 2
        pinchPath.lineCapStyle = .round
        pinchPath.move(to: thumb)
        pinchPath.line(to: index)
        (isPinched ? NSColor.systemYellow : NSColor.white.withAlphaComponent(0.35)).setStroke()
        pinchPath.stroke()

        guard isPinched else {
            return
        }

        let midpoint = CGPoint(x: (thumb.x + index.x) / 2, y: (thumb.y + index.y) / 2)
        let halo = NSBezierPath(ovalIn: NSRect(x: midpoint.x - 18, y: midpoint.y - 18, width: 36, height: 36))
        NSColor.systemYellow.withAlphaComponent(0.28).setFill()
        halo.fill()

        let text = "PINCH" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.black,
            .backgroundColor: NSColor.systemYellow
        ]
        text.draw(at: CGPoint(x: midpoint.x + 15, y: midpoint.y + 8), withAttributes: attributes)
    }

    private func drawOpenReadout(for hand: HandPose) {
        guard isSwipeOpenPose(hand), let center = hand.center else {
            return
        }

        let converted = convertVisionPoint(center)
        let halo = NSBezierPath(ovalIn: NSRect(x: converted.x - 20, y: converted.y - 20, width: 40, height: 40))
        NSColor.systemGreen.withAlphaComponent(0.22).setFill()
        halo.fill()

        let text = "OPEN" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.black,
            .backgroundColor: NSColor.systemGreen
        ]
        text.draw(at: CGPoint(x: converted.x + 16, y: converted.y + 8), withAttributes: attributes)
    }

    private func convertVisionPoint(_ point: CGPoint) -> CGPoint {
        let rect = aspectFitRect(contentSize: videoFrameSize ?? bounds.size, in: bounds)
        let displayed = displayPoint(point)
        return CGPoint(x: rect.minX + displayed.x * rect.width, y: rect.minY + displayed.y * rect.height)
    }
}

private final class StatusOverlayView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Mac Hand Control")
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
        pinchLabel.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
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
                let three = isThreeFingerPinchedPose(hand) ? "yes" : "no"
                return "H\(index + 1): point \(pointer) / pinch \(pinch) / 3pinch \(three)"
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

private final class RootViewController: NSViewController {
    private let tracker: HandTracker
    private let actionRunner = MacActionRunner()
    private let previewView = CameraPreviewView()
    private let overlayView = SkeletonOverlayView()
    private let statusView = StatusOverlayView()
    private let accessibilityView = AccessibilityControlView()
    private var accessibilityTimer: Timer?

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

        [previewView, overlayView, statusView, accessibilityView].forEach {
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
            accessibilityView.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            accessibilityView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            accessibilityView.widthAnchor.constraint(equalToConstant: 160),
            statusView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            statusView.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -18),
            statusView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            statusView.widthAnchor.constraint(equalToConstant: 330)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tracker.onFrame = { [weak self] frameImage in
            self?.previewView.frameImage = frameImage
            self?.overlayView.videoFrameSize = CGSize(width: frameImage.width, height: frameImage.height)
        }
        tracker.onHands = { [weak self] hands, snapshot in
            self?.overlayView.hands = hands
            self?.statusView.update(snapshot, hands: hands)
        }
        accessibilityView.onEnableAccessibility = { [weak self] in
            self?.enableAccessibility()
        }
        refreshAccessibilityStatus()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.refreshAccessibilityStatus()
        }
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
        accessibilityView.setStatus(prefix.map { "\(access) / \($0)" } ?? access)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
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
        menu.addItem(NSMenuItem(title: "Test Fullscreen on Front App", action: #selector(testFullscreenFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Test Space Left", action: #selector(testMoveLeftFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Test Space Right", action: #selector(testMoveRightFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Request Accessibility Permission", action: #selector(requestAccessibilityFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func showDebugWindow() {
        if let window {
            window.orderFrontRegardless()
            return
        }

        let controller = RootViewController(tracker: tracker)
        let frame = NSRect(x: 220, y: 180, width: 980, height: 620)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Mac Hand Control"
        window.minSize = NSSize(width: 720, height: 460)
        window.setFrame(frame, display: true)
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        OverlayWindowRegistry.shared.window = window
        self.window = window
    }

    @objc private func showDebugWindowFromMenu() {
        showDebugWindow()
    }

    @objc private func requestAccessibilityFromMenu() {
        MacActionRunner().requestAccessibilityIfNeeded()
    }

    @objc private func testFullscreenFromMenu() {
        actionRunner.run(.fullscreen)
    }

    @objc private func testFullscreenFromNotification() {
        actionRunner.run(.fullscreen)
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
