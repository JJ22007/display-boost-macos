# Display Boost

A small, local-only macOS menu bar utility that opens the built-in Liquid Retina
XDR display's EDR headroom and applies a bounded gamma-table boost.

## Usage

1. Open **Display Boost.app**.
2. Click the sun icon in the menu bar.
3. Choose **开启增亮**, or move the slider to enable automatically, then adjust
   **增亮强度**.
4. Choose **恢复标准亮度** or quit the app to restore the original display state.

F1/F2 keep their normal macOS behaviour from 0–100%. At the top of the native
range, F2 continues into the XDR range in 6.25% steps up to 160%; F1 walks back
through the same range. macOS requires one-time Accessibility permission so the
app can consume those brightness-key events instead of adjusting the backlight a
second time. Until permission is granted, the keys pass through to macOS unchanged;
if the native backlight moves while boost is active, Display Boost now yields to that
new system brightness and turns off the extra boost instead of forcing it back up.

The 1600-nit specification is a localized HDR peak, not a sustainable full-screen
brightness. Higher brightness uses more power, produces more heat, and can increase
normal backlight wear.

Enabling the boost temporarily moves the native backlight to 100%; the 100–160%
slider controls the extra EDR/gamma mapping above the normal SDR range. The app
restores the original backlight setting when boost is disabled, the Mac sleeps, or
the app quits.

Do not run it at the same time as BetterDisplay, BrightIntosh, BrightXDR, Lunar,
f.lux, or another utility that changes the display gamma table. This app refuses to
enable when it detects an already-boosted gamma endpoint. Gamma remapping can also
compress or clip highlight detail in HDR photos and video, so restore standard
brightness for color-critical or HDR mastering work.

## Build

```sh
./script/test_logic.sh
./script/build_and_run.sh --verify
./script/package_release.sh
```
