// Vehicle Motion Cues for macOS — dots at the screen edges that move with the
// vehicle, driven by the MacBook's built-in accelerometer (Apple Silicon).
import AppKit
import IOKit
import IOKit.hid
import simd
import ServiceManagement

let defaults = UserDefaults.standard
let env = ProcessInfo.processInfo.environment

// MARK: - Motion (accelerometer -> dot velocity)

final class Motion {
    static let shared = Motion()

    var flipX = defaults.bool(forKey: "flipX")
    var flipY = defaults.bool(forKey: "flipY")
    var swapAxes = defaults.bool(forKey: "swapAxes")
    var demo = env["VMC_DEMO"] != nil
    var demoStart = CACurrentMediaTime()

    private(set) var velocity = SIMD2<Double>(0, 0)   // points/second, +y is up the screen
    private(set) var sampleCount = 0
    private(set) var lastSampleTime: CFTimeInterval = 0

    // Vehicle detection: a moving vehicle shakes the laptop continuously; a desk or lap does not.
    private(set) var inVehicle = false
    private(set) var vibrationMg = 0.0              // typical shake over the last second, in milli-g
    private let vibrationThreshold = 0.003          // g; a still desk measures ~0.0005
    private let secondsToEnter = 12, windowSeconds = 20
    private let secondsToLeave = 120.0              // rides out red lights and traffic
    private var bandFast = SIMD3<Double>(0, 0, 0), bandSlow = SIMD3<Double>(0, 0, 0)
    private var shakeSamples: [Double] = []
    private var shakeWindowStart: CFTimeInterval = 0
    private var recentSeconds: [Bool] = []
    private var lastShakyTime: CFTimeInterval = 0
    private let fakeShake = env["VMC_SHAKE"] != nil  // testing: pretend the road is bumpy

    /// Which way the laptop is leaning right now (smoothed raw reading), used to set dot direction.
    var tilt: SIMD3<Double> { bandSlow + testTilt }
    var testTilt = SIMD3<Double>(0, 0, 0)            // testing: pretend the laptop was tilted

    private var gravity = SIMD3<Double>(0, 0, -1)
    private var haveGravity = false
    private var smooth = SIMD2<Double>(0, 0)
    private var manager: IOHIDManager?
    private var lockedSender: UnsafeMutableRawPointer?

    private let gravityTau = 4.0        // s: how slowly "which way is down" adapts
    private let smoothTau = 0.12        // s: rejects typing/road buzz
    private let velocityTau = 1.6       // s: flow decays once speed is steady
    private let deadzone = 0.006        // g
    private let pointsPerMps = 60.0     // screen points per m/s of speed change
    private let maxSpeed = 900.0

