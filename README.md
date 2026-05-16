# Mac Hand Control

Native macOS prototype for controlling Spaces and fullscreen with camera hand gestures.

![Mac Hand Control gesture guide](Docs/gesture-guide.png)

## Gestures

- Fullscreen: pinch with both hands, keep pinching, then spread or squeeze the two hands. This sends `Control + Command + F` to the app you were using.
- Switch Space: swipe one open hand horizontally. A left swipe sends `Control + Right`; a right swipe sends `Control + Left`.

The debug panel shows a mirrored camera feed, hand skeletons, yellow thumb-to-index pinch lines, green open-hand markers, and live gesture state for each detected hand.

## Install From Release

Download the latest `Mac-Hand-Control.dmg` or `Mac-Hand-Control.zip` from the GitHub Releases page:

https://github.com/minwoo19930301/mac-hand-control/releases

DMG is the friendlier install path. Open `Mac-Hand-Control.dmg`, then drag `Mac Hand Control.app` into `Applications`.

If you download the zip instead, unzip it and move `Mac Hand Control.app` into `Applications`. Open the app, approve camera access, and use the in-app `Enable AX` button to enable Accessibility control.

Because this prototype is ad-hoc signed instead of Developer ID signed and notarized, macOS may ask for approval in Privacy & Security the first time you open a downloaded copy.

## Build Locally

```sh
./build.sh
```

The build script creates:

```txt
build/Mac Hand Control.app
```

## Package A DMG

```sh
./package.sh
```

The package script builds the app and creates:

```txt
dist/Mac-Hand-Control.dmg
```

## Distribution

For a smoother public install, the next step is signing with an Apple Developer ID certificate and notarizing the DMG. Without that, the app still works, but macOS will show extra security prompts after download.
