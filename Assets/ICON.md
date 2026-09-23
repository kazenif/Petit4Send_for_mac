# Petit4Send Mac icon

`Petit4SendMac-icon.png` is the source of truth for the app icon: the retro pixel-art toolbox and wrench on a cyan rounded tile with a white rim, 1024x1024 with transparency and no lettering.

It is produced from `../icon-candidate.png` by `../Tools/clean-icon.swift`. The candidate is a 198x199 rendering that had been through lossy compression, leaving 6859 distinct colours, ringing along every edge, and isolated dark flecks in the surround. The tool restores the flat artwork:

1. A 3x3 per-channel median removes ringing.
2. k-means over 20 clusters recovers the intended palette and each pixel snaps to it.
3. Palette indices that barely appear in their own neighbourhood are replaced by the local mode, dropping speckles.
4. A flood fill from the border identifies the white surround.
5. A rounded rectangle is fitted to the tile. Both tile edges come from that geometry rather than from the compressed outline: the fitted rectangle grown by the rim width forms the silhouette, and the band just inside the outline — where the stray white and the light halo sit — is filled with the tile colour.
6. The artwork is replicated at the largest integer factor that fits the canvas, so the dots keep hard edges, and centred with transparent padding. Alpha comes from the fitted geometry's signed distance evaluated at output scale, which keeps the rim smooth instead of stair-stepping it.

```sh
swift Tools/clean-icon.swift icon-candidate.png Assets/Petit4SendMac-icon.png 1024
```

Omitting the canvas argument keeps the output at the source size. 1024 lands on a 5x replication of the 198px artwork.

## Pipeline

- `../Tools/build-icon.sh` resizes the PNG into the 16-512 pixel `@1x`/`@2x` representations under `Petit4SendMac.iconset` and runs `iconutil` to produce `../Sources/Petit4SendMac/Resources/Petit4SendMac.icns`.
- `../build-app.sh` runs that script, then copies the icns into the app bundle under a name derived from its content hash, sets `CFBundleIconFile`, bumps `CFBundleVersion`, and signs the bundle. The hashed name and version bump keep macOS from serving a cached copy of an older icon.

## Why the icns sits in the target's resources

Xcode builds this package as a bare executable with no `Info.plist`, so `CFBundleIconFile` never applies there and the Dock would show a blank icon. `Package.swift` therefore declares the icns as a resource of `Petit4SendMac` and `AppDelegate.applicationDidFinishLaunching` installs it, which works with or without a bundle.

Installing it takes two steps, and both matter:

- `NSApp.applicationIconImage` covers the Dock tile only.
- Naming the image `NSApplicationIcon` covers the About panel, alerts, and Help Viewer. Without a bundle that name is already taken — cached as the enclosing folder's icon — and `setName` is a no-op while a name is in use, so the old image has to release it first. Help Viewer picking this up was a surprise: it is a separate process, yet it reads the icon from the running app rather than from the bundle on disk.

Two consequences of declaring the icns as a resource:

- The icns must be committed even though it is generated. Without it SwiftPM sees a target with no resources, stops synthesising `Bundle.module`, and the build fails with `type 'Bundle' has no member 'module'`.
- `../build-app.sh` copies `Petit4Send_Petit4SendMac.bundle` into `Contents/Resources`, because `Bundle.module` traps when its resource bundle is missing.

Because the PNG is already 1024 pixels, `sips` only ever downsamples when building the iconset, so no representation is an interpolated upscale.
