# LumaRAW

A photo-only pro camera app for iPhone, inspired by the layout and workflow of
professional video camera apps (status bar, readout row, tool tabs, big
shutter) but designed from scratch for still photography — with manual
controls, pro monitoring tools, and **full LUT support**: import `.cube`
files, preview them live, and bake them into your photos.

Original design and code; no third-party assets or trademarks.

- Swift 5.9 · SwiftUI · AVFoundation · Core Image/Metal
- iOS 16.0+, iPhone
- No third-party dependencies
- The project file is generated with **XcodeGen** (`project.yml`), so the app
  builds entirely in **GitHub Actions** — no Mac required to develop it.

## Features

**Camera**
- Lens switching between the lenses your device actually has (ultra-wide,
  wide, telephoto, front) — discovered via AVFoundation, never faked
- Manual ISO, shutter speed, exposure compensation (EV), manual focus with
  AF/MF toggle, tap-to-focus, AE/AF lock on long-press
- White balance in Kelvin + tint with auto mode and presets
- Zoom, flash (auto/on/off), self-timer (3s/10s), burst mode (5 shots)
- Formats: HEIF, JPEG, and RAW (Apple ProRAW / Bayer DNG) when the device
  reports support, with graceful fallback when it doesn't
- 12MP / 48MP resolution choice when the device's formats support it
- Volume-button shutter on iOS 17.2+ (AVCaptureEventInteraction)
- Saves to the photo library, optionally into a **LumaRAW** album

**LUTs**
- Import `.cube` (1D, 3D, or combined; sizes 17/33/65 and arbitrary) from
  Files or via "Open in…"/share sheet, with clear errors for malformed files
- Robust parser: `LUT_3D_SIZE`, `LUT_1D_SIZE`, `DOMAIN_MIN`/`DOMAIN_MAX`,
  comments, titles; 1D sections are baked into the 3D cube
- Live GPU preview (CIColorCubeWithColorSpace), intensity slider, A/B compare
- Library with thumbnails (rendered on a generated sample image), rename,
  delete, favorite, reorder; last-used LUT is remembered
- Capture modes: graded only, original only, or both; RAW saves the
  untouched DNG plus an optional LUT-graded JPEG rendered from the RAW data
- Five built-in, programmatically generated looks: Cinematic Teal & Orange,
  B&W Film, Warm Vintage, Log to Rec.709, Neutral Punch
- Rec.709/sRGB assumed by default; optional "treat input as Log" mode applies
  a Log → Rec.709 decode before the creative LUT

**Monitoring (preview-only, all toggleable)**
- RGB + luma histogram, luma waveform (computed on a downscaled buffer at
  ~10fps — off tools cost nothing)
- Zebra stripes with adjustable threshold, focus peaking with color choice,
  false color
- Grids (thirds / center / golden ratio), aspect guides (4:3, 3:2, 16:9,
  1:1), CoreMotion horizon level, clean hide-UI mode

## Building (GitHub Actions)

Every push builds an **unsigned IPA**:

1. Push to this repo (or run the "Build LumaRAW" workflow manually).
2. The workflow installs XcodeGen, runs `xcodegen generate`, builds with
   `xcodebuild` for `generic/platform=iOS` with code signing disabled, and
   packages `Payload/LumaRAW.app` into `LumaRAW.ipa`.
3. Download the `LumaRAW-ipa` artifact from the workflow run.

A separate, non-blocking job runs the `LUTParser` unit tests on a simulator
when one is available; it never fails the IPA build.

An optional signed/TestFlight job is included in
`.github/workflows/build.yml`, fully commented out, with the exact secret
names it needs documented inline (`BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`,
`KEYCHAIN_PASSWORD`, `PROVISIONING_PROFILE_BASE64`,
`APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`,
`APP_STORE_CONNECT_API_KEY_CONTENT`).

### Local build (if you have a Mac)

```sh
brew install xcodegen
xcodegen generate
open LumaRAW.xcodeproj   # or build with xcodebuild as in the workflow
```

## Installing the unsigned IPA without a Mac

The GitHub Actions build is unsigned, so install it with a sideloading tool:

- **Sideloadly** (Windows/Mac): connect the iPhone, drag `LumaRAW.ipa` in,
  sign with a free Apple ID. Re-sign every 7 days on a free account.