    func start() {
        wakeSensor()
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3] as CFDictionary)
        IOHIDManagerRegisterInputReportCallback(m, { _, _, sender, _, _, report, length in
            guard length >= 18 else { return }
            func axis(_ offset: Int) -> Double {
                var v: Int32 = 0
                memcpy(&v, report + offset, 4)
                return Double(Int32(littleEndian: v)) / 65536.0
            }
            Motion.shared.ingest(SIMD3(axis(6), axis(10), axis(14)), sender: sender)
        }, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess { NSLog("VMC: could not open accelerometer (0x%x)", result) }
        manager = m
    }

    /// The sensor idles until asked to report.
    func wakeSensor() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else { return }
        while case let service = IOIteratorNext(iterator), service != 0 {
            IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, 10000 as CFNumber)
            IOObjectRelease(service)
        }
        IOObjectRelease(iterator)
    }

    private func ingest(_ reading: SIMD3<Double>, sender: UnsafeMutableRawPointer?) {
        if lockedSender == nil { lockedSender = sender }
        guard sender == lockedSender else { return }

        let now = CACurrentMediaTime()
        let dt = min(max(now - lastSampleTime, 0.001), 0.05)
        lastSampleTime = now
        sampleCount += 1
        if sampleCount == 1 { NSLog("VMC: accelerometer streaming") }

        if !haveGravity { gravity = reading; haveGravity = true; bandFast = reading; bandSlow = reading; shakeWindowStart = now }
        gravity += (reading - gravity) * (dt / gravityTau)
        detectVehicle(reading, now: now, dt: dt)

        // Remove gravity, keep only the part parallel to the ground.
        var linear = reading - gravity
        let down = simd_normalize(gravity)
        linear -= simd_dot(linear, down) * down

        var h = SIMD2(linear.x, linear.y)
        if swapAxes { h = SIMD2(h.y, h.x) }
        if flipX { h.x = -h.x }
        if flipY { h.y = -h.y }
        if demo {
            let t = now - demoStart
            h = SIMD2(0.10 * sin(t * 0.9), 0.07 * sin(t * 0.55 + 1))
            if t > 12 { demo = false }
        }

        smooth += (h - smooth) * min(1, dt / smoothTau)
        let magnitude = simd_length(smooth)
        let effective = magnitude > deadzone ? smooth * ((magnitude - deadzone) / magnitude) : .zero

        velocity += (effective * 9.81 * pointsPerMps - velocity / velocityTau) * dt
        let speed = simd_length(velocity)
        if speed > maxSpeed { velocity *= maxSpeed / speed }
    }

    private func detectVehicle(_ reading: SIMD3<Double>, now: CFTimeInterval, dt: Double) {
        var r = reading
        if fakeShake { r += SIMD3(Double.random(in: -0.03...0.03), Double.random(in: -0.03...0.03), Double.random(in: -0.03...0.03)) }
        // Keep roughly 1–12 Hz: road and suspension shake, not tilting and not speaker/fan buzz.
        bandFast += (r - bandFast) * (dt / (0.013 + dt))
        bandSlow += (bandFast - bandSlow) * (dt / (0.16 + dt))
        shakeSamples.append(simd_length(bandFast - bandSlow))
        guard now - shakeWindowStart >= 1 else { return }
        shakeWindowStart = now
        guard shakeSamples.count >= 30 else { shakeSamples.removeAll(keepingCapacity: true); return }

        // Median, so a few keystroke thumps in an otherwise still second don't count.
        shakeSamples.sort()
        let median = shakeSamples[shakeSamples.count / 2]
        shakeSamples.removeAll(keepingCapacity: true)
        vibrationMg = median * 1000

        let shaky = median > vibrationThreshold
        if shaky { lastShakyTime = now }
        recentSeconds.append(shaky)
        if recentSeconds.count > windowSeconds { recentSeconds.removeFirst() }

        if !inVehicle, recentSeconds.filter({ $0 }).count >= secondsToEnter {
            inVehicle = true
            NSLog("VMC: vehicle detected")
        } else if inVehicle, now - lastShakyTime > secondsToLeave {
            inVehicle = false
            recentSeconds.removeAll()
            NSLog("VMC: vehicle no longer detected")
        }
    }
}

// MARK: - Overlay (click-through dots on each screen)

final class Overlay {
    let window: NSWindow
    private var dots: [CALayer] = []
    private let size: CGSize
    private let spacing = 58.0, band = 130.0, dotSize = 15.0
    private let cols: Int, rows: Int

    init(screen: NSScreen) {
        size = screen.frame.size
        cols = Int(ceil(band / spacing)) + 2
        rows = Int(ceil(size.height / spacing)) + 2

        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        if env["VMC_SHARE"] == nil { window.sharingType = .none }   // keep dots out of screenshots

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        window.contentView = view
        for _ in 0..<(2 * cols * rows) {
            let dot = CALayer()
            dot.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
            dot.borderColor = NSColor(white: 1, alpha: 0.65).cgColor
            dot.borderWidth = 1
            view.layer?.addSublayer(dot)
            dots.append(dot)
        }
        layout(offset: .zero)
    }

