# MacShotty fork plan: screenshots first, video as a bonus

MacShotty is a personal fork of macshot. It has its own name and app ID (`com.mrimpossible1.macshotty`), so it can be installed next to the official macshot.

This fork adds Dropbox sharing on top of upstream macshot: every capture can land in a Dropbox `/Share` folder with a share link on the clipboard, redacted and readably named first. This file tracks what is done and what comes next.

Repo: https://github.com/mrimpossible1/macshot-fork (fork of https://github.com/sw33tLie/macshot). Get it with `git clone https://github.com/mrimpossible1/macshot-fork`, open `macshot.xcodeproj` in Xcode and press ⌘R.

## Done in this branch

- **Dropbox uploader** (`macshot/Upload/DropboxUploader.swift`): Settings → Uploads → Dropbox → Connect, then approve on Dropbox's page. MacShotty's own Dropbox app ("MacShotty" in Joel's developer console, key built in as `DropboxUploader.builtInAppKey`, OAuth2 PKCE, no secret in the app), uploads to `/Share` (configurable), never overwrites (`add` + autorename), creates a link. Recordings over 140 MB go up in 32 MB chunks through an upload session.
- **Link options** (Settings → Uploads → Dropbox): public link, team-only link (Dropbox Business), or no link. Optional direct links (`raw=1`) so an image link opens the image itself and previews inline in Slack/iMessage.
- **Links expire after 7 days** (Settings → Uploads → Dropbox → Link expires: Never / 1 / 7 / 30 days, default 7). Expiry applies to everyone, including you; the file stays in Dropbox. Needs a paid Dropbox plan: on Basic the upload stops with a clear message instead of quietly making a permanent link.
- **Monthly archive** (Settings → Uploads → Dropbox, on by default): on the 1st (or the first time the app runs that month), files left in the top of `/Share` from earlier months move into `/Share/Archive/YYYY-MM`, by the month they were taken. Nothing is deleted; subfolders you made are left alone; links keep working. Review each month's folder and delete what you don't need.
- **Enter uploads** (Settings → Uploads): when on, Return after selecting an area uploads and copies the link: one keystroke from capture to shareable URL, like CleanShot Cloud.
- **Video editor upload**: the existing Upload button in the video editor also works with Dropbox.
- **Tests**: `macshotTests/DropboxUploaderTests.swift` covers the request flow with local fixtures (no live Dropbox).
- **English only**: the 40 other language folders are removed and the language picker offers only English.
- **No built-in updater**: Sparkle never starts and "Check for Updates..." is gone, so an update can't replace this fork with official macshot. A monthly scheduled Claude task (1st of each month) reviews upstream and opens an `upstream-sync-YYYY-MM` pull request with a plain-language summary of what's worth taking.
- **Video look presets** (video editor → Background panel → Presets): save the whole look (background, frame, pointer, zoom, keystrokes, camera, captions) under a name, apply it to any recording, delete it. Screen Studio has these; upstream only remembers the last look.
- **Auto-redact before upload** (Settings → Uploads, on by default): one on-device OCR pass covers emails, phone numbers, card numbers, keys and tokens with solid boxes before a screenshot leaves the Mac. Your local copy keeps the original. Neither CleanShot nor Screen Studio does this.
- **Readable file names** (Dropbox, on by default): files are named from the screenshot's most prominent text, e.g. `Payout settings 2026-11-06 at 01.51.07.png`, so `/Share` and the link itself read like what they show. Lines that were redacted are never used as names.
- **Copy link as** (Settings → Uploads): plain URL, Markdown link `[Payout settings](https://…)`, or rich link that pastes into Slack, Notion, Google Docs or Mail as the clickable file name.
- **Before / After** (menu bar → Before / After (Last 2 Captures)): your latest capture is After, the one before it is Before. "Side-by-Side Image" opens a labeled side-by-side (stacked for wide shots) in the editor, so you can mark it up, copy, save or upload it. "Animated GIF…" makes a looping GIF that fades between them; save it, or upload it to Dropbox and copy the link (both shots are auto-redacted first). Shottr has this; CleanShot doesn't.
- **Text eraser** is upstream macshot's, not new here: Pixelate tool → Erase mode, plus "Text only" to erase just the lines of text and fill in the background around them.
- **CleanShot-style defaults**: ⌘⇧4 captures an area and ⌘⇧3 the full screen (turn off the macOS versions in System Settings → Keyboard → Keyboard Shortcuts → Screenshots so MacShotty gets them), and the floating thumbnail appears bottom-left. Both can be changed in Settings.
- **Auto Zoom new recordings** (Zoom panel, on by default): a fresh recording opens with zooms already placed from your clicks and typing, like Screen Studio. Turn it off to start with no zooms.

## Before daily use

Nothing to set up: the Dropbox app is created and its key is built in. Install with the `Install MacShotty.command` script, grant Screen Recording, then Settings → Uploads → Dropbox → Connect.

## Backburner

Not planned yet. Pick from here when something is actually missed in daily use.

**Sharing**
- Floating thumbnail: "Copy image" and "Copy link" buttons after an upload, like CleanShot.
- Upload toast actions: "Open in Dropbox" and "Copy direct link".
- Upload history: the last N Dropbox links in the menu bar menu.
- A separate global hotkey for "Capture → Dropbox", so Enter can stay copy-to-clipboard.
- Offline fallback: if an upload fails, save into the local `~/Dropbox/Share` folder so it syncs later.
- Monthly archive summary in the upstream-review task ("Archive/2026-10 has 43 shots, 1.2 GB").
- Password-protected or view-only (no download) links.
- Ship the share flow as the fork's defaults (Dropbox provider, Enter uploads, direct links).

**From Shottr**
- Color contrast checker (WCAG 2.0 / APCA).
- Average color of a selection, and more color formats (OKLCH).
- On-screen guides for lining things up while measuring.
- Combine any number of captures on one canvas (beyond before/after).
- Pick the before/after pair from the history panel instead of the last two captures.

**Video (vs. Screen Studio)**
- Audio enhance: one-click volume normalize and noise reduction for the mic track.
- Vertical/social export preset: one click to 9:16 with a matching look preset.
- Test first: record a 1–2 minute demo with "Editable pointer" on, apply auto-zoom, export, compare with Screen Studio, and only build the gaps actually felt.

Upstream macshot's Studio video editor already covers most of Screen Studio: recorded pointer with spring smoothing and click effects (`CursorMotion`), auto-zoom from clicks and typing (`AutoZoomPlanner`) with a motion-blurred camera path, frame/background styling, keystroke overlays, webcam bubble, on-device captions, MP4 and GIF export.
