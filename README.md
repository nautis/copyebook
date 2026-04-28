# copyebook

A small macOS command-line tool that turns the pages of any reading app you own, screenshots each page, runs Apple's Vision OCR over the image, and writes the result out as plain text.

It exists so the books on your shelf can talk to the AI tools you actually use — for personal research, note-taking, accessibility (large-print, text-to-speech, dyslexia-friendly reformatting), and faster recall of things you've already read and paid for.

It's a native macOS equivalent of [TextMuncher](https://textmuncher.com) (which works in the browser via Kindle Cloud Reader). copyebook works against any windowed app — Kindle for Mac, Apple Books, Preview, etc.

## What it does not do

copyebook does **not** decrypt anything. There is no DRM removal, no key extraction, no format conversion of protected files. It only sees what's already drawn on your screen, the same as a screenshot you'd take by hand. If the app won't render a page, copyebook can't read it either.

Use it on books you own, for your own use.

## Requirements

- macOS 14 or newer (uses ScreenCaptureKit)
- Xcode Command Line Tools (`xcode-select --install`)
- Vision framework (ships with macOS)

## Install

```bash
git clone git@github.com:nautis/copyebook.git
cd copyebook
bash build.sh
```

That produces a single binary at `./copyebook`. No dependencies, no package manager, no runtime.

## First run — permissions

copyebook needs two macOS permissions. Both are powerful, both belong to the app that *launches* copyebook (Terminal.app, iTerm, Ghostty, etc.) — not to copyebook itself. Be deliberate about granting them.

### What you're granting

1. **Accessibility** — lets the launching app send synthetic keystrokes to other apps. This is the same capability a keylogger uses. copyebook uses it for one thing: to press the arrow key that turns a page in your reading app. While the permission is on, anything else launched from that terminal can also send keystrokes systemwide.
2. **Screen Recording** — lets the launching app read pixel content from any visible window. This is the same capability a screen recorder uses. copyebook uses it to capture frames of the reading-app window for OCR. While the permission is on, anything else launched from that terminal can also capture any window on your screen.

### Granting

- Grant from System Settings → Privacy & Security → Accessibility / Screen Recording.
- macOS will auto-prompt for Accessibility on first run. Screen Recording must be added manually.
- Re-launch the terminal after granting (macOS reads the permission at launch time).

### Revoking

When you're done capturing, turn the permissions off:

1. System Settings → Privacy & Security → **Accessibility** → toggle the launching terminal app **off** (or click the minus button to remove it entirely).
2. System Settings → Privacy & Security → **Screen Recording** → same.
3. Restart the terminal.

You'll re-grant the next time you use copyebook. That's the right tradeoff — these permissions persist until revoked, and a terminal app is a broad surface to leave keylogger-equivalent rights attached to.

## Usage

Open the book in your reading app, navigate past the cover to the first page of real content, then run:

```bash
./copyebook --app Kindle --pages 200 --output ~/Downloads/my-book
```

Output goes to `<output>/text.txt` plus per-page PNG screenshots (unless you pass `--no-screenshots`).

### Options

| Flag | Default | Notes |
|------|---------|-------|
| `--app <name>` | (interactive picker) | Partial match against window title. |
| `--pages <n>` | `50` | Hard cap; stops earlier if duplicate detection trips. |
| `--key <key>` | `right` | `right`, `left`, `up`, `down`, `space`, or a raw keycode. |
| `--delay <seconds>` | `1.0` | Wait after each page turn — bump to `1.5` if pages are slow to render. |
| `--output <dir>` | `./copyebook-output` | Directory for `text.txt` + PNGs. |
| `--no-screenshots` | off | Skip saving the PNGs (text only). |
| `--similarity <0–1>` | `0.9` | Bigram Jaccard threshold for duplicate detection (stops at end of book). |

### Examples

Apple Books:
```bash
./copyebook --app Books --pages 400 --output ~/Downloads/my-book
```

Slow page renders (let pages settle longer):
```bash
./copyebook --app Kindle --pages 200 --delay 1.5 --output ~/Downloads/slow-book
```

Long book, in chunks (work around the page cap and any terminal timeouts):
```bash
./copyebook --app Kindle --pages 180 --output ~/Downloads/book-pt1
# ...continue reading position in Kindle, then:
./copyebook --app Kindle --pages 180 --output ~/Downloads/book-pt2
cat ~/Downloads/book-pt{1,2}/text.txt > ~/Downloads/book-full.txt
```

