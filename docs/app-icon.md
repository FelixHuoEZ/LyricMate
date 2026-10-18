# App Icon

LyricMate uses an original musical-note mark with two lyric bars. The brighter
bar represents the active lyric. Its rounded tile has transparent outer padding;
the menu-bar symbol stays monochrome for readability.

## Assets And Origin

- `LyricPreview/Resources/LyricMateIcon-1024.png`: 1024-pixel RGBA master.
- `LyricPreview/Resources/LyricMate.icns`: 16, 32, 128, 256 and 512-point
  variants, each at 1x and 2x.

The artwork was generated with OpenAI's image-generation tool and refined for
cleaner edges, then resized and packaged with native macOS tools. No upstream
LyricFever or Spotify artwork was supplied as an input. It contains no screenshots,
lyrics, account data or local configuration. The design does not imply endorsement
by an external service.

## Build And Check

The normal build copies the checked-in icon before code signing and validates the
bundled icon. To rebuild its container into a new file:

```sh
bash scripts/build-lyricmate-icon.sh /tmp/LyricMate.icns
bash scripts/build-lyric-preview.sh
bash scripts/test-lyricmate-icon.sh "dist/LyricMate Alpha.app"
```

The icon builder refuses to overwrite existing output and requires no online
image-generation API. Checks cover the bundle reference, exact asset bytes, all
ten dimensions/scales, alpha channels and code signing. These build-time checks
do not prove that an installed Finder or Dock cache has refreshed.

The source export permits only the two named icon files. Arbitrary images,
settings, local diagnostics, application bundles and installation receipts remain
outside the source allowlist. Alpha application and configuration identifiers
are unchanged.
