# ReadyForPickup

ReadyForPickup — a macOS app that watches Apple Store pickup availability for iPhone and Mac and alerts you when your configuration is ready nearby.

## Download

**[Download ReadyForPickup.dmg](https://github.com/wehbs/ReadyForPickup/releases/latest/download/ReadyForPickup.dmg)** (always the latest version), open it, and drag ReadyForPickup into Applications. Earlier versions and release notes are on the **[Releases page](https://github.com/wehbs/ReadyForPickup/releases)**. Or use the project site: https://wehbs.github.io/ReadyForPickup/

> **Note:** builds from v0.3.1 onward are Developer ID-signed and notarized by Apple, so they open with a normal double-click (earlier builds, e.g. v0.3.0, were unsigned for distribution and needed Privacy & Security -> Open Anyway on first launch).

## About this fork

Forked from worthbak/inventory-checker-app (GPL-3.0)

This is a modernized fork of [worthbak's InventoryWatch](https://github.com/worthbak/inventory-checker-app) (thanks, Worth!). Since the 2023 upstream release it has been updated for macOS 13+, Apple's current pickup API, the current iPhone and Mac lineup in 15 countries, a 2.0-style three-pane interface with multiple saved searches, auto-refresh with throttle backoff, and Pushover phone notifications (bring your own Pushover app token, entered in Settings). It was renamed from InventoryWatch to ReadyForPickup in October 2026 and relaunched as a new app (bundle ID `com.wehbs.ReadyForPickup`), so nothing carries over from InventoryWatch: saved searches, preferences and Pushover keys start fresh.

Licensed under GPL-3.0 — see LICENSE.md.

Project site: https://wehbs.github.io/ReadyForPickup/

## Countries

Each search watches one country's stores. Pick the country in the search's inspector, above the store picker: changing it picks a store there and keeps the search's preferred models and custom SKU only if that country's model list has them too (most part numbers differ by country). **Settings → Default country** sets where new searches start. Searches saved by 0.3.4 and earlier, which all used the app-wide country set in Settings, keep that country.

Supported: the United States, Australia, Austria, Canada, China mainland, France, Germany, India, Italy, Japan, Malaysia, South Korea, Spain, the United Arab Emirates and the United Kingdom. Every model watched in a country was found in that country's own pickup API. Outside the US, iPhone names are Apple's local ones (e.g. Japanese or French); Mac names are the US spec names. Not supported: Hong Kong (its pickup API rejects the store locations the app sends), Macao (no online store), and Apple's other store countries (Belgium, Brazil, Mexico, the Netherlands, Singapore, Sweden, Switzerland, Taiwan, Thailand and Türkiye) until their models are verified.

## Store list and product catalog

The app bundles two data files, each rebuilt by a script (Python 3.9+, standard library only; `--dry-run` prints the changes without writing):

- `InventoryWatch/Stores_LocalBootstrap.json`: every Apple Store, by country. `Scripts/update-store-list.py` rebuilds it from apple.com/retail/storelist in one request.
- `InventoryWatch/ProductCatalog.json`: the countries the app offers and the models it watches in each (part number and name). `Scripts/update-catalog.py` rebuilds every country but the US and checks each part number against that country's pickup API. Apple's pickup API blocks a client for about half an hour after roughly 40-60 calls, so refresh a few countries per run, about an hour apart, all with one new cache directory for that refresh: `Scripts/update-catalog.py --only GB,JP,FR,DE --cache-dir ~/rfp-cache/2026-10-19`. Saved responses never expire, so a cache directory from an earlier refresh replays Apple's data from then. A country already in the file that can't be rebuilt keeps its current entry and the script exits with status 1 (`--drop-failed` removes it instead). The US entry is edited by hand: the script checks it against Apple's live US pages and pickup API and reports drift (new or missing SKUs) but never rewrites it, and the other countries' Macs are derived from it.

Run `update-store-list.py` before every release (stores open and close), and before `update-catalog.py`, which checks models at real stores. Run `update-catalog.py` when Apple's lineup changes (new iPhones each September, new Macs) after updating the US entry, or to add a country (see `COUNTRIES` in the script). A new product line also needs a `ProductType` case and an entry in the script's page tables. After editing either file by hand, run `Scripts/check-bundled-data.py`: the app reads each file as a whole, so one bad value would drop every country or store.

## App icon

The app icon and the project site's logo (`docs/logo.png`) are drawn in code by `Scripts/make-app-icon.swift`: a white paper shopping bag with grey rope handles and a green check, on a blue macOS icon tile. It uses neither Apple's logo nor SF Symbols, which may not appear in app icons. To change the icon, edit the script and run `swift Scripts/make-app-icon.swift`; it rewrites every size in `InventoryWatch/Assets.xcassets/AppIcon.appiconset` and the site logo.

## Auto-updates (Sparkle)

ReadyForPickup uses [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle) (MIT — see `Sparkle-LICENSE.txt`) to check for updates automatically (daily, on by default; toggle in Settings → Software Updates, or use **ReadyForPickup → Check for Updates…**).

- **Update feed:** `https://raw.githubusercontent.com/wehbs/ReadyForPickup/main/appcast.xml` — a file in this repo (on `main`), chosen so releases are version-controlled, reviewable, and don't depend on a separate hosting service. The DMG enclosures it points to are GitHub Release assets.
- **Signing key:** updates are EdDSA-signed. The *private* key lives only in the maintainer's Mac login Keychain (created by Sparkle's `generate_keys`; service `https://sparkle-project.org`, account `ed25519`) — it is never in this repo. Only the public key (`SUPublicEDKey`) is embedded in the app's `Info.plist`.
- **One-time manual update:** v0.3.1 and earlier were built *without* Sparkle, and v0.3.2 was signed without the sandbox entitlements Sparkle's installer needs, so none of them can install updates themselves. Download v0.3.3 (or later) manually once from the Releases page; after that, updates install automatically.

## Releasing

First refresh the bundled data (see [Store list and product catalog](#store-list-and-product-catalog)): run `Scripts/update-store-list.py`, plus `Scripts/update-catalog.py` if Apple's lineup changed, and commit any changes. Read the changes each script prints before committing: a closed store or a removed country shows up there.

Then run `Scripts/build-notarized-release.sh` (see its header). It checks the bundled data (`Scripts/check-bundled-data.py`), builds, signs Sparkle's nested code then the app, makes the DMG, notarizes (`notarytool submit --wait` — this can take hours; the submission ID is printed — if running detached, poll `xcrun notarytool info <id> --key … --key-id … --issuer …` every ~2 min, and on `Accepted` staple/validate and check `spctl` on the mounted app), staples, then generates/signs `appcast.xml` with Sparkle's `generate_appcast` (fails safe if the Sparkle tools are missing). Then, in order:

1. Commit + push the version bump: both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (Sparkle compares the latter). Don't commit `appcast.xml` yet.
2. `gh release create v<VERSION> /tmp/readyforpickup-release/ReadyForPickup-<VERSION>.dmg /tmp/readyforpickup-release/ReadyForPickup.dmg --repo wehbs/ReadyForPickup --target <bump commit SHA> --title "ReadyForPickup <VERSION>" --notes "…"` — **always pass `--repo wehbs/ReadyForPickup`** (`gh` otherwise defaults to the upstream worthbak repo here). Upload both files: Sparkle's feed points at the versioned DMG, and the site and the README link to the version-free `ReadyForPickup.dmg` through `releases/latest/download/ReadyForPickup.dmg`, which always serves the latest release's copy.
3. Verify: the release asset downloads (HTTP 200), its SHA-256 matches the local DMG, and the mounted app passes `spctl -a -vvv` (`accepted source=Notarized Developer ID`). Note the DMG itself may show `spctl` "no usable signature" (it isn't codesigned) — the app inside is what matters.
4. Commit + push the generated `appcast.xml`. This is what makes the update live, so it goes last: pushed earlier, the feed would point at a DMG that doesn't exist yet.
5. Verify the live feed (`https://raw.githubusercontent.com/wehbs/ReadyForPickup/main/appcast.xml`, cached for up to 5 minutes) lists the new version with the right enclosure URL and signature.

Do not delete old releases.
