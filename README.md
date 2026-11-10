# Spencil

Trace a reference image onto real paper, using your iPhone (or a Mac with Continuity Camera) as a see-through guide.

## Run it

```sh
xcodegen generate        # creates Spencil.xcodeproj from project.yml
open Spencil.xcodeproj
```

- **iPhone**: pick the `Spencil` scheme and your phone, then set your team under *Signing & Capabilities*. The camera doesn't work in the Simulator.
- **Mac**: pick the `SpencilMac` scheme. With your iPhone near the Mac (Continuity Camera), choose the **Desk View** camera to get a top-down view of the desk.

Core logic tests: `cd SpencilCore && swift test`

## How it works

1. **New Drawing**: choose an image and the paper size.
2. **Place**: drag, pinch and twist to position the image *on the paper* (stored in mm).
3. **Draw**: the placement is pinned. Pinching and dragging now only zoom the view; the camera never zooms, so the whole sheet stays visible.
4. Sessions save automatically. When you come back, put the sheet down and the image goes back to where it was.

Paper tracking, per frame:
- Vision's document detector finds a rough outline of the sheet the first time.
- `EdgeRefiner` fits a straight line to each edge (RANSAC), and the corners are where the lines meet. A corner under your hand still lands in the right place.
- `PaperTracker` keeps track of which corner is which, smooths jitter, and holds the position when the sheet is covered.
- `PaperSnapshot` saves a 32×44 fingerprint of the sheet every 5 s. After a resume or a lost track it checks the sheet both ways round and picks the one matching your drawing. On blank paper, use **Rotate paper**. The dot on the outline marks the sheet's top-left corner.

## Layout

```
SpencilCore/   pure Swift package: geometry, edge fitting, tracking, snapshots, sessions (+ tests)
App/           SwiftUI app shared by the iOS and macOS targets
  Camera/      AVFoundation capture + per-frame processing
  Render/      Core Image compositing into an MTKView
  Model/       Library (sessions) and DrawingModel (per-drawing state, gestures)
  Views/       session list, new drawing, drawing screen
```