- **AltStore**: add the IPA from the Files app; AltStore refreshes it over
  Wi-Fi automatically.
- **TrollStore** (supported iOS versions only): install the IPA permanently,
  no re-signing.

> Free-Apple-ID sideloading limits you to 3 sideloaded apps at a time.

## Using LUTs

1. Open the **LUT** tab → **Library** → **Import**, and pick a `.cube` file
   (or share a `.cube` to LumaRAW from Files/another app).
2. Tap a LUT to select it; the preview updates live. Use the **intensity**
   slider and the **A/B** button to compare against the original.
3. Choose what gets saved under **Settings → Save mode**: graded, original,
   or both.

Built-in LUTs can be renamed, favorited and reordered but not deleted;
imported LUTs can also be deleted.

## Renaming the app

Change `AppConstants.appName` (display strings + Photos album name) and
`PRODUCT_NAME` / target name in `project.yml`.

## Architecture

MVVM, one responsibility per file:

```
project.yml                     XcodeGen definition
.github/workflows/build.yml     CI: unsigned IPA + (non-blocking) tests
LumaRAW/
  App/          App entry point + AppConstants (single rename point)
  Camera/       CameraManager (session, devices, controls, capture)
                CameraViewModel (user-facing state; no per-frame data)
                PhotoCaptureDelegate, PhotoSaver (Photos/DNG/sidecar)
                FramePipeline (LUT preview + scopes on the data-output queue)
                CameraPreviewView (preview layer / Metal view)
                MonitoringStores (histogram / waveform / level stores)
  LUT/          LUTParser, LUTManager, LUTProcessor, BuiltInLUTs
  Monitoring/   HistogramView, WaveformView, ZebraFocusPeaking (effects)
  Views/        CameraView, ControlDials, ControlPanels, LUTLibraryView,
                SettingsView, StatusBarView, Overlays
LumaRAWTests/   LUTParser unit tests
```

Performance rules baked into the design (learned the hard way): all session
work on a dedicated serial queue; frame processing only on the video-data
queue; scopes computed on a ≤256px-wide, ~10fps analysis pass; per-tool
results published to tiny dedicated stores observed by leaf views only — the
root view never sees frame-rate state; one shared Metal-backed CIContext for
rendering and one for encoding; the cheap `AVCaptureVideoPreviewLayer` path
is used whenever no LUT and no image monitor is active.

## Known limitations / next steps

- **On-device behavior is only proven by testing on a real phone.** CI
  proves the app compiles and packages; focus/exposure feel, preview
  rotation in every orientation, and RAW availability are device-dependent.
- **Apple ProRAW / RAW** appears only when the device reports RAW formats.
  The regular (non-Pro) iPhone 16 does not shoot ProRAW, so on that phone
  the format picker effectively offers HEIF/JPEG. When both Bayer and
  ProRAW formats exist, the ProRAW one is chosen as the non-Bayer entry in
  `availableRawPhotoPixelFormatTypes`.
- **48MP** depends on the device's formats reporting ≥48MP photo dimensions
  (Pro models); elsewhere the choice stays hidden/falls back to 12MP.
- **Volume-button shutter** needs iOS 17.2+ (AVCaptureEventInteraction). On
  iOS 16 use the on-screen shutter.
- **Graded saves are re-encoded** from the capture's pixel buffer with the
  LUT applied (EXIF orientation honored); some original metadata (lens
  model, capture settings) is not carried into the graded copy. Originals
  are always the camera's untouched file data.
- **RAW graded sidecar** is a JPEG rendered from the DNG via CIRAWFilter
  with default RAW adjustments, then the selected LUT.
- **Tap-to-focus** maps the tap through normalized preview coordinates; with
  aspect-fill cropping it is approximate at the extreme edges.
- **CI preview rotation** relies on AVCaptureConnection rotation support
  (frames arrive pre-rotated); the preview-layer path is always correct.
- Focus peaking is an approximation built from CIEdges + a luminance mask,
  and zebra/false color analyze the *graded* preview when the pipeline is
  active.
- Burst mode is 5 sequential full captures (not a high-speed burst), and the
  self-timer is implemented in the view model rather than in hardware.

## License

Personal project — all rights reserved.
