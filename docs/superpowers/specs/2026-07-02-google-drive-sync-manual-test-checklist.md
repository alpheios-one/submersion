# Google Drive Sync - Manual Device Test Checklist

Run on real hardware per platform: macOS, iPhone or iPad, Android device,
Windows, Linux. All items must pass before Google Drive sync is considered
done (acceptance gate from the 2026-07-02 design spec).

## Console prerequisites (do these first)

Both are Google Cloud console state for project `433819313354`, not code.
Item 1 in particular invalidates item 2 of the device matrix below if
skipped: refresh tokens issued in Testing mode expire after 7 days, so a
cold-launch silent auth that passes today fails a week later.

- [ ] A. OAuth consent screen publishing status is **In production**, not
      Testing (Google Auth Platform > Audience > Publish app). The only
      Drive scope requested is `drive.appdata`, which Google classifies as
      non-sensitive, so publishing needs no verification review and takes
      effect immediately.
- [ ] B. An Android OAuth client exists for the **release / Play App
      Signing** SHA-1, not just the debug SHA-1. Without it, sign-in works
      in debug builds and fails in release ones.

## Device matrix

For each platform:

- [ ] 1. Fresh sign-in from Settings > Cloud Sync (native account sheet on
      iOS/macOS/Android; system browser + return on Windows/Linux). Tile
      shows the account email after connecting.
- [ ] 2. Cold-launch silent auth: force-quit, relaunch, run Sync Now.
      No sign-in prompt, no keychain dialog, sync succeeds.
- [ ] 3. Two-device round-trip: edit a dive on device A, Sync Now on A
      then B; the change appears on B. Repeat in the other direction.
- [ ] 4. Sign out (Advanced > Sign Out): tile deselects, subsequent
      launches show no keychain prompts.
- [ ] 5. Revoke access at myaccount.google.com > Security > Third-party
      access, then Sync Now: a "sign in again" error appears; re-auth
      via the tile recovers and sync works.
- [ ] 6. (Apple platforms) Backend switch iCloud -> Google Drive: the
      departure confirmation appears, the moved-marker lands on iCloud,
      and the per-provider cursor does not read stale (first Drive sync
      is a full first-contact sync, not an incremental continuation).
- [ ] 7. (Windows/Linux) Cancel the browser dialog mid-sign-in: the tile
      stays unselected, no credentials are stored, retrying works.
- [ ] 8. Settings > Media Storage still offers Google Drive and connects,
      on every platform where the Cloud Sync tile is enabled. The media
      store and sync share one Google session and one appDataFolder, so
      the availability gate now hides both together; check they agree.

Cross-platform matrix (any two platforms with different auth paths, e.g.
macOS + Windows): items 1-3 passing proves both OAuth clients land in the
same appDataFolder (same Google Cloud project).