    func layout(offset: SIMD2<Double>) {
        let nx = floor(offset.x / spacing), fx = offset.x - nx * spacing
        let ny = floor(offset.y / spacing), fy = offset.y - ny * spacing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var i = 0
        for side in 0..<2 {
            let base = side == 0 ? 0.4 * spacing : size.width - 2.4 * spacing
            for c in 0..<cols {
                let odd = ((c - Int(nx)) % 2 + 2) % 2 == 1
                let x = base + Double(c - 1) * spacing + fx
                let edgeDistance = side == 0 ? x : size.width - x
                var f = min(max(1 - edgeDistance / band, 0), 1)
                f = f * f * (3 - 2 * f)
                let d = dotSize * (0.4 + 0.6 * f)
                for r in 0..<rows {
                    let y = Double(r - 1) * spacing + fy + (odd ? spacing / 2 : 0)
                    let dot = dots[i]; i += 1
                    dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
                    dot.cornerRadius = d / 2
                    dot.position = CGPoint(x: x, y: y)
                    dot.opacity = Float(f * 0.9)
                }
            }
        }
        CATransaction.commit()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    // Direction setup: the user tilts the laptop twice and the sensor's axes are worked out from that.
    private enum SetupStep { case none, liftLeft, setDown, liftFront, finished }
    private var setupStep = SetupStep.none
    private var setupBaseline = SIMD3<Double>(0, 0, 0)
    private var setupStarted: CFTimeInterval = 0
    private var setupHoldStart: CFTimeInterval?
    private var setupSwap = false, setupFlipX = false
    private var setupPanel: NSPanel?
    private var setupLabel: NSTextField?
    private let setupTest = env["VMC_CALTEST"]       // testing: "xy" or "yx" fakes the two tilts

    private var overlays: [Overlay] = []
    private var statusItem: NSStatusItem!
    private var offset = SIMD2<Double>(0, 0)
    private var lastTick = CACurrentMediaTime()
    private var lastWatchdog = CACurrentMediaTime()
    private var manualOn = defaults.bool(forKey: "manualOn")                             // switched on by hand
    private var autoInVehicle = defaults.object(forKey: "autoInVehicle") as? Bool ?? true
    private var dismissedThisRide = false       // switched off by hand while a vehicle was detected
    private let menu = NSMenu()
    private var shown = false

    func applicationDidFinishLaunching(_ note: Notification) {
        // New menu bar items go to the far left, where a MacBook's notch or the front app's menus
        // can hide them. Unless the user has dragged the icon somewhere, start it near the right.
        let positionKey = "NSStatusItem Preferred Position VehicleMotionCues"
        if defaults.object(forKey: positionKey) == nil { defaults.set(190.0, forKey: positionKey) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "VehicleMotionCues"
        // Click = dots on/off. Right-click (or Control/Option-click) = options menu.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(iconClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self
        updateIcon()
        if env["VMC_CLICKTEST"] != nil {        // testing: click the icon at 2 s and again at 6 s
            for delay in [2.0, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.statusItem.button?.performClick(nil) }
            }
        }

        Motion.shared.start()
        rebuildOverlays()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildOverlays),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        let arguments = CommandLine.arguments
        if arguments.contains("--login-item") { setLoginItem(true) }
        if arguments.contains("--calibrate") || setupTest != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.startSetup() }
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func rebuildOverlays() {
        overlays.forEach { $0.window.close() }
        overlays = NSScreen.screens.map(Overlay.init)
        overlays.forEach { $0.layout(offset: offset) }
        shown = false
        updateVisibility()
    }

    @objc private func didWake() { Motion.shared.wakeSensor() }

    // MARK: Start at login

