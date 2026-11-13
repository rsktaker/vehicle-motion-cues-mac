# Vehicle Motion Cues for Mac

Dots along the left and right edges of the screen that move with the vehicle you are riding in, like the iPhone's Vehicle Motion Cues. They give your eyes the motion your inner ear already feels, which can reduce motion sickness when reading in a car.

It reads the accelerometer and gyroscope built into Apple Silicon MacBooks, so it needs no AirPods, phone, or webcam.

> macOS 26 and later include Apple's own Vehicle Motion Cues (System Settings > Accessibility > Motion). Use that if you can. This app is for Macs still on macOS 13–15.

## Download

**[Download VehicleMotionCues.dmg](https://github.com/rsktaker/vehicle-motion-cues-mac/releases/latest/download/VehicleMotionCues.dmg)** (Apple Silicon MacBooks, macOS 13 or later)

1. Open the disk image and drag **Vehicle Motion Cues** into **Applications**.
2. Open it from Applications. A car icon appears on the right side of the menu bar. No permissions are requested.

The app is signed with a Developer ID and notarized by Apple, so it opens without a Gatekeeper warning.

## Build from source

Needs the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/rsktaker/vehicle-motion-cues-mac.git
cd vehicle-motion-cues-mac
./build.sh
open "Vehicle Motion Cues.app"
```

`./make-dmg.sh` packs the disk image; the comments at the top of that script cover signing and notarizing.

## Use

- **Click the car icon** to turn the dots on or off.
- **Right-click the icon** (or Control/Option-click) for options.
- **Turn On Automatically in a Vehicle** (off by default): the dots fade in after about 12 seconds of continuous road vibration and fade out 2 minutes after it stops. It can also switch on by mistake; see Limits.
- **Set Dot Direction…**: tilt the laptop twice when asked, and the app works out which way the sensor's axes point.
- **Wider Band of Dots** (on by default): the dots reach about 5 cm in from each edge of a 14-inch screen. Switch it off for a narrow strip, as on a phone; see the note on research below.
- **Preview Motion**: 12 seconds of simulated motion, to see what it looks like at a desk.
- **Start at Login**.

The dots are click-through and are hidden from screenshots and screen sharing.

## How it works

- The accelerometer and gyroscope are undocumented HID devices (`AppleSPUHIDDevice`, usage page `0xFF00`, usages `3` and `9`), each reporting about 100 times a second. No root access is needed.
- Tilting the laptop and accelerating the vehicle look the same to an accelerometer: both shift the pull it feels sideways. The gyroscope measures the turning directly, so the app's sense of "down" turns with the laptop and a tilt cancels out. That estimate then drifts slowly toward the accelerometer to correct gyroscope error.
- A gyroscope reads slightly off zero even when nothing is turning. The app measures that offset whenever the laptop sits completely still for two seconds (on a table, say) and remembers it.
- Gravity is subtracted. What remains, parallel to the ground, is the vehicle's acceleration.
- Dots move opposite to that acceleration: turn left and they slide right, brake and they slide up. Up-and-down motion (bumps, or lifting the laptop) moves them vertically as well.
- Quick movements shift the dots a little; a sustained push keeps them flowing. Shaking the laptop 6 cm side to side swings them about 20 points.
- Vehicle detection takes the median 1–12 Hz vibration over each second. A still desk measures about 0.5 milli-g; the threshold is 3. The median ignores keystroke thumps.

## What the research says

- The closest study is [Bubble Margin](https://dl.ifip.org/hal-02544623v1) (Meschtscherjakov, Strumegger and Trösterer, 2019): bubbles in the margin of a phone's text, moved by the phone's sensors. Ten people reading on real roads reported milder symptoms.
- A [2023 review](https://pubmed.ncbi.nlm.nih.gov/37981841/) found visual cues worked better in peripheral vision than in central vision alone. Results across studies are mixed, and Apple has published no data for its own feature.
- No study found tests how wide the band of dots should be. Research on the feeling of self-motion finds that a larger moving area gives a stronger effect, and [one simulator study](https://publications.tno.nl/publication/34637359/PRaw0I/winkel-2020-efficacy.pdf) found that adding more visual information stops helping past a point. The wider band is the default because of the first of those findings; that it helps more than the narrow one is not shown. At 55 cm it spans about 5° of vision at each edge of a 14-inch MacBook, and the narrow band about 2.7°, similar to the strip on a phone held at 30 cm.

## Limits

- Developed on one machine: a 14-inch MacBook Pro (M4) on macOS 15.6.
- Not yet tested in a moving vehicle. Tilt rejection was checked against recordings of the laptop being moved on a lap and against simulated tilts and braking.
- The vehicle detection was tested with simulated vibration only, and its threshold is an estimate. In a day of ordinary use on a lap it switched on by mistake five times, which is why it is off by default.
- On a Mac without the gyroscope device, the app falls back to the accelerometer alone, and tilting the laptop moves the dots. The menu says so.
- The sensor interface is undocumented and could change in a macOS update.

## Testing hooks

Environment variables, for running the binary directly: `VMC_DEMO` (simulated motion), `VMC_SHAKE` (simulated road vibration), `VMC_CALTEST=xy|yx` (simulated direction setup), `VMC_CLICKTEST` (simulated icon clicks), `VMC_SHARE` (let the dots appear in screenshots), `VMC_NOGYRO` (ignore the gyroscope), `VMC_REPLAY=<file>` (run a recording through the motion code and print how far the dots would travel; rows are `seconds,kind,x,y,z` with kind `3` for accelerometer readings in g and `9` for gyroscope readings in degrees per second).

## Credit

The way to read the sensor follows [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer).
