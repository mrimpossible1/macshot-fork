# Fork plan: screenshots first, video as a bonus

This fork adds one thing on top of upstream macshot: every capture can land in a Dropbox `/Share` folder with a share link on the clipboard. This file tracks what is done and what comes next.

## Done in this branch

- **Dropbox uploader** (`macshot/Upload/DropboxUploader.swift`): sign-in with your own Dropbox app (OAuth2 PKCE, no secret in the app), uploads to `/Share` (configurable), never overwrites (`add` + autorename), creates a link. Recordings over 140 MB go up in 32 MB chunks through an upload session.
- **Link options** (Settings → Uploads → Dropbox): public link, team-only link (Dropbox Business), or no link. Optional direct links (`raw=1`) so an image link opens the image itself and previews inline in Slack/iMessage.
- **Enter uploads** (Settings → Uploads): when on, Return after selecting an area uploads and copies the link: one keystroke from capture to shareable URL, like CleanShot Cloud.
- **Video editor upload**: the existing Upload button in the video editor also works with Dropbox.
- **Tests**: `macshotTests/DropboxUploaderTests.swift` covers the request flow with local fixtures (no live Dropbox).
- **Strings**: English only. Other language files carry the English text so the localization tests stay green.

## Before daily use (do these once)

1. **Turn off upstream auto-updates in your build.** The app's Sparkle feed still points at the official macshot appcast, so an update would replace this fork with the official app and drop the Dropbox feature. Easiest: in Xcode, set `SUFeedURL` in `Info.plist` to your fork's own appcast or remove it, and untick automatic update checks in Preferences.
2. **Bundle ID.** The fork still uses `com.sw33tlie.macshot.macshot`. Fine if you replace the official app; change it in the project settings if you want both installed side by side.
3. **Dropbox app** (one time, about 2 minutes): see the PR description.

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

So the plan for video is to **test before building**:

1. Record a 1–2 minute demo with "Editable pointer" on, open it in the editor, apply auto-zoom, export, and compare against the same demo in Screen Studio.
2. Write down the gaps you actually feel (likely candidates: zoom presets you can save, auto-applying your look on stop, export presets for vertical social video).
3. Build only those. Upload to Dropbox already works from the editor.