    private var loginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            NSLog("VMC: start at login %@", on ? "on" : "off")
        } catch {
            NSLog("VMC: could not change start at login: %@", error.localizedDescription)
        }
    }

    // MARK: Direction setup

    @objc private func startSetup() {
        if setupPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
                                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Vehicle Motion Cues: Set Dot Direction"
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            let label = NSTextField(wrappingLabelWithString: "")
            label.font = .systemFont(ofSize: 15)
            label.alignment = .center
            label.frame = NSRect(x: 20, y: 15, width: 400, height: 115)
            panel.contentView?.addSubview(label)
            setupPanel = panel
            setupLabel = label
        }
        setupStep = .liftLeft
        setupStarted = CACurrentMediaTime()
        setupHoldStart = nil
        setupBaseline = Motion.shared.tilt
        setupLabel?.stringValue = "Step 1 of 2\n\nWith the laptop sitting level, lift its LEFT side about an inch and hold it there."
        setupPanel?.center()
        setupPanel?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        if setupStep != .finished { setupStep = .none }
    }

    /// True once `condition` has held continuously for `seconds`.
    private func held(_ condition: Bool, for seconds: Double, now: CFTimeInterval) -> Bool {
        guard condition else { setupHoldStart = nil; return false }
        if setupHoldStart == nil { setupHoldStart = now }
        guard now - setupHoldStart! >= seconds else { return false }
        setupHoldStart = nil
        return true
    }

    private func tickSetup(now: CFTimeInterval) {
        guard setupStep != .none, setupStep != .finished else { return }
        let elapsed = now - setupStarted
        if let test = setupTest {       // fake: tilt 1–3 s on the first axis, 5–8 s on the second
            let first = test == "yx" ? SIMD3(0, -0.08, 0) : SIMD3(-0.08, 0, 0)
            let second = test == "yx" ? SIMD3(0.08, 0, 0) : SIMD3(0, 0.08, 0)
            Motion.shared.testTilt = (1...3).contains(elapsed) ? first : (5...8).contains(elapsed) ? second : .zero
        }
        if elapsed > 120 { setupStep = .none; setupPanel?.orderOut(nil); return }

        let lean = Motion.shared.tilt - setupBaseline
        let x = lean.x, y = lean.y
        let tilted = 0.045      // g, about 2.5° of lean
        switch setupStep {
        case .liftLeft:
            // Whichever sensor axis responds is the left/right one. The right side is now the low
            // side, and dots should drift toward the low side.
            let clear = max(abs(x), abs(y)) > tilted && max(abs(x), abs(y)) > 1.5 * min(abs(x), abs(y))
            if held(clear, for: 0.5, now: now) {
                setupSwap = abs(y) > abs(x)
                setupFlipX = (setupSwap ? y : x) < 0
                setupStep = .setDown
                setupLabel?.stringValue = "Got it.\n\nNow set the laptop back down level."
            }
        case .setDown:
            if held(simd_length(SIMD2(x, y)) < 0.02, for: 0.6, now: now) {
                setupBaseline = Motion.shared.tilt
                setupStep = .liftFront
                setupLabel?.stringValue = "Step 2 of 2\n\nNow lift the FRONT edge (the edge nearest you) about an inch and hold it there."
            }
        case .liftFront:
            // The hinge side is now the low side, so dots should drift up the screen.
            let along = setupSwap ? x : y, across = setupSwap ? y : x
            if held(abs(along) > tilted && abs(along) > 1.5 * abs(across), for: 0.5, now: now) {
                let flipY = along < 0
                NSLog("VMC: direction set: swap=%d flipX=%d flipY=%d", setupSwap ? 1 : 0, setupFlipX ? 1 : 0, flipY ? 1 : 0)
                if setupTest == nil {
                    Motion.shared.swapAxes = setupSwap; defaults.set(setupSwap, forKey: "swapAxes")
                    Motion.shared.flipX = setupFlipX; defaults.set(setupFlipX, forKey: "flipX")
                    Motion.shared.flipY = flipY; defaults.set(flipY, forKey: "flipY")
                    defaults.set(true, forKey: "directionSet")
                }
                setupStep = .finished
                setupLabel?.stringValue = "Done. The dots now move the right way.\n\nYou can set the laptop down."
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.setupPanel?.orderOut(nil)
                    self?.setupStep = .none
                }
            }
        default: break
        }
    }

    // MARK: Menu bar icon

    @objc private func iconClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
            || event?.modifierFlags.contains(.option) == true
        if wantsMenu {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleDots()
        }
    }

    /// Flip whatever is on screen right now: showing -> hidden, hidden -> showing.
    @objc private func toggleDots() {
        if shown {
            manualOn = false
            Motion.shared.demo = false
            dismissedThisRide = Motion.shared.inVehicle   // stay off for the rest of this ride
        } else {
            manualOn = true
            dismissedThisRide = false
        }
        defaults.set(manualOn, forKey: "manualOn")
        updateVisibility()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name = shown ? "car.side.fill" : "car.side"
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Vehicle Motion Cues") {
            button.image = image
        } else {
            button.title = shown ? "●" : "○"
        }
        button.toolTip = "Vehicle Motion Cues: \(shown ? "on" : "off"). Click to switch, right-click for options."
    }

    private var wantsDots: Bool {
        if setupStep != .none || manualOn || Motion.shared.demo { return true }
        return autoInVehicle && Motion.shared.inVehicle && !dismissedThisRide
    }

    /// Fade the dots in or out when the answer to "should they be showing?" changes.
    private func updateVisibility() {
        let want = wantsDots
        guard want != shown else { return }
        shown = want
        updateIcon()
        for overlay in overlays {
            let window = overlay.window
            if want {
                window.alphaValue = 0
                window.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.8
                window.animator().alphaValue = want ? 1 : 0
            }, completionHandler: { [weak self] in
                if self?.shown == false { window.orderOut(nil) }
            })
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)
        lastTick = now

        if now - lastWatchdog > 2 {            // sensor went quiet (sleep, etc.): nudge it
            lastWatchdog = now
            if now - Motion.shared.lastSampleTime > 2 { Motion.shared.wakeSensor() }
        }
        if !Motion.shared.inVehicle { dismissedThisRide = false }
        tickSetup(now: now)
        updateVisibility()
        guard shown else { return }
        let v = Motion.shared.velocity
        guard simd_length(v) > 0.3, now - Motion.shared.lastSampleTime < 0.5 else { return }
        offset += v * dt
        offset.x = offset.x.truncatingRemainder(dividingBy: 116 * 100)   // multiple of 2 × spacing
        offset.y = offset.y.truncatingRemainder(dividingBy: 116 * 100)
        overlays.forEach { $0.layout(offset: offset) }
    }

    // Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let live = CACurrentMediaTime() - Motion.shared.lastSampleTime < 1
        menu.addItem(withTitle: live ? "Motion sensor: active" : "Motion sensor: not responding", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: String(format: "In a vehicle: %@ (shake %.1f, needs 3.0)",
                                       Motion.shared.inVehicle ? "yes" : "no", Motion.shared.vibrationMg),
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, shown ? "Turn Dots Off" : "Turn Dots On", #selector(toggleDots), false)
        add(menu, "Turn On Automatically in a Vehicle", #selector(toggleAuto), autoInVehicle)
        menu.addItem(.separator())
        add(menu, "Preview Motion (12 s)", #selector(preview), false)
        menu.addItem(.separator())
        add(menu, "Reverse Left/Right", #selector(toggleFlipX), Motion.shared.flipX)
        add(menu, "Reverse Forward/Back", #selector(toggleFlipY), Motion.shared.flipY)
        add(menu, "Swap Axes", #selector(toggleSwap), Motion.shared.swapAxes)
        add(menu, defaults.bool(forKey: "directionSet") ? "Set Dot Direction Again…" : "Set Dot Direction…", #selector(startSetup), false)
        menu.addItem(.separator())
        add(menu, "Start at Login", #selector(toggleLoginItem), loginItemEnabled)
        menu.addItem(.separator())
        add(menu, "Quit Vehicle Motion Cues", #selector(quit), false)
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ checked: Bool) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
    }

    @objc private func toggleAuto() {
        autoInVehicle.toggle()
        defaults.set(autoInVehicle, forKey: "autoInVehicle")
        updateVisibility()
    }
    @objc private func preview() { Motion.shared.demoStart = CACurrentMediaTime(); Motion.shared.demo = true }
    @objc private func toggleFlipX() { Motion.shared.flipX.toggle(); defaults.set(Motion.shared.flipX, forKey: "flipX") }
    @objc private func toggleFlipY() { Motion.shared.flipY.toggle(); defaults.set(Motion.shared.flipY, forKey: "flipY") }
    @objc private func toggleSwap() { Motion.shared.swapAxes.toggle(); defaults.set(Motion.shared.swapAxes, forKey: "swapAxes") }
    @objc private func toggleLoginItem() { setLoginItem(!loginItemEnabled) }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
