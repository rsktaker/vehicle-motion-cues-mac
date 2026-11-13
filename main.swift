// Vehicle Motion Cues for macOS — dots at the screen edges that move with the
// vehicle, driven by the MacBook's built-in accelerometer and gyroscope (Apple Silicon).
import AppKit
import IOKit
import IOKit.hid
import simd
import ServiceManagement

let defaults = UserDefaults.standard
let env = ProcessInfo.processInfo.environment
/// The dots reach further in from each edge unless the user has chosen the narrow band.
var wideBand: Bool { defaults.object(forKey: "wideBand") as? Bool ?? true }

// MARK: - Motion (accelerometer + gyroscope -> dot velocity)

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
    private var liftRest = 0.0
    private let liftTau = 1.0           // s: how quickly a steady up/down reading is forgotten
    private var managers: [IOHIDManager] = []
    private var accelSender: UnsafeMutableRawPointer?

    // Gyroscope. An accelerometer alone cannot tell "the laptop was tilted" from "the vehicle
    // sped up": both shift the pull it feels sideways. The gyroscope measures the turning
    // itself, so "which way is down" can follow a tilt as it happens and the tilt cancels out.
    private let useGyro = env["VMC_NOGYRO"] == nil   // testing: behave like an accelerometer-only Mac
    private var gyro = SIMD3<Double>(0, 0, 0)        // rad/s, latest reading
    // What the gyroscope reads when nothing is turning (rad/s). Left uncorrected, a small offset
    // slowly tips the app's sense of "down" and the dots creep. It is measured only while the laptop
    // is truly still, because a slow tilt looks just like an offset, and it is saved between launches
    // so the dots are right from the first moment on a lap or in a car, where nothing is ever still.
    private var gyroBias = SIMD3<Double>(0, 0, 0)
    private var haveBias = false
    private let saveBias = env["VMC_REPLAY"] == nil
    private var savedBias = SIMD3<Double>(0, 0, 0)
    private var stillStart: CFTimeInterval = 0
    private var stillCount = 0
    private var accelLow = SIMD3<Double>(0, 0, 0), accelHigh = SIMD3<Double>(0, 0, 0), accelSum = SIMD3<Double>(0, 0, 0)
    private var gyroLow = SIMD3<Double>(0, 0, 0), gyroHigh = SIMD3<Double>(0, 0, 0), gyroSum = SIMD3<Double>(0, 0, 0)
    private var lastStillAccel: SIMD3<Double>?
    private var gyroSender: UnsafeMutableRawPointer?
    private(set) var lastGyroTime: CFTimeInterval = 0
    var gyroLive: Bool { useGyro && lastSampleTime - lastGyroTime < 0.1 && lastGyroTime > 0 }

    private let gravityTau = 6.0        // s: how slowly "which way is down" drifts toward the accelerometer
    private let unlearnedTau = 2.0      // s: the same, until the gyroscope's offset has been measured
    private let accelOnlyTau = 4.0      // s: the same, when there is no gyroscope to follow tilts
    private let smoothTau = 0.08        // s: rejects typing/road buzz
    private let velocityTau = 0.27      // s: flow decays once speed is steady
    private let deadzone = 0.006        // g
    // Quick moves (a jolt, a hand shake) shift the dots by pointsPerMps for each m/s of speed change.
    // A steady push settles at pointsPerMps × velocityTau, about 97 points/s for each m/s².
    private let pointsPerMps = 360.0
    private let maxSpeed = 900.0

    func start() {
        if saveBias, let saved = defaults.array(forKey: "gyroOffset") as? [Double], saved.count == 3 {
            gyroBias = SIMD3(saved[0], saved[1], saved[2]) * (.pi / 180)     // stored in degrees/second
            savedBias = gyroBias
            haveBias = true
            NSLog("VMC: gyroscope offset loaded: %.2f %.2f %.2f °/s", saved[0], saved[1], saved[2])
        }
        wakeSensor()
        open(usage: 3)      // accelerometer
        if useGyro { open(usage: 9) }   // gyroscope
    }

    private func open(usage: Int) {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: usage] as CFDictionary)
        IOHIDManagerRegisterInputReportCallback(m, { context, _, sender, _, _, report, length in
            guard length >= 18 else { return }
            func axis(_ offset: Int) -> Double {
                var v: Int32 = 0
                memcpy(&v, report + offset, 4)
                return Double(Int32(littleEndian: v)) / 65536.0
            }
            let reading = SIMD3(axis(6), axis(10), axis(14))
            let now = CACurrentMediaTime()
            if Int(bitPattern: context) == 3 {
                Motion.shared.ingest(reading, now: now, sender: sender)          // in g
            } else {
                Motion.shared.ingestGyro(reading, now: now, sender: sender)      // in degrees/second
            }
        }, UnsafeMutableRawPointer(bitPattern: usage))
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess { NSLog("VMC: could not open motion sensor %d (0x%x)", usage, result) }
        managers.append(m)
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

    /// If more than one device answers, listen to the first; switch only if that one goes silent.
    private func accept(_ sender: UnsafeMutableRawPointer?, locked: inout UnsafeMutableRawPointer?,
                        lastTime: CFTimeInterval, now: CFTimeInterval) -> Bool {
        if sender == locked { return true }
        guard locked == nil || now - lastTime > 2 else { return false }
        locked = sender
        return true
    }

    func ingestGyro(_ degreesPerSecond: SIMD3<Double>, now: CFTimeInterval, sender: UnsafeMutableRawPointer? = nil) {
        guard accept(sender, locked: &gyroSender, lastTime: lastGyroTime, now: now) else { return }
        if lastGyroTime == 0 { NSLog("VMC: gyroscope streaming") }
        gyro = degreesPerSecond * (.pi / 180)
        lastGyroTime = now
    }

    func ingest(_ reading: SIMD3<Double>, now: CFTimeInterval, sender: UnsafeMutableRawPointer? = nil) {
        guard accept(sender, locked: &accelSender, lastTime: lastSampleTime, now: now) else { return }

        // After a gap (sleep, lid closed) the laptop may be sitting differently: start afresh.
        if now - lastSampleTime > 1 {
            haveGravity = false
            smooth = .zero; velocity = .zero; liftRest = 0
            stillCount = 0; lastStillAccel = nil
        }
        let dt = min(max(now - lastSampleTime, 0.001), 0.05)
        lastSampleTime = now
        sampleCount += 1
        if sampleCount == 1 { NSLog("VMC: accelerometer streaming") }

        if !haveGravity { gravity = reading; haveGravity = true; bandFast = reading; bandSlow = reading; shakeWindowStart = now }
        if gyroLive {
            measureGyroOffset(reading, now: now)
            // Turn "down" along with the laptop, then let it drift slowly toward the accelerometer.
            gravity += simd_cross(gravity, gyro - gyroBias) * dt
            gravity += (reading - gravity) * (dt / (haveBias ? gravityTau : unlearnedTau))
        } else {
            gravity += (reading - gravity) * (dt / accelOnlyTau)
        }
        detectVehicle(reading, now: now, dt: dt)

        // Remove gravity. Split what is left into the part parallel to the ground and the
        // up/down part (bumps, or the laptop being lifted), which moves the dots vertically.
        var linear = reading - gravity
        let down = simd_normalize(gravity)
        // A vehicle never pushes straight up or down for long, so anything steady in that
        // direction is sensor error (after a hard knock, say) and is faded out within a second.
        let rawLift = -simd_dot(linear, down)
        liftRest += (rawLift - liftRest) * min(1, dt / liftTau)
        let lift = rawLift - liftRest
        linear -= simd_dot(linear, down) * down

        var h = SIMD2(linear.x, linear.y)
        if swapAxes { h = SIMD2(h.y, h.x) }
        if flipX { h.x = -h.x }
        if flipY { h.y = -h.y }
        h.y += lift
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

    /// Looks at one second at a time. If neither sensor moved during it, and the laptop sits exactly
    /// as it did the second before, whatever the gyroscope read is its resting offset.
    private func measureGyroOffset(_ reading: SIMD3<Double>, now: CFTimeInterval) {
        if stillCount == 0 {
            stillStart = now
            accelLow = reading; accelHigh = reading; accelSum = .zero
            gyroLow = gyro; gyroHigh = gyro; gyroSum = .zero
        }
        accelLow = simd_min(accelLow, reading); accelHigh = simd_max(accelHigh, reading); accelSum += reading
        gyroLow = simd_min(gyroLow, gyro); gyroHigh = simd_max(gyroHigh, gyro); gyroSum += gyro
        stillCount += 1
        guard now - stillStart >= 1 else { return }
        let n = Double(stillCount)
        stillCount = 0

        // At rest the readings wander by about 0.004 g and 0.4°/s within a second.
        let calm = n >= 50 && simd_reduce_max(accelHigh - accelLow) < 0.008
            && simd_reduce_max(gyroHigh - gyroLow) < 0.014                     // 0.8°/s
        let accel = accelSum / n, offset = gyroSum / n
        defer { lastStillAccel = calm ? accel : nil }
        guard calm, let before = lastStillAccel,
              simd_reduce_max(simd_abs(accel - before)) < 0.001,               // not tilting, even slowly
              simd_length(offset) < 0.05 else { return }                       // 3°/s: more is not an offset
        gyroBias += (offset - gyroBias) * (haveBias ? 0.3 : 1)
        haveBias = true
        if saveBias, simd_length(gyroBias - savedBias) > 0.0005 {              // 0.03°/s
            savedBias = gyroBias
            let degrees = gyroBias * (180 / .pi)
            defaults.set([degrees.x, degrees.y, degrees.z], forKey: "gyroOffset")
            NSLog("VMC: gyroscope offset measured: %.2f %.2f %.2f °/s", degrees.x, degrees.y, degrees.z)
        }
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
    private let spacing = 58.0, dotSize = 15.0
    private let band = wideBand ? 250.0 : 130.0    // how far in from each edge the dots reach
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
            let base = side == 0 ? 0.4 * spacing : size.width - (Double(cols) - 2.6) * spacing
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
    private var sensorQuiet = false
    private var manualOn = defaults.bool(forKey: "manualOn")                             // switched on by hand
    private var autoInVehicle = defaults.bool(forKey: "autoInVehicle")                   // opt-in: a lap can shake like a road
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
        NSLog("VMC: dots %@ (sensor %@)", want ? "on" : "off",
              Motion.shared.sampleCount == 0 ? "starting" : CACurrentMediaTime() - Motion.shared.lastSampleTime < 1 ? "live" : "not responding")
        for overlay in overlays {
            let window = overlay.window
            if want {
                window.alphaValue = 0
                window.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = want ? 0.2 : 0.35
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

        if now - lastWatchdog > 2 {            // a sensor went quiet (sleep, etc.): nudge it
            lastWatchdog = now
            let quiet = now - Motion.shared.lastSampleTime > 2
                || (Motion.shared.lastGyroTime > 0 && now - Motion.shared.lastGyroTime > 2)
            if quiet { Motion.shared.wakeSensor() }
            if quiet != sensorQuiet {
                sensorQuiet = quiet
                NSLog("VMC: motion sensor %@", quiet ? "stopped reporting, waking it" : "reporting again")
            }
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
        let sensor = !live ? "not responding" : Motion.shared.gyroLive ? "active" : "active, no gyroscope (tilting will move the dots)"
        menu.addItem(withTitle: "Motion sensor: \(sensor)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: String(format: "In a vehicle: %@ (shake %.1f, needs 3.0)",
                                       Motion.shared.inVehicle ? "yes" : "no", Motion.shared.vibrationMg),
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, shown ? "Turn Dots Off" : "Turn Dots On", #selector(toggleDots), false)
        add(menu, "Turn On Automatically in a Vehicle", #selector(toggleAuto), autoInVehicle)
        menu.addItem(.separator())
        add(menu, "Wider Band of Dots", #selector(toggleWide), wideBand)
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
    @objc private func toggleWide() { defaults.set(!wideBand, forKey: "wideBand"); rebuildOverlays() }
    @objc private func preview() { Motion.shared.demoStart = CACurrentMediaTime(); Motion.shared.demo = true }
    @objc private func toggleFlipX() { Motion.shared.flipX.toggle(); defaults.set(Motion.shared.flipX, forKey: "flipX") }
    @objc private func toggleFlipY() { Motion.shared.flipY.toggle(); defaults.set(Motion.shared.flipY, forKey: "flipY") }
    @objc private func toggleSwap() { Motion.shared.swapAxes.toggle(); defaults.set(Motion.shared.swapAxes, forKey: "swapAxes") }
    @objc private func toggleLoginItem() { setLoginItem(!loginItemEnabled) }
    @objc private func quit() { NSApp.terminate(nil) }
}

// Testing: VMC_REPLAY=<file> runs a recording through the motion code and prints how far the dots
// would have travelled. Rows are "seconds,kind,x,y,z" with kind 3 = accelerometer (g), 9 = gyroscope (°/s).
if let path = env["VMC_REPLAY"] {
    var travel = 0.0, peak = 0.0, first: Double?, last = 0.0
    var offset = SIMD2<Double>(0, 0), lo = SIMD2<Double>(0, 0), hi = SIMD2<Double>(0, 0)
    for line in ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n") {
        let f = line.split(separator: ",").compactMap { Double($0) }
        guard f.count >= 5 else { continue }
        let t = f[0] + 1000, reading = SIMD3(f[2], f[3], f[4])
        if Int(f[1]) == 9 { Motion.shared.ingestGyro(reading, now: t); continue }
        Motion.shared.ingest(reading, now: t)
        let speed = simd_length(Motion.shared.velocity)
        if let _ = first { travel += speed * (t - last); offset += Motion.shared.velocity * (t - last) } else { first = t }
        lo = simd_min(lo, offset); hi = simd_max(hi, offset)
        last = t
        peak = max(peak, speed)
    }
    print(String(format: "%.0f s replayed, gyroscope %@: dots travelled %.0f points, peak speed %.0f points/s, swing %.0f across / %.0f up-down",
                 last - (first ?? last), Motion.shared.gyroLive ? "used" : "not used", travel, peak, hi.x - lo.x, hi.y - lo.y))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
