#!/usr/bin/env python3
"""Forward geocoding for chamber leads, via OpenStreetMap Nominatim.

Registry pages publish addresses, not coordinates, but the emergency card sorts
by distance and the dataset validation requires a latitude and longitude on
every row. Results are cached on disk so re-running the harvester does not
re-query Nominatim for rows that already resolved.

Nominatim's usage policy allows at most one request per second and requires a
identifying user agent. Both are honoured here.
"""

import json
import os
import time
import urllib.parse
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CACHE_PATH = os.path.join(SCRIPT_DIR, ".chamber_geocode_cache.json")

ENDPOINT = "https://nominatim.openstreetmap.org/search"
USER_AGENT = "SubmersionChamberHarvester/1.0 (dive log app; chamber directory)"
MIN_INTERVAL = 1.1


class Geocoder:
    def __init__(self, cache_path=CACHE_PATH):
        self.cache_path = cache_path
        self.cache = {}
        self._last_request = 0.0
        if os.path.exists(cache_path):
            with open(cache_path, encoding="utf-8") as handle:
                self.cache = json.load(handle)

    def save(self):
        with open(self.cache_path, "w", encoding="utf-8") as handle:
            json.dump(self.cache, handle, indent=2, ensure_ascii=False, sort_keys=True)

    def _rate_limit(self):
        elapsed = time.time() - self._last_request
        if elapsed < MIN_INTERVAL:
            time.sleep(MIN_INTERVAL - elapsed)
        self._last_request = time.time()

    def lookup(self, query, country_code):
        """Return (latitude, longitude), or None when nothing matched."""
        key = f"{country_code}|{query}"
        if key in self.cache:
            hit = self.cache[key]
            return (hit["lat"], hit["lon"]) if hit else None

        self._rate_limit()
        params = urllib.parse.urlencode(
            {
                "q": query,
                "countrycodes": country_code.lower(),
                "format": "json",
                "limit": 1,
            }
        )
        request = urllib.request.Request(
            f"{ENDPOINT}?{params}", headers={"User-Agent": USER_AGENT}
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                results = json.load(response)
        except Exception as error:  # noqa: BLE001 - report and carry on
            print(f"  geocode failed for {query!r}: {error}")
            return None

        if not results:
            self.cache[key] = None
            return None

        lat = float(results[0]["lat"])
        lon = float(results[0]["lon"])
        self.cache[key] = {"lat": lat, "lon": lon}
        return (lat, lon)


def geocode_rows(rows, geocoder=None):
    """Fill latitude and longitude on rows that lack them.

    Tries the most specific query first (facility name plus city), then falls
    back to the city alone, which still puts the chamber in the right town for
    distance sorting. Rows that resolve to neither are returned unchanged and
    are dropped later by validation, since a chamber the card cannot place is a
    chamber it cannot rank.
    """
    geocoder = geocoder or Geocoder()
    resolved = 0

    for row in rows:
        if row.get("latitude") is not None and row.get("longitude") is not None:
            continue

        attempts = []
        if row.get("city"):
            attempts.append(f"{row['name']}, {row['city']}")
            attempts.append(row["city"])
        else:
            attempts.append(row["name"])

        for query in attempts:
            point = geocoder.lookup(query, row["country"])
            if point:
                row["latitude"], row["longitude"] = point
                resolved += 1
                break

    geocoder.save()
    print(f"Geocoded {resolved} rows")
    return rows
