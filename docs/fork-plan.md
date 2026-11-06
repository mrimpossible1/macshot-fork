# Fork plan: screenshots first, video as a bonus

This fork adds one thing on top of upstream macshot: every capture can land in a Dropbox `/Share` folder with a share link on the clipboard. This file tracks what is done and what comes next.

## Done in this branch

- **Dropbox uploader** (`macshot/Upload/DropboxUploader.swift`): sign-in with your own Dropbox app (OAuth2 PKCE, no secret in the app), uploads to `/Share` (configurable), never overwrites (`add` + autorename), creates a link. Recordings over 140 MB go up in 32 MB chunks through an upload session.
- **Link options** (Settings → Uploads → Dropbox): public link, team-only link (Dropbox Business), or no link. Optional direct links (`raw=1`) so an image link opens the image itself and previews inline in Slack/iMessage.
- **Enter uploads** (Settings → Uploads): when on, Return after selecting an area uploads and copies the link: one keystroke from capture to shareable URL, like CleanShot Cloud.
- **Video editor upload**: the existing Upload button in the video editor also works with Dropbox.
- **Tests**: `macshotTests/DropboxUploaderTests.swift` covers the request flow with local fixtures (no live Dropbox).
- **English only**: the 40 other language folders are removed and the language picker offers only English.
- **No built-in updater**: Sparkle never starts and "Check for Updates..." is gone, so an update can't replace this fork with official macshot. A monthly scheduled Claude task (1st of each month) reviews upstream and opens an `upstream-sync-YYYY-MM` pull request with a plain-language summary of what's worth taking.
- **Video look presets** (video editor → Background panel → Presets): save the whole look (background, frame, pointer, zoom, keystrokes, camera, captions) under a name, apply it to any recording, delete it. Screen Studio has these; upstream only remembers the last look.
- **Auto Zoom new recordings** (Zoom panel, on by default): a fresh recording opens with zooms already placed from your clicks and typing, like Screen Studio. Turn it off to start with no zooms.

## Before daily use (do these once)

1. **Bundle ID.** The fork still uses `com.sw33tlie.macshot.macshot`. Fine if you replace the official app; change it in the project settings if you want both installed side by side.
2. **Dropbox app** (one time, about 2 minutes): see the PR description.

## Screenshot tune-up (next)

Ordered by payoff:

1. **Defaults for the share flow.** Provider = Dropbox, Enter uploads = on, direct links = on for images. Consider shipping these as the fork's defaults.
2. **Readable file names.** Set the filename template (Settings → General) to something like `{date} {app}` so files in `/Share` sort and read well. Supported tokens live in `FilenameFormatter`.
3. **Upload toast actions.** Add "Open in Dropbox" and "Copy direct link" buttons to `UploadToastController` next to the copied link.
4. **Upload history.** Keep the last N Dropbox links in the menu bar menu (imgbb uploads already keep a list in `imgbbUploads`).
5. **Menu bar shortcut for "Capture → Dropbox"** as its own global hotkey, so the normal Enter behavior can stay copy-to-clipboard.
6. **Local fallback when offline.** If the upload fails, save the file into the local `~/Dropbox/Share` folder so Dropbox syncs it later, and copy the path.

## Video (bonus, mostly already there)

Upstream macshot's Studio video editor already covers most of what Screen Studio does, per its own docs:

- Pointer recorded separately, then smoothed with a spring, hidden when idle or typing, with click effects (`CursorMotion`).
- **Auto-zoom** suggestions from clicks and typing that follow the pointer (`AutoZoomPlanner`), plus a camera path with motion blur.
- Frame/background styling, keystroke overlays, webcam bubble, on-device captions, MP4 and GIF export.

This fork adds look presets and auto-zoom on open (above). Remaining Screen Studio gaps worth considering:

- **Audio enhance**: one-click volume normalize and noise reduction for the mic track (Screen Studio has this; macshot only mixes track volumes).
- **Vertical/social export preset**: one click to 9:16 with a matching look preset.

Next, **test before building more**:

1. Record a 1–2 minute demo with "Editable pointer" on, open it in the editor, apply auto-zoom, export, and compare against the same demo in Screen Studio.
2. Write down the gaps you actually feel (likely candidates: zoom presets you can save, auto-applying your look on stop, export presets for vertical social video).
3. Build only those. Upload to Dropbox already works from the editor.
