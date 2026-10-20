#!/usr/bin/env python3
"""Regenerate ReadyForPickup/Stores_LocalBootstrap.json from Apple's store list.

The JSON endpoint the app used to read
(https://www.apple.com/rsp-web/store-list?locale=en_US) returns HTTP 404
since 2026. The public page https://www.apple.com/retail/storelist/ embeds
the same data as Next.js page props (<script id="__NEXT_DATA__">), at
props.pageProps.storeList: one entry per country with `locale`, `hasStates`
and `state` ([{name, store: [...]}]).

This script fetches that page (one request) and rewrites the bundled file
in the shape ReadyForPickup/Model/ModelTypes/StoreBootstrap.swift decodes:

    {"storeListData": [
      {"locale": "en_US", "hasStates": true,
       "state": [{"name": "Alabama", "store": [STORE, ...]}, ...]},
      {"locale": "en_SG", "hasStates": false, "store": [STORE, ...]}]}

    STORE = {"id": "R123", "name": "...", "slug": "...", "telephone": "...",
             "address": {"address1", "address2", "city", "stateName",
                         "stateCode", "postalCode"}}

Keys Apple adds for its own page (__typename, calledLocale, states) are
dropped, missing strings become "" (the app treats "" and a missing value
the same), surrounding whitespace is trimmed, and countries are sorted by
locale, states by name and stores by name. Re-running against an unchanged
list leaves the file byte-identical; real changes show up as small diffs.
The app looks stores up by `locale` (ProductCatalog.json gives each locale's
storefront).

Usage (Python 3.9+, standard library only):
    Scripts/update-store-list.py              # fetch, rewrite, print changes
    Scripts/update-store-list.py --dry-run    # fetch and print changes only
    Scripts/update-store-list.py --cache-dir /tmp/apple-cache
                                              # reuse saved responses

The paced Apple client below (AppleClient) is shared with
Scripts/update-catalog.py: one request at a time, at least 3.5 seconds
apart, a desktop Safari User-Agent, and on HTTP 429/541/503 or a block page
it waits 60 seconds, then 5 minutes, then gives up; after a throttled
response it also leaves twice the gap between later requests.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
STORE_FILE = REPO_ROOT / "ReadyForPickup" / "Stores_LocalBootstrap.json"
STORE_LIST_URL = "https://www.apple.com/retail/storelist/"

USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
              "(KHTML, like Gecko) Version/26.0 Safari/605.1.15")
ALLOWED_HOSTS = {"www.apple.com", "www.apple.com.cn"}
MIN_INTERVAL = 3.5          # seconds between two Apple requests
BACKOFF = (60, 300)         # waits after a throttled response, then give up
ADDRESS_KEYS = ("address1", "address2", "city", "stateName", "stateCode", "postalCode")


# MARK: - Paced Apple client

class AppleError(Exception):
    pass


class Throttled(AppleError):
    pass


class Response:
    def __init__(self, url: str, status: int, headers: dict, body: bytes, cached: bool = False):
        self.url = url
        self.status = status
        self.headers = headers
        self.body = body
        self.cached = cached

    @property
    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")

    def json(self):
        return json.loads(self.body)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None     # surface 3xx as HTTPError so every hop is paced


def _looks_blocked(status: int, body: bytes, expect_json: bool) -> bool:
    """Apple answers rate limiting with 429 or 541, or (via Akamai) an
    "Access Denied" / interstitial page instead of the data."""
    if status in (429, 541, 503):
        return True
    head = body[:4000].decode("utf-8", errors="replace").lower()
    if status == 403 and "access denied" in head:
        return True
    if status == 200 and expect_json:
        try:
            json.loads(body)
        except ValueError:
            return True
    return False


class AppleClient:
    """GETs from www.apple.com / www.apple.com.cn, strictly one at a time.

    With `cache_dir`, every final response (2xx, 3xx, 404) is saved there
    and served from disk on the next run, so an interrupted run resumes
    without repeating requests. Throttled and 5xx responses are never cached.
    Saved responses never expire; `oldest_cached` is the save time of the
    oldest one served.
    After a throttled response every later gap is doubled (up to 4x), and
    `max_requests` stops the run before it sends more than that many.
    """

    def __init__(self, cache_dir: Path | None = None, interval: float = MIN_INTERVAL,
                 max_requests: int | None = None, log=sys.stderr):
        self.cache_dir = Path(cache_dir) if cache_dir else None
        if self.cache_dir:
            self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.interval = max(interval, 3.0)
        self.max_requests = max_requests
        self.slowdown = 1.0
        self.log = log
        self.requests = 0
        self.cache_hits = 0
        self.oldest_cached = None
        # Also wait before the first request, so back-to-back runs stay paced.
        self._last_request = time.monotonic()
        self._opener = urllib.request.build_opener(_NoRedirect())

    def get(self, url: str, referer: str | None = None, expect_json: bool = False,
            follow_redirects: bool = True, min_interval: float = 0.0) -> Response:
        """`min_interval` widens the gap before this request (slow endpoints)."""
        for _ in range(4):
            resp = self._get_once(url, referer, expect_json, min_interval)
            location = resp.headers.get("location")
            if not (follow_redirects and resp.status in (301, 302, 303, 307, 308) and location):
                return resp
            url = urllib.parse.urljoin(url, location)
        raise AppleError(f"too many redirects for {url}")

    def _get_once(self, url: str, referer: str | None, expect_json: bool, min_interval: float) -> Response:
        host = urllib.parse.urlsplit(url).hostname
        if host not in ALLOWED_HOSTS:
            raise AppleError(f"refusing to fetch non-Apple host {host}: {url}")

        key = hashlib.sha256(f"{url}\n{referer or ''}".encode()).hexdigest()[:32]
        cached = self._read_cache(key)
        if cached:
            self.cache_hits += 1
            return cached

        waits = list(BACKOFF)
        while True:
            status, headers, body = self._fetch(url, referer, expect_json, min_interval)
            if not _looks_blocked(status, body, expect_json):
                break
            if not waits:
                raise Throttled(f"still throttled (HTTP {status}) after backing off: {url}")
            wait = waits.pop(0)
            self.slowdown = min(self.slowdown * 2, 4.0)
            print(f"  throttled (HTTP {status}); waiting {wait}s, then {self.slowdown:g}x slower",
                  file=self.log)
            time.sleep(wait)

        resp = Response(url, status, headers, body)
        if status >= 500:
            raise AppleError(f"HTTP {status} from {url}")
        self._write_cache(key, referer, resp)
        return resp

    def _fetch(self, url: str, referer: str | None, expect_json: bool, min_interval: float):
        if self.max_requests is not None and self.requests >= self.max_requests:
            raise AppleError(f"request budget of {self.max_requests} reached before {url}")
        gap = max(self.interval, min_interval) * self.slowdown
        delay = self._last_request + gap - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        headers = {
            "User-Agent": USER_AGENT,
            "Accept": "application/json, text/plain, */*" if expect_json
                      else "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate",
        }
        if referer:
            headers["Referer"] = referer
        request = urllib.request.Request(url, headers=headers)
        self.requests += 1
        try:
            with self._opener.open(request, timeout=30) as raw:
                status, resp_headers, body = raw.status, raw.headers, raw.read()
        except urllib.error.HTTPError as error:
            status, resp_headers, body = error.code, error.headers, error.read()
        except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
            raise AppleError(f"network error for {url}: {error}") from error
        finally:
            self._last_request = time.monotonic()

        encoding = (resp_headers.get("Content-Encoding") or "").lower()
        if encoding == "gzip":
            body = gzip.decompress(body)
        elif encoding == "deflate":
            body = zlib.decompress(body)
        kept = {k.lower(): v for k, v in resp_headers.items()
                if k.lower() in ("location", "content-type")}
        print(f"  [apple #{self.requests}] {status} {url}", file=self.log)
        if self.cache_dir:
            with open(self.cache_dir / "requests.log", "a", encoding="utf-8") as log:
                log.write(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')} {status} {url}\n")
        return status, kept, body

    def _read_cache(self, key: str) -> Response | None:
        if not self.cache_dir:
            return None
        meta_path = self.cache_dir / f"{key}.json"
        if not meta_path.exists():
            return None
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        body = (self.cache_dir / f"{key}.body").read_bytes()
        saved = meta.get("fetchedAt")       # UTC ISO 8601: compares as text
        if saved and (self.oldest_cached is None or saved < self.oldest_cached):
            self.oldest_cached = saved
        return Response(meta["url"], meta["status"], meta["headers"], body, cached=True)

    def _write_cache(self, key: str, referer: str | None, resp: Response) -> None:
        if not self.cache_dir:
            return
        (self.cache_dir / f"{key}.body").write_bytes(resp.body)
        meta = {"url": resp.url, "referer": referer, "status": resp.status, "headers": resp.headers,
                "fetchedAt": datetime.now(timezone.utc).isoformat(timespec="seconds")}
        (self.cache_dir / f"{key}.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")


def next_data(html: str) -> dict:
    """The Next.js page props Apple's newer pages embed."""
    match = re.search(r'<script[^>]*\bid="__NEXT_DATA__"[^>]*>(.*?)</script>', html, re.S)
    if not match:
        raise AppleError("page has no __NEXT_DATA__ script")
    return json.loads(match.group(1))


