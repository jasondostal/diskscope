# Packaging DiskScope

DiskScope ships as a **Developer ID–signed, notarized `.app`** in a DMG — *not* the Mac App
Store. (App Sandbox would confine a whole-disk indexer to user-picked folders and defeat the
point. Distribution outside the store is the deliberate choice.)

## TL;DR

```sh
make app        # build + sign + verify dist/DiskScope.app
make dmg        # …and a DMG
make notarize   # …and notarize + staple (needs a Developer ID cert + NOTARY_PROFILE)
make icon       # regenerate Packaging/AppIcon.icns from the OKLCH palette
```

`make app` works **right now** with no setup — it falls back to an **ad-hoc signature**, which
runs on *this* Mac but is not distributable and cannot be notarized. The Developer ID + notarize
path below is what makes a DMG other people can open.

## What's in here

| File | Role |
|------|------|
| `Info.plist` | Bundle metadata. **`CFBundleIdentifier = com.witekdivers.DiskScope`** — see "Bundle identity" below. `CFBundleShortVersionString` (marketing) is hand-edited; `package.sh` stamps `CFBundleVersion` (build number) from the git commit count. |
| `DiskScope.entitlements` | Intentionally empty — not sandboxed, no special entitlements needed. |
| `AppIcon.icns` | App icon (committed). Regenerate with `make icon`. |
| `../Scripts/render-icon.swift` | Draws the 1024px master from the real OKLCH category palette. |
| `../Scripts/make-icon.sh` | master PNG → iconset → `.icns`. |
| `../Scripts/package.sh` | The build/sign/dmg/notarize pipeline. |

Build artifacts (`dist/`, the iconset, `*.dmg`, `icon-1024.png`) are git-ignored.

## Bundle identity (read before changing)

`com.witekdivers.DiskScope` is the **stable identity Full Disk Access is keyed on**. Once you've
granted the app FDA, changing the bundle id silently breaks the grant (TCC sees a "different"
app). Pick it once and leave it. It currently uses the `witekdivers.com` domain you own; if you'd
rather ship under a different reverse-DNS prefix, change it **before** the first FDA grant and
keep it fixed thereafter.

## One-time setup for real distribution

You need an **Apple Developer Program** membership ($99/yr).

### 1. Developer ID Application certificate

Xcode → Settings → Accounts → (your Apple ID) → Manage Certificates → **+** → **Developer ID
Application**. It lands in your login keychain. Confirm:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

`package.sh` auto-detects it. To pin a specific one: `export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"`.

### 2. notarytool credentials (store once in the keychain)

Create an **app-specific password** at <https://account.apple.com> → Sign-In and Security →
App-Specific Passwords. Then:

```sh
xcrun notarytool store-credentials "diskscope-notary" \
  --apple-id "jdostal@witekdivers.com" \
  --team-id "YOURTEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"     # the app-specific password

export NOTARY_PROFILE="diskscope-notary"   # add to your shell profile
```

(`--team-id` is the 10-char Team ID from <https://developer.apple.com/account> → Membership.)

### 3. Ship

```sh
make notarize
```

That signs with hardened runtime + secure timestamp, builds the DMG, submits to Apple
(`notarytool ... --wait`), and staples the ticket so it validates offline. Verify:

```sh
spctl --assess --type open --context context:primary-signature -v dist/DiskScope-1.0.0.dmg
xcrun stapler validate dist/DiskScope-1.0.0.dmg
```

A notarized, stapled DMG opens on any Mac with no Gatekeeper warning.

## Releasing a new version

1. Bump `CFBundleShortVersionString` in `Info.plist` **and** `VERSION` in `Scripts/package.sh`
   (kept in sync by hand; the build number auto-advances with commits).
2. `make notarize`.
3. Upload `dist/DiskScope-<version>.dmg`.
