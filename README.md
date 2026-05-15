# Mac Hand Control

Native macOS prototype for controlling Spaces and fullscreen with camera hand gestures.

## Build

```sh
./build.sh
```

The build script creates:

```txt
build/Mac Hand Control.app
```

Open the app, approve camera access, and enable Accessibility using the in-app `Enable AX` button if needed.

Gestures:

- Pinch with both hands, keep pinching, then spread or squeeze the two hands to send `Control + Command + F`.
- Swipe an open hand left to send `Control + Right`.
- Swipe an open hand right to send `Control + Left`.

The debug panel shows a mirrored camera feed, hand skeletons, yellow thumb-to-index pinch lines, green open-hand markers, and live gesture state for each detected hand.

## Distribution

This is a local prototype. The app is ad-hoc signed for development, so a downloaded copy may require macOS approval in Privacy & Security and Accessibility settings.
