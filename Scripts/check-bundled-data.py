#!/usr/bin/env python3
"""Check the bundled ProductCatalog.json and Stores_LocalBootstrap.json as the app reads them.

The app decodes each file as a whole (SKUDataLoader, StoreBootstrap), so one
missing key or wrong type drops every country or every store. This checks the
shapes those decoders require, plus what the app needs to offer a country:
product types it knows (ProductType.swift; it skips others), models for each,
and stores for the country's locale. It reads only local files, prints every
problem and exits 1 if there is one. Scripts/build-notarized-release.sh runs
it before building; run it too after editing either file by hand.

Usage (Python 3.9+, standard library only):
    Scripts/check-bundled-data.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG_FILE = REPO_ROOT / "ReadyForPickup" / "ProductCatalog.json"
STORE_FILE = REPO_ROOT / "ReadyForPickup" / "Stores_LocalBootstrap.json"
PRODUCT_TYPE_FILE = REPO_ROOT / "ReadyForPickup" / "Model" / "ModelTypes" / "ProductType.swift"

# StoreAddress's optional strings (missing or null is fine).
OPTIONAL_ADDRESS_KEYS = ("address1", "address2", "stateName", "stateCode", "postalCode")


def product_types() -> set:
    """ProductType's cases (their raw values are their names)."""
    source = PRODUCT_TYPE_FILE.read_text(encoding="utf-8")
    start = source.find("enum ProductType")
    body = source[source.find("{", start) + 1:] if start >= 0 else ""
    depth, end = 1, 0
    for end, char in enumerate(body):
        depth += {"{": 1, "}": -1}.get(char, 0)
        if depth == 0:
            break
    body = body[:end]
    names = set()
    for match in re.finditer(r"^\s*case\s+(\w+(?:\s*,\s*\w+)*)\s*$", body, re.M):
        names.update(name.strip() for name in match.group(1).split(","))
    return names


def is_string(value, allow_empty: bool = False) -> bool:
    return isinstance(value, str) and (allow_empty or value.strip() != "")


def check_catalog(catalog, known_types: set, problems: list) -> list:
    """The catalog's countries (only those that decode), checked as
    SKUDataLoader's CatalogFile decodes them."""
    if not isinstance(catalog, dict) or not isinstance(catalog.get("countries"), list) \
            or not catalog["countries"]:
        problems.append("ProductCatalog.json: no \"countries\" list")
        return []
    countries, codes = [], set()
    for index, entry in enumerate(catalog["countries"]):
        where = f"ProductCatalog.json countries[{index}]"
        if not isinstance(entry, dict):
            problems.append(f"{where}: not an object")
            continue
        where = f"{where} ({entry.get('code')!r})"
        bad = [key for key in ("code", "name", "locale", "storeHost") if not is_string(entry.get(key))]
        if not is_string(entry.get("storePath"), allow_empty=True):
            bad.append("storePath")
        if bad:
            problems.append(f"{where}: missing or not a string: {', '.join(bad)}")
            continue
        if entry["code"] in codes:
            problems.append(f"{where}: duplicate code")
        codes.add(entry["code"])
        products = entry.get("products")
        if not isinstance(products, dict) or not products:
            problems.append(f"{where}: no \"products\" object with products in it")
            continue
        for ptype, models in products.items():
            if ptype not in known_types:
                problems.append(f"{where}: {ptype!r} is not a ProductType case (the app would skip it)")
            if not isinstance(models, list) or not models:
                problems.append(f"{where} {ptype}: not a list of models, or empty")
                continue
            for position, model in enumerate(models):
                if not isinstance(model, dict) or not is_string(model.get("sku")) \
                        or not is_string(model.get("name")):
                    problems.append(f"{where} {ptype}[{position}]: needs a non-empty string sku and name: "
                                    f"{model!r}")
        countries.append(entry)
    if "US" not in codes:
        problems.append("ProductCatalog.json: no US entry (the default country and first search are in the US)")
    return countries


def check_address(address, where: str, problems: list) -> None:
    if not isinstance(address, dict) or not is_string(address.get("city")):
        problems.append(f"{where}: address needs a non-empty string city")
        return
    for key in OPTIONAL_ADDRESS_KEYS:
        if address.get(key) is not None and not isinstance(address[key], str):
            problems.append(f"{where}: address {key} is not a string")


def check_stores(data, problems: list) -> dict:
    """{locale: store count}, checked as StoreBootstrap decodes the file."""
    if not isinstance(data, dict) or not isinstance(data.get("storeListData"), list):
        problems.append("Stores_LocalBootstrap.json: no \"storeListData\" list")
        return {}
    counts = {}
    for index, country in enumerate(data["storeListData"]):
        where = f"Stores_LocalBootstrap.json storeListData[{index}]"
        if not isinstance(country, dict) or not is_string(country.get("locale")) \
                or not isinstance(country.get("hasStates"), bool):
            problems.append(f"{where}: needs a string locale and a boolean hasStates")
            continue
        locale = country["locale"]
        where = f"Stores_LocalBootstrap.json {locale}"
        if locale in counts:
            problems.append(f"{where}: duplicate locale")
        if country["hasStates"]:
            states = country.get("state")
            if not isinstance(states, list):
                problems.append(f"{where}: hasStates but no \"state\" list")
                continue
            groups = []
            for state in states:
                if not isinstance(state, dict) or not isinstance(state.get("name"), str) \
                        or not isinstance(state.get("store"), list):
                    problems.append(f"{where}: a state needs a string name and a \"store\" list")
                    continue
                groups.append(state["store"])
        elif isinstance(country.get("store"), list):
            groups = [country["store"]]
        else:
            problems.append(f"{where}: no \"store\" list")
            continue
        count = 0
        for stores in groups:
            for store in stores:
                if not isinstance(store, dict):
                    problems.append(f"{where}: a store is not an object")
                    continue
                bad = [key for key in ("id", "name", "telephone", "slug")
                       if not is_string(store.get(key), allow_empty=key in ("telephone", "slug"))]
                if bad:
                    problems.append(f"{where} {store.get('id')!r}: missing or not a string: {', '.join(bad)}")
                    continue
                check_address(store.get("address"), f"{where} {store['id']}", problems)
                count += 1
        counts[locale] = counts.get(locale, 0) + count
    return counts


def load(path: Path, problems: list):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        problems.append(f"{path.name}: can't be read as JSON: {error}")
        return None


def main() -> int:
    problems = []
    known_types = product_types()
    if not known_types:
        problems.append(f"{PRODUCT_TYPE_FILE.name}: no ProductType cases found")
    countries = check_catalog(load(CATALOG_FILE, problems), known_types, problems)
    store_counts = check_stores(load(STORE_FILE, problems), problems)
    for country in countries:
        if not store_counts.get(country["locale"]):
            problems.append(f"{country['code']}: no stores for its locale {country['locale']} "
                            "in Stores_LocalBootstrap.json")
    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1
    skus = sum(len(models) for country in countries for models in country["products"].values())
    print(f"Bundled data OK: {len(countries)} countries, {skus} SKUs; "
          f"{len(store_counts)} store-list locales, {sum(store_counts.values())} stores")
    return 0


if __name__ == "__main__":
    sys.exit(main())
