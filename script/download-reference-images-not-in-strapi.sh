#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFERENCE_DIR="${REFERENCE_DIR:-$ROOT_DIR/reference}"
RAW_IMAGE_DIR="${RAW_IMAGE_DIR:-$ROOT_DIR/raw-image}"
REFERENCE_CSV="${REFERENCE_CSV:-$REFERENCE_DIR/[Template] Venue Offices - sewakantorcbd Apr 9.csv}"
EXISTING_FILENAMES="${EXISTING_FILENAMES:-$REFERENCE_DIR/strapi-office-venue-existing-filenames.txt}"
PRIORITY_ONLY="${PRIORITY_ONLY:-1}"
DRY_RUN="${DRY_RUN:-0}"

export REFERENCE_CSV EXISTING_FILENAMES RAW_IMAGE_DIR PRIORITY_ONLY DRY_RUN

python3 <<'PY'
import ast
import csv
import json
import os
import posixpath
import sys
import urllib.parse
import urllib.request
from collections import defaultdict

PRIORITY_BUILDINGS = """Centennial Tower
Menara Jamsostek - North Tower
Menara Jamsostek - South Tower
Atrium Setiabudi
Gedung Setiabudi 2
Graha Arda
Menara Sun Life (Ex. Menara Prima II)
RDTX Square (Ex Menara Standard Chartered)
Intiland Tower
Plaza Sentral
Sona Topas Tower
Wisma GKBI
Plaza Bank Index (Ex Plaza Permata)
Gedung Graha Kencana
Wisma Slipi
Alamanda Tower
South Quarter Tower A
Wisma Kemang
Graha Rekso
Kirana Two
Soho Capital
Millenium Centennial Center
Sainath Tower
Menara Kompas
Intirub Business Park
KEM Tower
UOB Plaza
Midpoint Place
Park Tower
Plaza Timor
Trio Building
Graha Dirgantara""".splitlines()

PHOTO_COLUMNS = ("photosExterior", "photosInterior", "photosFloorPlan")
CATEGORY_DIR = {
    "photosExterior": "exterior",
    "photosInterior": "interior",
    "photosFloorPlan": "floorplan",
}
REFERENCE_CSV = os.environ["REFERENCE_CSV"]
EXISTING_FILENAMES = os.environ["EXISTING_FILENAMES"]
RAW_IMAGE_DIR = os.environ["RAW_IMAGE_DIR"]
PRIORITY_ONLY = os.environ.get("PRIORITY_ONLY", "1") == "1"
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"


def parse_photo_list(raw):
    text = str(raw or "").strip()
    if not text:
        return []
    if text.isdigit():
        return [text]
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        try:
            data = ast.literal_eval(text)
        except (ValueError, SyntaxError):
            return []
    if isinstance(data, dict):
        photos = data.get("photos", [])
        return photos if isinstance(photos, list) else []
    if isinstance(data, list):
        return data
    return []


def image_key(value):
    parsed = urllib.parse.urlparse(str(value or ""))
    path = parsed.path or str(value or "")
    return urllib.parse.unquote(posixpath.basename(path)).strip()


def load_existing(path):
    with open(path, encoding="utf-8-sig") as input_file:
        return {line.strip().lower() for line in input_file if line.strip()}


def collect_items():
    priority_order = {name.lower(): index for index, name in enumerate(PRIORITY_BUILDINGS)}
    existing = load_existing(EXISTING_FILENAMES)
    items = []
    seen = set()
    with open(REFERENCE_CSV, newline="", encoding="utf-8-sig") as input_file:
        reader = csv.DictReader(input_file)
        for row in reader:
            building_name = str(row.get("buildingName", "")).strip()
            priority_index = priority_order.get(building_name.lower())
            if PRIORITY_ONLY and priority_index is None:
                continue
            order = priority_index if priority_index is not None else len(priority_order)
            for column in PHOTO_COLUMNS:
                for url in parse_photo_list(row.get(column)):
                    filename = image_key(url)
                    filename_key = filename.lower()
                    if not filename or filename_key in existing or filename_key in seen:
                        continue
                    if not str(url).startswith(("http://", "https://")):
                        continue
                    seen.add(filename_key)
                    items.append((order, building_name, column, filename, str(url)))
    return sorted(items)


def download(url, destination):
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept": "*/*"})
    with urllib.request.urlopen(request, timeout=90) as response:
        data = response.read()
    tmp_path = f"{destination}.tmp"
    with open(tmp_path, "wb") as output_file:
        output_file.write(data)
    os.replace(tmp_path, destination)
    return len(data)


try:
    items = collect_items()
except Exception as error:
    print(f"Failed collecting items: {error}", file=sys.stderr)
    sys.exit(1)

os.makedirs(RAW_IMAGE_DIR, exist_ok=True)
for category_dir in CATEGORY_DIR.values():
    os.makedirs(os.path.join(RAW_IMAGE_DIR, category_dir), exist_ok=True)
failures = []
downloaded = 0

print(f"Reference CSV: {REFERENCE_CSV}")
print(f"Existing filenames: {EXISTING_FILENAMES}")
print(f"Raw image dir: {RAW_IMAGE_DIR}")
print(f"Priority only: {PRIORITY_ONLY}")
print(f"Images not in existing Strapi list: {len(items)}")

for index, (order, building_name, category, filename, url) in enumerate(items, 1):
    destination = os.path.join(RAW_IMAGE_DIR, CATEGORY_DIR[category], filename)
    if DRY_RUN:
        print(f"DRY_RUN\t{index}/{len(items)}\t{building_name}\t{category}\t{filename}\t{url}")
        continue
    try:
        size = download(url, destination)
        downloaded += 1
        print(f"DOWNLOADED\t{index}/{len(items)}\t{building_name}\t{category}\t{filename}\t{size}")
    except Exception as error:
        failures.append((building_name, category, filename, url, str(error)))
        print(f"FAILED\t{index}/{len(items)}\t{building_name}\t{category}\t{filename}\t{error}", file=sys.stderr)

if failures:
    os.makedirs("report", exist_ok=True)
    failure_path = "report/reference-download-failures.tsv"
    with open(failure_path, "w", encoding="utf-8", newline="") as output_file:
        output_file.write("buildingName\tcategory\tfilename\turl\terror\n")
        for row in failures:
            output_file.write("\t".join(row) + "\n")
    print(f"Failure report: {failure_path}")

print(f"Summary: downloaded={downloaded} failed={len(failures)}")
PY
