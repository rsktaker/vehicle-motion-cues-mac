# Vehicle Motion Cues for Mac

Dots along the left and right edges of the screen that move with the vehicle you are riding in, like the iPhone's Vehicle Motion Cues. They give your eyes the motion your inner ear already feels, which can reduce motion sickness when reading in a car.

It reads the accelerometer built into Apple Silicon MacBooks, so it needs no AirPods, phone, or webcam.

> macOS 26 and later include Apple's own Vehicle Motion Cues (System Settings > Accessibility > Motion). Use that if you can. This app is for Macs still on macOS 13–15.

## Install

Needs an Apple Silicon MacBook and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/rsktaker/vehicle-motion-cues-mac.git
cd vehicle-motion-cues-mac
./build.sh
open "Vehicle Motion Cues.app"
```

A car icon appears in the menu bar. No permissions are requested.

## Use

- **Click the car icon** to turn the dots on or off.
- **Right-click the icon** (or Control/Option-click) for options.
- **Turn On Automatically in a Vehicle** (on by default): the dots fade in after about 12 seconds of continuous road vibration and fade out 2 minutes after it stops.
- **Set Dot Direction…**: tilt the laptop twice when asked, and the app works out which way the sensor's axes point.
- **Preview Motion**: 12 seconds of simulated motion, to see what it looks like at a desk.
- **Start at Login**.

The dots are click-through and are hidden from screenshots and screen sharing.

## How it works

- The accelerometer is an undocumented HID device (`AppleSPUHIDDevice`, usage page `0xFF00`, usage `3`) reporting about 100 times a second. No root access is needed.
- Gravity is tracked with a slow filter and subtracted. What remains, parallel to the ground, is the vehicle's acceleration.
- Dots move opposite to that acceleration: turn left and they slide right, brake and they slide up.
- Vehicle detection takes the median 1–12 Hz vibration over each second. A still desk measures about 0.5 milli-g; the threshold is 3. The median ignores keystroke thumps.

## Limits

- Developed on one machine: a 14-inch MacBook Pro (M4) on macOS 15.6.
- The vehicle detection was tested with simulated vibration, not yet on a real road. The threshold is an estimate.
- Any continuous shaking for 12 seconds can trigger it, such as bouncing a leg with the laptop on your lap.
- The sensor interface is undocumented and could change in a macOS update.

## Testing hooks

Environment variables, for running the binary directly: `VMC_DEMO` (simulated motion), `VMC_SHAKE` (simulated road vibration), `VMC_CALTEST=xy|yx` (simulated direction setup), `VMC_CLICKTEST` (simulated icon clicks), `VMC_SHARE` (let the dots appear in screenshots).

## Credit

The way to read the sensor follows [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer).
