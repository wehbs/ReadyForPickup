#!/usr/bin/env python3
"""Regenerate ReadyForPickup/ProductCatalog.json, the SKUs the app watches per country.

File format (ProductCatalog.json):

    {"generatedAt": "YYYY-MM-DD",
     "countries": [
       {"code": "US", "name": "United States", "locale": "en_US",
        "storeHost": "www.apple.com", "storePath": "",
        "products": {"<ProductType rawValue>": [{"sku": "MJQ34LL/A",
                                                 "name": "iPhone 18 Pro 256GB Black"}, ...]}},
       ...]}

- code: ISO 3166-1 alpha-2 (GB, not UK). name: English country name.
- locale: the country's key in Stores_LocalBootstrap.json (StoreBootstrap.countryData).
- storeHost/storePath: the storefront the pickup request goes to:
  https://<storeHost>/<storePath>/shop/retail/pickup-message ("/<storePath>" is
  left out when storePath is empty), e.g. "" (US, and China on
  www.apple.com.cn), "ca", "uk", "jp", "befr".
- products: ProductType raw values (ProductType.swift) mapped to the SKUs to
  watch, in display order. A country lists only the products it sells; keys
  follow ProductType.allCases order.
- countries: US first, then by English name. generatedAt only changes when the
  countries do, so re-running against unchanged data leaves the file as is.

Where the data comes from:
- US is golden: the SKUs, names and order the app shipped before this file
  existed (SKUData.swift and iPhoneModelsCurrent-intl.json, US-verified
  2026-10-18; the app has read this file instead since). The script never
  rewrites it; it compares it with the live US buy pages and pickup API and
  reports drift (new or missing SKUs) instead, so edit the US entry by hand
  when the US lineup changes. The first run seeds it with --us-seed.
- iPhones (other countries): every part number in the country's buy pages
  (productSelectionData.products, grouped by familyType), in the order the page
  offers them (its selector sections and their variantOrder). Base part numbers
  differ per country, e.g. MJQ34LL/A (US) vs MJRP4QN/A (UK).
- Macs (other countries): Mac buy pages list a part number only for each model's
  entry configurations (PRECONFIGURED_BTR). Mac base part numbers are global and
  the suffix is regional (MDHA4LL/A in the US is MDHA4B/A in the UK), so the
  country's suffix is read from its MacBook Air page and applied to every US
  standard configuration, in the US order. A Mac whose configurations all fail
  with that suffix gets its own from its buy page (Mac mini and Mac Studio ship
  without a keyboard and use another suffix in some countries). Configurations
  a country does not sell fail verification and are left out.
- Verification: every SKU goes through the country's own pickup-message API in
  the app's request shape (FulfillmentModel.fetchChunk: pl=true, location, then
  parts.0 ... parts.19), with the app's location for a real store from
  Stores_LocalBootstrap.json (postal code, else "City, StateCode-or-StateName").
  A SKU is verified when a returned store lists it in partsAvailability with a
  pickupDisplay the app understands and a storePickupProductTitle.
- Names: iPhones use storePickupProductTitle (non-breaking spaces normalized).
  Mac pickup titles carry only model and color ("Mac mini", "14-inch MacBook
  Pro - Space Black"), so Macs keep the US spec name of the same base part
  number, after checking that the country's titles group those SKUs exactly
  as the US titles do (same model and color).
- A country is included only if its pickup API answers with stores from the
  store list and every iPhone part number on its buy pages verifies. A Mac
  product is left out if an entry configuration from its page fails, or the
  title check fails, or nothing verifies.

Usage (Python 3.9+, standard library only). Apple's pickup API answers HTTP
541 for about half an hour once it has seen roughly 40-60 calls from one
address (in 2026-10 that happened at 30 and 100 seconds per call alike), and
each country needs about 10 pickup calls plus 7 page loads. So refresh a few
countries per run, about an hour apart, all with one new --cache-dir per
refresh:
    Scripts/update-catalog.py --only GB,JP,FR,DE --cache-dir ~/rfp-cache/2026-10-19
    Scripts/update-catalog.py --only CH,NL --cache-dir ~/rfp-cache/2026-10-19 --dry-run \
        --report-json /tmp/catalog-report.json
    Scripts/update-catalog.py --us-seed us.json ...  # first run only: the US entry
The cache makes reruns free (the US check runs once per cache), and a run that
is still throttled after the client's 60-second and 5-minute waits stops
without writing anything; rerun it later with the same --cache-dir. Cached
responses never expire, so a cache directory from an earlier refresh replays
Apple's data from then (the script notes cached responses older than a day).
Run Scripts/update-store-list.py first so verification uses the current stores.

Every run prints what it changes in the file, per country and product (also
with --dry-run). A country already in the file that can't be rebuilt (it
fails verification, or the store list lost its stores) keeps its current
entry, and the script exits with status 1; --drop-failed removes such
countries among those refreshed instead.
"""

from __future__ import annotations

import argparse
import html
import importlib.util
import json
import re
import sys
import unicodedata
import urllib.parse
from collections import Counter
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent
CATALOG_FILE = REPO_ROOT / "ReadyForPickup" / "ProductCatalog.json"
STORE_FILE = REPO_ROOT / "ReadyForPickup" / "Stores_LocalBootstrap.json"