The first page of part 2 will usually duplicate the last page of part 1; clean by hand or with a quick `awk` pass.

## How it stops

copyebook keeps turning pages until one of:

1. `--pages` is reached.
2. A captured page is nearly identical to the previous one (bigram Jaccard ≥ `--similarity`). This is how it detects end-of-book, modal popups, or pages where the keystroke didn't advance.

When it stops, check the last few PNGs to see why. If it's an end-of-book modal or library view, the book is done. If it's a stuck page, see "Gotchas" below.

## Gotchas

These are notes from real runs against several reading apps. Worth knowing before you start.

### Kindle for Mac

- **Cover view ignores Right Arrow.** Manually advance past the cover before launching copyebook — otherwise duplicate detection trips on page 2.
- **Toolbar overlay swallows keystrokes.** If the top-of-window toolbar (`< Kindle ... Q Aa`) stays visible across pages, click once in the center of the reading pane to dismiss it, then resume. OCR will show the toolbar text on every page when this is happening.
- **The "Recommend this book" end-of-book modal exits to the library** if you dismiss it (Kindle Mac v7.56 behavior). To continue past it into back-matter (notes, index), reopen the book, navigate via Go To → Location, and start a new chunk.
- **Per-page chrome to strip post-OCR:** the literal word `Kindle`, the all-caps running header, `Learning reading speed`, and bare percentage indicators like `24%`. A short Python or sed pass cleans them.

### Apple Books

- Works cleanly. Make sure paginated mode is on (`View → Scrolling View` *off*).
- The back-cover repeat is a clean stop signal — duplicate detection catches it on its own.

### Focus

Page turns go to whatever app is frontmost at the moment of the keystroke. copyebook reactivates the target before every keystroke, but anything that steals focus mid-run (a notification, Spotlight, an IDE rebuild) will break the run. Don't touch the machine while it's working.

### Running in the background

copyebook **must** run in the foreground of the terminal that owns the Screen Recording permission. Backgrounded subprocesses lose their window-server connection and ScreenCaptureKit fails to initialize.

## Output cleanup

Vision OCR is good but not perfect. Expect:

- Drop-cap initials split onto their own line, sometimes with the trailing letters rendered in lookalike Unicode (e.g. `W\nітн` for "With").
- End-of-line hyphenation preserved as a literal hyphen.
- App chrome captured on every page — strip with a one-liner.

Example chrome-strip for Kindle output:

```bash
python3 -c "
import re, sys
chrome = {'Kindle', 'Learning reading speed'}
for line in open(sys.argv[1]):
    s = line.strip()
    if s in chrome: continue
    if re.fullmatch(r'\d{1,3}%', s): continue
    sys.stdout.write(line)
" ~/Downloads/my-book/text.txt > ~/Downloads/my-book-clean.txt
```

## Verifying what you cloned

You're about to grant a binary the ability to log keystrokes and capture any window on your screen. Before you do, verify the source.

### Cheap and effective

After cloning, check that the commit hash on disk matches the commit on GitHub:

```bash
git rev-parse HEAD
# Open https://github.com/nautis/copyebook/commits/main and compare the top commit hash.
```

If they match, you're running the same source GitHub is publishing. The whole codebase is one Swift file (`copyebook.swift`, ~430 lines). It's small enough to read.

### Signed tags

Releases are tagged and SSH-signed with the maintainer's ed25519 key. To verify a tag locally:

```bash
# 1. Fetch the maintainer's public key from GitHub (same key used for auth):
curl -s https://github.com/nautis.keys | head -1 > /tmp/copyebook-key

# 2. Build an allowed_signers file inside the repo:
echo "nautis@github $(cat /tmp/copyebook-key)" > .git/allowed_signers
git config gpg.ssh.allowedSignersFile .git/allowed_signers

# 3. Verify a tag:
git verify-tag v0.1.0
```

A successful verification prints `Good "git" signature for nautis@github with ED25519 key`.

(GitHub's own "Verified" badge requires the maintainer to also upload the key under *SSH signing keys* in account settings — separate from the auth key. The cryptographic guarantee is the same with or without the badge.)

## License

MIT. See [LICENSE](LICENSE).