# MARK: - Store list

def _text(value) -> str:
    return "" if value is None else str(value).strip()


def _sort_key(name: str, fallback: str = ""):
    return (name.casefold(), name, fallback)


def clean_store(raw: dict) -> dict:
    address = raw.get("address") or {}
    store = {
        "id": _text(raw.get("id")),
        "name": _text(raw.get("name")),
        "slug": _text(raw.get("slug")),
        "telephone": _text(raw.get("telephone")),
        "address": {key: _text(address.get(key)) for key in ADDRESS_KEYS},
    }
    if not re.fullmatch(r"R\d+", store["id"]) or not store["name"] or not store["address"]["city"]:
        raise AppleError(f"store without a usable id, name or city: {raw}")
    return store


def clean_country(raw: dict) -> dict:
    locale = _text(raw.get("locale"))
    if not re.fullmatch(r"[a-z]{2}_[A-Z]{2}", locale):
        raise AppleError(f"unexpected locale {locale!r}")
    has_states = bool(raw.get("hasStates"))
    states = raw.get("state")
    if states is None:      # tolerate a flat list, as the old JSON endpoint sent
        states = [{"name": "", "store": raw.get("store") or []}]

    grouped = {}
    for state in states:
        name = _text(state.get("name"))
        stores = grouped.setdefault(name, {})
        for raw_store in state.get("store") or []:
            store = clean_store(raw_store)
            stores[store["id"]] = store
    for name, stores in grouped.items():
        grouped[name] = sorted(stores.values(), key=lambda s: _sort_key(s["name"], s["id"]))

    if has_states:
        state_list = [{"name": name, "store": grouped[name]}
                      for name in sorted(grouped, key=_sort_key) if grouped[name]]
        return {"locale": locale, "hasStates": True, "state": state_list}
    flat = [store for name in sorted(grouped, key=_sort_key) for store in grouped[name]]
    return {"locale": locale, "hasStates": False,
            "store": sorted(flat, key=lambda s: _sort_key(s["name"], s["id"]))}


