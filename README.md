# Tack

**Convert**, **Compress** and **Upscale** boxes that appear right under Vorssaint's Shelf when you drag images. Hover a box mid-drag to see its options, drop on one, and the result lands next to the original.

<p><img src="docs/convert.png" width="300" alt="Tack's Convert box expanded to JPG, PNG, WebP, HEIC and AVIF"> <img src="docs/upscale.png" width="300" alt="Tack's Upscale box expanded"></p>

<img src="docs/results.png" width="300" alt="Tack showing a finished result to drag back">

- Convert to JPG, PNG, WebP, HEIC or AVIF.
- Compress (light / medium / strong); PNGs use pngquant when it's installed.
- Upscale 2× (Lanczos).
- Works on png, jpg, webp, heic, avif, tiff and bmp files, while dragging or while they sit on the Shelf.
- No menu bar icon. Open Tack again from Applications to quit it or change Open at Login.

## Requirements

- macOS 26 or later.
- **Vorssaint**, running, with its **Shelf** turned on. Tack is an add-on to Vorssaint's Shelf: it finds the Shelf window on screen and reads the Shelf's file list from Vorssaint's preferences. Without Vorssaint (or with the Shelf off) Tack does nothing. Tested with Vorssaint 3.4 using shake-to-summon; the notch Shelf hasn't been tested.
- Optional, from Homebrew: `brew install webp` (needed for **WebP** output) and `brew install pngquant` (better PNG compression).

## Install

```sh
git clone https://github.com/Byaydenrx/Tack.git
cd Tack
./install.sh
```

`install.sh` builds Tack from source, copies it to `~/Applications` and opens it. To only build: `./build.sh` makes `build/Tack.app` (universal: Apple silicon and Intel). Either needs Swift 6 from the Xcode Command Line Tools (`xcode-select --install`) or Xcode.

Downloaded builds aren't notarized, so macOS blocks them the first time: System Settings › Privacy & Security › **Open Anyway**. Building it yourself avoids that.

## Data

None. Results are saved next to the original (or in `~/Downloads` if that folder is private or read-only). Log: `~/Library/Logs/Tack.log` (trimmed to the newest 256 KB once it passes 1 MB).

## Test modes

`Tack --process convert:jpg|compress:medium|upscale:2 <files>`, `--snapshot <dir>`, `--preview`.

## License

MIT — see [LICENSE](LICENSE). Vorssaint is a separate app and isn't affiliated with this project.