def _load_store_list_tool():
    """The paced Apple client lives in update-store-list.py (shared pacing rules)."""
    sys.dont_write_bytecode = True      # no __pycache__ in Scripts/
    spec = importlib.util.spec_from_file_location("update_store_list", HERE / "update-store-list.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


store_tool = _load_store_list_tool()
AppleError = store_tool.AppleError


class AppleClient(store_tool.AppleClient):
    """The shared paced client, plus the wider gap pickup requests need."""

    def __init__(self, pickup_interval: float, **kwargs):
        super().__init__(**kwargs)
        self.pickup_interval = pickup_interval


# ProductType raw values in ProductType.allCases order.
MAC_TYPES = ["MacBookNeo", "M5MacBookAir13", "M5MacBookAir15", "MacBookPro14", "MacBookPro16",
             "iMac", "MacMini", "MacStudio"]
IPHONE_TYPES = ["iPhone16", "iPhone17", "iPhone17e", "iPhoneAir", "iPhoneDuo", "iPhonePro18",
                "iPhoneProMax18"]
PRODUCT_TYPES = MAC_TYPES + IPHONE_TYPES

# buy-iphone slug -> productSelectionData familyType -> ProductType.
IPHONE_PAGES = {
    "iphone-16": {"iphone16": "iPhone16"},
    "iphone-17": {"iphone17": "iPhone17"},
    "iphone-17e": {"iphone17e": "iPhone17e"},
    "iphone-air": {"iphoneair": "iPhoneAir"},
    "iphone-duo": {"iphoneduo": "iPhoneDuo"},
    "iphone-18-pro": {"iphone18pro": "iPhonePro18", "iphone18promax": "iPhoneProMax18"},
}
# buy-mac slug -> ProductTypes it sells. The US drift check reads all of them;
# other countries read macbook-air for their suffix, plus the page of any Mac
# whose configurations all failed with that suffix.
MAC_PAGES = {
    "macbook-neo": ["MacBookNeo"],
    "macbook-air": ["M5MacBookAir13", "M5MacBookAir15"],
    "macbook-pro": ["MacBookPro14", "MacBookPro16"],
    "imac": ["iMac"],
    "mac-mini": ["MacMini"],
    "mac-studio": ["MacStudio"],
}
SUFFIX_PAGE = "macbook-air"
UNWATCHED_PAGES = {"carrier-offers", "studio-display", "studio-display-xdr"}

# Store-list locale -> ISO code, English name, host, storefront paths as linked
# from apple.com/choose-country-region, English first. Buy pages come from the
# first path that has them (a later path wins if it lists other part numbers);
# pickup uses the first path whose API answers the app's location.
COUNTRIES = {
    "de_AT": ("AT", "Austria", "www.apple.com", ["at"]),
    "de_DE": ("DE", "Germany", "www.apple.com", ["de"]),
    "en_AE": ("AE", "United Arab Emirates", "www.apple.com", ["ae"]),
    "en_AU": ("AU", "Australia", "www.apple.com", ["au"]),
    "en_CA": ("CA", "Canada", "www.apple.com", ["ca"]),
    "en_GB": ("GB", "United Kingdom", "www.apple.com", ["uk"]),
    "en_HK": ("HK", "Hong Kong", "www.apple.com", ["hk/en", "hk"]),
    "en_IN": ("IN", "India", "www.apple.com", ["in"]),
    "en_MO": ("MO", "Macao", "www.apple.com", ["mo"]),
    "en_MY": ("MY", "Malaysia", "www.apple.com", ["my"]),
    "en_SG": ("SG", "Singapore", "www.apple.com", ["sg"]),
    "en_US": ("US", "United States", "www.apple.com", [""]),
    "es_ES": ("ES", "Spain", "www.apple.com", ["es"]),
    "es_MX": ("MX", "Mexico", "www.apple.com", ["mx"]),
    "fr_BE": ("BE", "Belgium", "www.apple.com", ["befr"]),
    "fr_CH": ("CH", "Switzerland", "www.apple.com", ["chfr"]),
    "fr_FR": ("FR", "France", "www.apple.com", ["fr"]),
    "it_IT": ("IT", "Italy", "www.apple.com", ["it"]),
    "ja_JP": ("JP", "Japan", "www.apple.com", ["jp"]),
    "ko_KR": ("KR", "South Korea", "www.apple.com", ["kr"]),
    "nl_NL": ("NL", "Netherlands", "www.apple.com", ["nl"]),
    "pt_BR": ("BR", "Brazil", "www.apple.com", ["br"]),
    "sv_SE": ("SE", "Sweden", "www.apple.com", ["se"]),
    "th_TH": ("TH", "Thailand", "www.apple.com", ["th"]),
    "tr_TR": ("TR", "Türkiye", "www.apple.com", ["tr"]),
    "zh_CN": ("CN", "China mainland", "www.apple.com.cn", [""]),
    "zh_TW": ("TW", "Taiwan", "www.apple.com", ["tw"]),
}

PART_RE = re.compile(r"^([A-Z0-9]{5})([A-Z]{1,3}/A)$")
CHUNK = 20                  # parts per pickup request, as the app sends
PICKUP_INTERVAL = 30.0      # default seconds before each pickup request (pages are not throttled)
LOCATION_ATTEMPTS = 3       # stores to try before giving up on a country
# pickupDisplay values PartAvailability.PickupAvailability accepts ("default" is
# mapped to unavailable by FulfillmentModel.parseStoreResponse).
APP_PICKUP_DISPLAYS = {"available", "unavailable", "ineligible", "default"}
# URLComponents.queryItems leaves these unescaped in names and values.
QUERY_SAFE = "!$'()*+,-./:;?@_~"


def log(message: str = "") -> None:
    print(message, flush=True)


# MARK: - Pages

def storefront_url(host: str, path: str, rest: str) -> str:
    return f"https://{host}/{path + '/' if path else ''}{rest}"


def fetch_page(client: AppleClient, url: str):
    """(html, None) for a 200 page, (None, reason) otherwise. A redirect is
    followed only when it keeps the same path (e.g. a trailing slash);
    otherwise the product is not sold there."""
    resp = client.get(url, follow_redirects=False)
    if resp.status in (301, 302, 303, 307, 308):
        target = urllib.parse.urljoin(url, resp.headers.get("location") or "")
        if urllib.parse.urlsplit(target).path.rstrip("/") != urllib.parse.urlsplit(url).path.rstrip("/"):
            return None, f"redirects to {target}"
        resp = client.get(target, follow_redirects=False)
    if resp.status != 200:
        return None, f"HTTP {resp.status}"
    return resp.text, None


def selection_data(page_html: str) -> dict | None:
    """window.PRODUCT_SELECTION_BOOTSTRAP.productSelectionData (a JSON object
    inside a JS object literal)."""
    start = page_html.find("window.PRODUCT_SELECTION_BOOTSTRAP")
    key = page_html.find("productSelectionData:", start) if start >= 0 else -1
    if key < 0:
        return None
    try:
        data, _ = json.JSONDecoder().raw_decode(page_html, page_html.index("{", key))
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def iphone_parts(data: dict, families: dict):
    """({ProductType: [sku, ...]}, unknown familyTypes) in the page's selector
    order. Carrier variants share a part number; if a country gives one
    configuration several part numbers, the unlocked ones win."""
    dims = [s.get("dimension") for s in data.get("sections") or []
            if s.get("dimension") and s.get("dimension") != "carrierModel"]
    orders = {d: ((data.get("displayValues") or {}).get(d) or {}).get("variantOrder") or [] for d in dims}

    def rank(product):
        return tuple(orders[d].index(product.get(d)) if product.get(d) in orders[d] else len(orders[d])
                     for d in dims)

    by_type, unknown = {}, Counter()
    for product in data.get("products") or []:
        part = product.get("partNumber") or ""
        ptype = families.get(product.get("familyType"))
        if not ptype:
            unknown[product.get("familyType")] += 1
            continue
        if not PART_RE.match(part):
            continue
        config = by_type.setdefault(ptype, {}).setdefault(tuple(product.get(d) for d in dims), {})
        unlocked = product.get("carrierPolicyType") in (None, "UNLOCKED")
        if part not in config:
            config[part] = (product, unlocked)
        elif unlocked:
            config[part] = (config[part][0], True)
    result = {}
    for ptype, configs in by_type.items():
        chosen = []
        for parts in configs.values():
            if any(unlocked for _, unlocked in parts.values()):
                parts = {part: v for part, v in parts.items() if v[1]}
            chosen += [(rank(product), part) for part, (product, _) in parts.items()]
        result[ptype] = [part for _, part in sorted(chosen)]
    return result, dict(unknown)


def mac_entry_parts(data: dict) -> list:
    """Part numbers the Mac page gives (entry configurations only)."""
    parts = []
    for product in data.get("products") or []:
        part = product.get("btrOrFdPartNumber") or ""
        if PART_RE.match(part) and part not in parts:
            parts.append(part)
    return parts


def page_slugs(page_html: str, section: str) -> list:
    return sorted(set(re.findall(rf'href="(?:https://www\.apple\.com)?(?:/[a-z-]+)*/shop/{section}/([a-z0-9-]+)"',
                                 page_html)))


# MARK: - Pickup verification

def app_location(store: dict) -> str:
    """FulfillmentModel.pickupLocation: postal code, else StoreAddress.cityStateDisplay."""
    address = store["address"]
    if address.get("postalCode"):
        return address["postalCode"]
    state = address.get("stateCode") or address.get("stateName") or ""
    return address["city"] + (f", {state}" if state else "")


def pickup_url(host: str, path: str, location: str, parts: list) -> str:
    def quote(value):
        return urllib.parse.quote(value, safe=QUERY_SAFE)
    items = ["pl=true", f"location={quote(location)}"]
    items += [f"parts.{index}={quote(part)}" for index, part in enumerate(parts)]
    return storefront_url(host, path, "shop/retail/pickup-message?" + "&".join(items))


def clean_title(title) -> str:
    """storePickupProductTitle with non-breaking and other Unicode spaces as
    plain spaces, invisible format characters dropped and U+2011 as "-"."""
    if not isinstance(title, str):
        return ""
    chars = []
    for char in html.unescape(title).replace("\u2011", "-"):
        category = unicodedata.category(char)
        if category == "Zs":
            chars.append(" ")
        elif category != "Cf":
            chars.append(char)
    return " ".join("".join(chars).split())


def parse_pickup(resp) -> tuple:
    """Mirrors FulfillmentModel.parseStoreResponse: ([(storeNumber, {part:
    (pickupDisplay, title)})], error or None)."""
    if resp.status != 200:
        return [], f"HTTP {resp.status}"
    try:
        body = resp.json().get("body")
    except (ValueError, AttributeError):
        return [], "response is not JSON"
    if not isinstance(body, dict):
        return [], "no body"
    content = body.get("content") if isinstance(body.get("content"), dict) else {}
    stores = body.get("stores")
    if not isinstance(stores, list):
        stores = (content.get("pickupMessage") or {}).get("stores")
    if not isinstance(stores, list) or not stores:
        message = body.get("errorMessage") or content.get("errorMessage") or "no error message"
        return [], f"no stores ({message})"
    parsed = []
    for store in stores:
        if not all(isinstance(store.get(key), str) for key in ("storeName", "storeNumber", "city")):
            continue
        availability = store.get("partsAvailability")
        if not isinstance(availability, dict):
            continue
        parts = {}
        for part in availability.values():
            if not isinstance(part, dict):
                continue
            number, display = part.get("partNumber"), part.get("pickupDisplay")
            if not isinstance(number, str) or display not in APP_PICKUP_DISPLAYS:
                continue
            regular = (part.get("messageTypes") or {}).get("regular") or {}
            parts[number] = (display, clean_title(regular.get("storePickupProductTitle")))
        parsed.append((store["storeNumber"], parts))
    return parsed, None if parsed else "no store the app can parse"


def verify(client: AppleClient, host: str, path: str, stores: list, skus: list,
           known_location: dict | None = None) -> dict:
    """Checks every SKU through the storefront's pickup API, 20 per request,
    from the first store whose location returns stores (or from
    `known_location`, one that already did)."""
    referer = storefront_url(host, path, "shop/buy-iphone/")
    if known_location:
        locations = [(known_location["store"], known_location["location"])]
    else:
        locations = []
        for store in stores:
            if app_location(store) not in [loc for _, loc in locations]:
                locations.append((store["id"], app_location(store)))
    known = {store["id"] for store in stores}
    result = {"titles": {}, "displays": Counter(), "requests": 0, "errors": [], "location": known_location,
              "storesReturned": [], "storesKnown": 0, "titleConflicts": []}
    attempt = 0
    for start in range(0, len(skus), CHUNK):
        chunk = skus[start:start + CHUNK]
        while True:
            if attempt >= min(LOCATION_ATTEMPTS, len(locations)):
                result["errors"].append("no store location returned stores")
                return result
            store_id, location = locations[attempt]
            resp = client.get(pickup_url(host, path, location, chunk), referer=referer,
                              expect_json=True, follow_redirects=False, min_interval=client.pickup_interval)
            result["requests"] += 1
            parsed, error = parse_pickup(resp)
            if parsed or result["location"]:
                break
            result["errors"].append(f"{store_id} location {location!r}: {error}")
            if resp.status in (403, 404):
                return result       # no pickup API on this storefront at all
            # Nothing has worked yet: this location may be the problem.
            attempt += 1
        if not parsed:
            result["errors"].append(f"parts {start}-{start + len(chunk) - 1}: {error}")
            continue
        result["location"] = result["location"] or {"store": store_id, "location": location}
        for number, parts in parsed:
            if number not in result["storesReturned"]:
                result["storesReturned"].append(number)
            for sku in chunk:
                if sku in parts and parts[sku][1]:
                    display, title = parts[sku]
                    if sku not in result["titles"]:
                        result["titles"][sku] = title
                        result["displays"][display] += 1
                    elif result["titles"][sku] != title:
                        result["titleConflicts"].append((sku, result["titles"][sku], title))
    result["storesKnown"] = sum(1 for number in result["storesReturned"] if number in known)
    return result


# MARK: - Countries

def us_mac_bases(us_entry: dict) -> dict:
    """{ProductType: [(base, US sku, US name)]} for the golden US Macs."""
    bases = {}
    for ptype in MAC_TYPES:
        for item in us_entry["products"].get(ptype, []):
            match = PART_RE.match(item["sku"])
            if match:
                bases.setdefault(ptype, []).append((match.group(1), item["sku"], item["name"]))
    return bases


def check_us(client: AppleClient, us_entry: dict, stores: list) -> dict:
    """Drift between the golden US data and Apple's live US pages and pickup API."""
    report = {"pages": {}, "newPages": [], "new": {}, "missingFromPages": {}, "notVerified": [],
              "pickup": None}
    golden = {ptype: [item["sku"] for item in us_entry["products"].get(ptype, [])] for ptype in PRODUCT_TYPES}
    all_golden = {sku for skus in golden.values() for sku in skus}

    for section, known in (("buy-iphone", set(IPHONE_PAGES)), ("buy-mac", set(MAC_PAGES))):
        page, error = fetch_page(client, storefront_url("www.apple.com", "", f"shop/{section}"))
        if page:
            report["newPages"] += [f"{section}/{slug}" for slug in page_slugs(page, section)
                                   if slug not in known and slug not in UNWATCHED_PAGES]
        else:
            report["pages"][section] = error

    for slug, families in IPHONE_PAGES.items():
        page, error = fetch_page(client, storefront_url("www.apple.com", "", f"shop/buy-iphone/{slug}"))
        data = selection_data(page) if page else None
        if not data:
            report["pages"][slug] = error or "no productSelectionData"
            continue
        found, unknown = iphone_parts(data, families)
        report["pages"][slug] = {ptype: len(skus) for ptype, skus in found.items()}
        if unknown:
            report["pages"][slug]["otherFamilies"] = unknown
        for ptype in families.values():
            live = found.get(ptype, [])
            new = [sku for sku in live if sku not in golden[ptype]]
            missing = [sku for sku in golden[ptype] if sku not in live]
            if new:
                report["new"][ptype] = new
            if missing:
                report["missingFromPages"][ptype] = missing

    for slug in MAC_PAGES:
        page, error = fetch_page(client, storefront_url("www.apple.com", "", f"shop/buy-mac/{slug}"))
        data = selection_data(page) if page else None
        if not data:
            report["pages"][slug] = error or "no productSelectionData"
            continue
        parts = mac_entry_parts(data)
        report["pages"][slug] = {"entryConfigs": len(parts)}
        new = [sku for sku in parts if sku not in all_golden]
        if new:
            report["new"][slug] = new

    ordered = [sku for ptype in PRODUCT_TYPES for sku in golden[ptype]]
    result = verify(client, "www.apple.com", "", stores, ordered)
    report["pickup"] = summarize_pickup(result)
    report["notVerified"] = [sku for sku in ordered if sku not in result["titles"]]
    report["titles"] = result["titles"]
    return report


def summarize_pickup(result: dict) -> dict:
    return {"location": result["location"], "requests": result["requests"], "errors": result["errors"],
            "storesReturned": len(result["storesReturned"]), "storesInStoreList": result["storesKnown"],
            "verified": len(result["titles"]), "pickupDisplay": dict(result["displays"]),
            "titleConflicts": result["titleConflicts"]}


def build_country(client: AppleClient, locale: str, stores: list, us_entry: dict, us_titles: dict) -> tuple:
    """(catalog entry or None, report) for one non-US country."""
    code, name, host, paths = COUNTRIES[locale]
    report = {"code": code, "name": name, "locale": locale, "storeHost": host, "pages": {},
              "products": {}, "excluded": [], "notes": []}
    if not stores:
        report["reason"] = "no stores in Stores_LocalBootstrap.json"
        return None, report

    # Buy pages: from the first storefront path that has them; a later
    # (local-language) path wins if it lists other part numbers.
    tried = {p: fetch_page(client, storefront_url(host, p, "shop/buy-iphone/iphone-18-pro")) for p in paths}
    path = next((p for p in paths if tried[p][0]), paths[0])
    for other in paths:
        if other == path:
            continue
        if not tried[other][0]:
            report["notes"].append(f"/{other}/ has no iPhone 18 Pro page ({tried[other][1]})")
        elif page_part_sets(tried[other][0]) == page_part_sets(tried[path][0]):
            report["notes"].append(f"/{path}/ and /{other}/ list the same iPhone 18 Pro part numbers")
        elif paths.index(other) > paths.index(path):
            report["notes"].append(f"/{other}/ lists other part numbers than /{path}/; using /{other}/")
            path = other
    pages = {"iphone-18-pro": tried[path]}
    report["pagePath"] = path

    # iPhones: all part numbers from the buy pages.
    iphones = {}
    for slug, families in IPHONE_PAGES.items():
        if slug not in pages:
            pages[slug] = fetch_page(client, storefront_url(host, path, f"shop/buy-iphone/{slug}"))
        page, error = pages[slug]
        data = selection_data(page) if page else None
        if not data:
            report["pages"][slug] = error or "no productSelectionData"
            continue
        found, unknown = iphone_parts(data, families)
        report["pages"][slug] = {ptype: len(skus) for ptype, skus in found.items()} or "no known families"
        if unknown:
            report["notes"].append(f"{slug}: other families {unknown}")
        iphones.update(found)
    if not iphones:
        report["reason"] = "no iPhone buy pages with part numbers"
        return None, report

    # Macs: the country's suffix from its MacBook Air entry configurations.
    us_bases = us_mac_bases(us_entry)
    suffix, entry_parts = mac_page_suffix(client, host, path, SUFFIX_PAGE, report)
    macs, type_suffix = {}, {}
    if suffix:
        for ptype, items in us_bases.items():
            macs[ptype] = [base + suffix for base, _, _ in items]
            type_suffix[ptype] = suffix
    report["macSuffix"] = suffix

    # Pickup: the first storefront path (English first) whose API answers the
    # app's location with stores.
    ordered = [sku for ptype in IPHONE_TYPES for sku in iphones.get(ptype, [])]
    ordered += [sku for ptype in MAC_TYPES for sku in macs.get(ptype, [])]
    for pickup_path in paths:
        result = verify(client, host, pickup_path, stores, ordered)
        if result["location"]:
            break
        if len(paths) > 1:
            report["notes"].append(f"/{pickup_path}/ pickup API: " + "; ".join(result["errors"]))
    report["storePath"] = pickup_path
    report["pickup"] = summarize_pickup(result)
    report["titles"] = titles = result["titles"]

    if not result["location"]:
        report["reason"] = "pickup API returned no stores: " + "; ".join(result["errors"])
        return None, report
    if result["storesKnown"] == 0:
        report["reason"] = "pickup API returned no store from the store list"
        return None, report

    # A Mac with no verified configuration may use another suffix (Mac mini and
    # Mac Studio ship without a keyboard): read it from that product's page.
    retry = []
    for slug, ptypes in MAC_PAGES.items():
        failed = [p for p in ptypes if macs.get(p) and not any(sku in titles for sku in macs[p])]
        if not failed or slug == SUFFIX_PAGE:
            continue
        page_suffix, parts = mac_page_suffix(client, host, path, slug, report)
        entry_parts = entry_parts + [part for part in parts if part not in entry_parts]
        if page_suffix and page_suffix != suffix:
            for ptype in failed:
                macs[ptype] = [base + page_suffix for base, _, _ in us_bases[ptype]]
                type_suffix[ptype] = page_suffix
                retry += macs[ptype]
    if retry:
        second = verify(client, host, pickup_path, stores, retry, known_location=result["location"])
        report["pickupRetry"] = summarize_pickup(second)
        titles.update(second["titles"])
    report["macSuffixes"] = {p: s for p, s in type_suffix.items() if s != suffix}
    derived = {sku for skus in macs.values() for sku in skus}
    unmatched = [part for part in entry_parts if part not in derived]
    if unmatched:
        report["notes"].append(f"Mac entry configs that are not a US configuration (not included): {unmatched}")

    products = {}
    iphone_failures = []
    for ptype in IPHONE_TYPES:
        skus = iphones.get(ptype)
        if not skus:
            continue
        missing = [sku for sku in skus if sku not in titles]
        names = [titles.get(sku, "") for sku in skus]
        duplicates = sorted(n for n, count in Counter(names).items() if n and count > 1)
        report["products"][ptype] = {"skus": len(skus), "verified": len(skus) - len(missing)}
        if missing or duplicates:
            iphone_failures.append(ptype)
            report["excluded"].append({"product": ptype, "unverified": missing, "duplicateNames": duplicates})
            continue
        products[ptype] = [{"sku": sku, "name": titles[sku]} for sku in skus]

    entry_set = set(entry_parts)
    for ptype in MAC_TYPES:
        candidates = macs.get(ptype)
        if not candidates:
            continue
        ending = type_suffix[ptype]
        us_sku = {base + ending: sku for base, sku, _ in us_bases[ptype]}
        verified = [sku for sku in candidates if sku in titles]
        report["products"][ptype] = {"skus": len(candidates), "verified": len(verified)}
        failed_entries = [sku for sku in candidates if sku in entry_set and sku not in titles]
        if failed_entries:
            report["excluded"].append({"product": ptype, "unverifiedEntryConfigs": failed_entries})
            continue
        # A configuration the US pickup API no longer knows has no reference title.
        no_reference = [sku for sku in verified if us_sku[sku] not in us_titles]
        if no_reference:
            report["notes"].append(f"{ptype}: left out {no_reference}, their US SKUs did not verify")
            verified = [sku for sku in verified if sku not in no_reference]
        if not verified:
            report["excluded"].append({"product": ptype, "reason": f"no US configuration verified with {ending}"})
            continue
        mismatch = mac_title_mismatch(verified, titles, us_titles, us_sku)
        if mismatch:
            report["excluded"].append({"product": ptype, "titleMismatch": mismatch})
            continue
        names = {base + ending: us_name for base, _, us_name in us_bases[ptype]}
        products[ptype] = [{"sku": sku, "name": names[sku]} for sku in verified]

    if iphone_failures:
        report["reason"] = "iPhone products did not fully verify: " + ", ".join(iphone_failures)
        return None, report
    report["included"] = {ptype: len(items) for ptype, items in products.items()}
    entry = {"code": code, "name": name, "locale": locale, "storeHost": host, "storePath": pickup_path,
             "products": {ptype: products[ptype] for ptype in PRODUCT_TYPES if ptype in products}}
    return entry, report


def mac_page_suffix(client: AppleClient, host: str, path: str, slug: str, report: dict) -> tuple:
    """(most common regional suffix, entry part numbers) of one Mac buy page."""
    page, error = fetch_page(client, storefront_url(host, path, f"shop/buy-mac/{slug}"))
    data = selection_data(page) if page else None
    if not data:
        report["pages"][slug] = error or "no productSelectionData"
        return None, []
    parts = mac_entry_parts(data)
    suffixes = Counter(PART_RE.match(part).group(2) for part in parts)
    report["pages"][slug] = {"entryConfigs": parts, "suffixes": dict(suffixes)}
    return (suffixes.most_common(1)[0][0] if suffixes else None), parts


def title_key(title: str) -> str:
    """For comparing titles only: Apple mixes "-" and "\u2013" (and spacing)
    between titles of the same model, e.g. '14" MacBook Pro - Space Schwarz'."""
    key = re.sub("[\u2010-\u2015\u2212-]", "-", title.casefold())
    return " ".join(re.sub(r"\s*-\s*", " - ", key).split())


def mac_title_mismatch(verified: list, titles: dict, us_titles: dict, us_sku: dict):
    """The country's pickup titles must split the SKUs into the same groups
    (model and color) as the US titles of the same base part numbers."""
    forward, backward = {}, {}
    for sku in verified:
        us_title, local = title_key(us_titles[us_sku[sku]]), title_key(titles[sku])
        forward.setdefault(us_title, set()).add(local)
        backward.setdefault(local, set()).add(us_title)
    bad = {k: sorted(v) for k, v in forward.items() if len(v) > 1}
    bad.update({k: sorted(v) for k, v in backward.items() if len(v) > 1})
    return bad or None


def page_part_sets(page_html: str | None):
    data = selection_data(page_html) if page_html else None
    if not data:
        return None
    found, _ = iphone_parts(data, IPHONE_PAGES["iphone-18-pro"])
    return {ptype: set(skus) for ptype, skus in found.items()} or None


# MARK: - Catalog file

def load_stores() -> dict:
    data = json.loads(STORE_FILE.read_text(encoding="utf-8"))
    by_locale = {}
    for country in data["storeListData"]:
        if country.get("hasStates"):
            by_locale[country["locale"]] = [s for state in country["state"] for s in state["store"]]
        else:
            by_locale[country["locale"]] = list(country["store"])
    return by_locale


def validate_us(entry: dict) -> dict:
    if entry.get("code") != "US" or entry.get("locale") != "en_US" or entry.get("storePath") != "":
        raise SystemExit("error: the US seed must be the en_US entry with storePath \"\"")
    unknown = set(entry.get("products", {})) - set(PRODUCT_TYPES)
    if unknown:
        raise SystemExit(f"error: unknown product types in the US entry: {sorted(unknown)}")
    return entry


def serialize(catalog: dict) -> str:
    """Stable, review-friendly JSON: one line per SKU."""
    def dumps(value):
        return json.dumps(value, ensure_ascii=False)
    lines = ["{", f'  "generatedAt": {dumps(catalog["generatedAt"])},', '  "countries": [']
    countries = catalog["countries"]
    for ci, country in enumerate(countries):
        lines.append("    {")
        for key in ("code", "name", "locale", "storeHost", "storePath"):
            lines.append(f'      "{key}": {dumps(country[key])},')
        lines.append('      "products": {')
        products = list(country["products"].items())
        for pi, (ptype, items) in enumerate(products):
            lines.append(f"        {dumps(ptype)}: [")
            for ii, item in enumerate(items):
                comma = "," if ii < len(items) - 1 else ""
                lines.append(f'          {{"sku": {dumps(item["sku"])}, "name": {dumps(item["name"])}}}{comma}')
            lines.append("        ]" + ("," if pi < len(products) - 1 else ""))
        lines.append("      }")
        lines.append("    }" + ("," if ci < len(countries) - 1 else ""))
    lines += ["  ]", "}"]
    text = "\n".join(lines) + "\n"
    if json.loads(text) != catalog:
        raise AssertionError("serializer round trip failed")
    return text


def sort_countries(countries: list) -> list:
    us = [c for c in countries if c["code"] == "US"]
    rest = sorted((c for c in countries if c["code"] != "US"), key=lambda c: (c["name"].casefold(), c["code"]))
    return us + rest


def describe_changes(old: dict | None, countries: list) -> list:
    """One line per country that `countries` changes in the current file."""
    def models(country: dict, ptype: str) -> dict:
        return {item["sku"]: item["name"] for item in country.get("products", {}).get(ptype, [])}

    before = {c["code"]: c for c in (old or {}).get("countries", [])}
    after = {c["code"]: c for c in countries}
    lines = []
    for code in sorted(set(before) | set(after)):
        if code not in after:
            lines.append(f"{code}: REMOVED")
            continue
        if code not in before:
            lines.append(f"{code}: added, {sum(len(items) for items in after[code]['products'].values())} SKUs")
            continue
        notes = [f"{key} {before[code].get(key)!r} -> {after[code][key]!r}"
                 for key in ("name", "locale", "storeHost", "storePath")
                 if before[code].get(key) != after[code][key]]
        ptypes = set(before[code].get("products", {})) | set(after[code]["products"])
        known = [p for p in PRODUCT_TYPES if p in ptypes]
        for ptype in known + sorted(ptypes - set(known)):
            was, now = models(before[code], ptype), models(after[code], ptype)
            if not now or not was:
                notes.append(f"{ptype} {'removed' if was else 'added'} ({len(was or now)} SKUs)")
                continue
            added = [sku for sku in now if sku not in was]
            removed = [sku for sku in was if sku not in now]
            renamed = [sku for sku in now if sku in was and was[sku] != now[sku]]
            change = [f"+{len(added)} {added}"] if added else []
            change += [f"-{len(removed)} {removed}"] if removed else []
            change += [f"{len(renamed)} renamed"] if renamed else []
            if not change and list(was) != list(now):
                change.append("reordered")
            if change:
                notes.append(f"{ptype} " + ", ".join(change))
        if notes:
            lines.append(f"{code}: " + "; ".join(notes))
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--cache-dir", type=Path, help="save Apple responses here and reuse them on later runs")
    parser.add_argument("--only", help="comma-separated country codes to refresh; others are kept as they are")
    parser.add_argument("--us-seed", type=Path, help="JSON file with the golden US entry (first run only)")
    parser.add_argument("--dry-run", action="store_true", help="verify and report without writing the file")
    parser.add_argument("--report-json", type=Path, help="also write the full verification report here")
    parser.add_argument("--output", type=Path, default=CATALOG_FILE, help=f"default: {CATALOG_FILE}")
    parser.add_argument("--max-requests", type=int, default=600,
                        help="stop (writing nothing) before sending more Apple requests than this (default 600)")
    parser.add_argument("--pickup-interval", type=float, default=PICKUP_INTERVAL,
                        help=f"seconds between pickup requests (default {PICKUP_INTERVAL:g})")
    parser.add_argument("--drop-failed", action="store_true",
                        help="remove a country already in the file that is refreshed (see --only) but can't be "
                             "rebuilt; by default it keeps its current entry and the script exits with status 1")
    args = parser.parse_args()

    old = json.loads(args.output.read_text(encoding="utf-8")) if args.output.exists() else None
    if args.us_seed:
        us_entry = validate_us(json.loads(args.us_seed.read_text(encoding="utf-8")))
    elif old:
        us_entry = validate_us(next(c for c in old["countries"] if c["code"] == "US"))
    else:
        raise SystemExit(f"error: {args.output.name} does not exist yet; pass --us-seed")
    old_entries = {c["code"]: c for c in (old or {}).get("countries", []) if c["code"] != "US"}
    only = {code.strip().upper() for code in args.only.split(",")} if args.only else None

    stores = load_stores()
    unknown = sorted(set(stores) - set(COUNTRIES))
    client = AppleClient(args.pickup_interval, cache_dir=args.cache_dir, max_requests=args.max_requests)
    report = {"date": date.today().isoformat(), "unknownLocales": unknown, "countries": {}}

    try:
        page, error = fetch_page(client, "https://www.apple.com/choose-country-region/")
        if page:
            links = set(re.findall(r'href="(/[a-z-]+/(?:[a-z]+/)?|https://www\.apple\.com\.cn/)"', page))
            report["storefrontsNotListed"] = [
                f"{locale} /{paths[0]}/" for locale, (_, _, _, paths) in sorted(COUNTRIES.items())
                if paths[0] and f"/{paths[0]}/" not in links]
        log("US: comparing the golden data with Apple's live US pages and pickup API")
        us_report = check_us(client, us_entry, stores.get("en_US", []))
        report["us"] = us_report

        entries = [us_entry]
        kept = []           # countries in the file that failed and kept their entry

        def keep_or_drop(code: str, problem: str, may_drop: bool = True) -> None:
            if args.drop_failed and may_drop:
                log(f"   {code} {problem}: removing it from {args.output.name} (--drop-failed)")
                return
            log(f"   WARNING: {code} {problem}: keeping its current entry in {args.output.name}")
            entries.append(old_entries[code])
            kept.append(code)

        for locale in sorted(stores):
            if locale == "en_US" or locale not in COUNTRIES:
                continue
            code = COUNTRIES[locale][0]
            if only is not None and code not in only:
                if code in old_entries:
                    entries.append(old_entries[code])
                continue
            log(f"{code}: {COUNTRIES[locale][1]}")
            entry, country_report = build_country(client, locale, stores[locale], us_entry, us_report["titles"])
            report["countries"][code] = country_report
            status = "included" if entry else f"EXCLUDED: {country_report.get('reason')}"
            log(f"   {status}; {sum(len(v) for v in (entry or {}).get('products', {}).values())} SKUs")
            for item in country_report["excluded"]:
                log(f"   left out: {item}")
            if entry:
                entries.append(entry)
            elif code in old_entries:
                keep_or_drop(code, "failed")
        # Countries in the file whose locale the loop didn't reach.
        for code in sorted(set(old_entries) - set(report["countries"]) - {entry["code"] for entry in entries}):
            locale = old_entries[code]["locale"]
            log(f"{code}: {old_entries[code]['name']}")
            keep_or_drop(code, f"has no COUNTRIES entry for {locale}" if locale in stores
                         else f"has no stores for {locale} in {STORE_FILE.name}",
                         may_drop=only is None or code in only)
    except AppleError as error:
        print(f"error: {error}. Nothing was written; re-run later with the same --cache-dir.", file=sys.stderr)
        return 2
    finally:
        print(f"Apple requests: {client.requests} (cache hits: {client.cache_hits})", file=sys.stderr)
        report["appleRequests"] = client.requests

    countries = sort_countries(entries)
    generated = date.today().isoformat()
    if old and old.get("countries") == countries:
        generated = old.get("generatedAt", generated)
    catalog = {"generatedAt": generated, "countries": countries}
    text = serialize(catalog)

    if client.oldest_cached:
        saved = datetime.fromisoformat(client.oldest_cached)
        if datetime.now(timezone.utc) - saved > timedelta(days=1):
            log(f"note: this run used responses saved in --cache-dir as long ago as {saved.date().isoformat()}; "
                "they never expire. Use a new cache directory to check Apple's current data.")
    us = report["us"]
    log(f"US drift: new {us['new'] or 'none'}; missing from pages {us['missingFromPages'] or 'none'}; "
        f"not verified by pickup {us['notVerified'] or 'none'}; new pages {us['newPages'] or 'none'}")
    log(f"Included: {', '.join(c['code'] for c in countries)}")
    changes = describe_changes(old, countries)
    log(f"Changes to {args.output.name}:" + ("" if changes else " none"))
    for line in changes:
        log(f"   {line}")
    if unknown:
        log(f"Store-list locales without a COUNTRIES entry (add them): {', '.join(unknown)}")
    if args.report_json:
        args.report_json.write_text(json.dumps(report, indent=1, ensure_ascii=False, default=list) + "\n",
                                    encoding="utf-8")
    if args.dry_run:
        log("dry run: file not written")
    elif args.output.exists() and args.output.read_text(encoding="utf-8") == text:
        log(f"{args.output.name} is already up to date")
    else:
        args.output.write_text(text, encoding="utf-8")
        log(f"wrote {args.output}")
    if kept:
        print(f"error: kept the current entries of {', '.join(kept)} in {args.output.name}, which could not be "
              "rebuilt (see the warnings above). Fix the cause and rerun, or remove them with --only and "
              "--drop-failed.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