def build_store_list(page_html: str) -> dict:
    countries = next_data(page_html)["props"]["pageProps"]["storeList"]
    cleaned = [clean_country(country) for country in countries]
    cleaned = [country for country in cleaned if stores_of(country)]
    if len({c["locale"] for c in cleaned}) != len(cleaned):
        raise AppleError("duplicate locale in the store list")
    cleaned.sort(key=lambda c: c["locale"])
    if not any(c["locale"] == "en_US" for c in cleaned):
        raise AppleError("store list has no en_US stores; refusing to write it")
    return {"storeListData": cleaned}


def stores_of(country: dict) -> list:
    if "state" in country:
        return [store for state in country["state"] for store in state["store"]]
    return list(country.get("store") or [])


def serialize(data: dict) -> str:
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def describe_changes(old: dict | None, new: dict, out=sys.stdout) -> None:
    old_by_locale = {c["locale"]: c for c in (old or {}).get("storeListData", [])}
    new_by_locale = {c["locale"]: c for c in new["storeListData"]}
    total_old = total_new = 0
    print(f"{'locale':8} {'old':>5} {'new':>5}  changes", file=out)
    for locale in sorted(set(old_by_locale) | set(new_by_locale)):
        before = {s["id"]: s for s in stores_of(old_by_locale.get(locale, {}))}
        after = {s["id"]: s for s in stores_of(new_by_locale.get(locale, {}))}
        total_old += len(before)
        total_new += len(after)
        added = sorted(set(after) - set(before))
        removed = sorted(set(before) - set(after))
        edited = sorted(i for i in set(before) & set(after) if _comparable(before[i]) != _comparable(after[i]))
        notes = []
        if locale not in old_by_locale:
            notes.append("new locale")
        if locale not in new_by_locale:
            notes.append("locale removed")
        notes += [f"+{len(added)} new"] if added else []
        notes += [f"-{len(removed)} closed"] if removed else []
        notes += [f"{len(edited)} edited"] if edited else []
        print(f"{locale:8} {len(before):5} {len(after):5}  {', '.join(notes)}", file=out)
        for sid in added:
            print(f"           + {sid} {after[sid]['name']} ({after[sid]['address']['city']})", file=out)
        for sid in removed:
            print(f"           - {sid} {before[sid]['name']} ({before[sid]['address'].get('city', '')})", file=out)
    print(f"{'total':8} {total_old:5} {total_new:5}", file=out)


def _comparable(store: dict) -> dict:
    address = store.get("address") or {}
    return {"name": _text(store.get("name")), "slug": _text(store.get("slug")),
            "telephone": _text(store.get("telephone")),
            "address": {key: _text(address.get(key)) for key in ADDRESS_KEYS}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--dry-run", action="store_true", help="print changes without writing the file")
    parser.add_argument("--cache-dir", type=Path, help="save responses here and reuse them on later runs")
    parser.add_argument("--output", type=Path, default=STORE_FILE, help=f"default: {STORE_FILE}")
    args = parser.parse_args()

    client = AppleClient(cache_dir=args.cache_dir)
    page = client.get(STORE_LIST_URL)
    if page.status != 200:
        print(f"error: HTTP {page.status} from {STORE_LIST_URL}", file=sys.stderr)
        return 1
    new = build_store_list(page.text)

    old = None
    if args.output.exists():
        old = json.loads(args.output.read_text(encoding="utf-8"))
    describe_changes(old, new)

    text = serialize(new)
    if args.dry_run:
        print("dry run: file not written")
    elif args.output.exists() and args.output.read_text(encoding="utf-8") == text:
        print(f"{args.output.name} is already up to date")
    else:
        args.output.write_text(text, encoding="utf-8")
        print(f"wrote {args.output}")
    print(f"Apple requests: {client.requests} (cache hits: {client.cache_hits})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
