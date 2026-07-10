#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFERENCE_DIR="${REFERENCE_DIR:-$ROOT_DIR/reference}"
RAW_IMAGE_DIR="${RAW_IMAGE_DIR:-$ROOT_DIR/raw-image}"
REFERENCE_CSV="${REFERENCE_CSV:-}"
REPORT_XLSX="${REPORT_XLSX:-}"
DRY_RUN="${DRY_RUN:-0}"

if [[ -z "$REPORT_XLSX" ]]; then
  mapfile -t xlsx_files < <(find "$ROOT_DIR/report" -maxdepth 1 -type f -name 'strapi-venue-images-*.xlsx' | sort)
  if [[ ${#xlsx_files[@]} -eq 0 ]]; then
    echo "No XLSX report found in $ROOT_DIR/report. Run: make check-strapi-venue-images-xlsx" >&2
    exit 1
  fi
  REPORT_XLSX="${xlsx_files[-1]}"
fi

if [[ -z "$REFERENCE_CSV" ]]; then
  mapfile -t csv_files < <(find "$REFERENCE_DIR" -maxdepth 1 -type f -name '*.csv' | sort)
  if [[ ${#csv_files[@]} -eq 0 ]]; then
    echo "No reference CSV found in $REFERENCE_DIR" >&2
    exit 1
  fi
  if [[ ${#csv_files[@]} -gt 1 ]]; then
    echo "Multiple reference CSV files found. Set REFERENCE_CSV=path/to/file.csv" >&2
    printf ' - %s\n' "${csv_files[@]}" >&2
    exit 1
  fi
  REFERENCE_CSV="${csv_files[0]}"
fi

export REPORT_XLSX REFERENCE_CSV RAW_IMAGE_DIR DRY_RUN

python3 <<'PY'
import ast
import csv
import json
import os
import posixpath
import re
import sys
import urllib.parse
import urllib.request
import zipfile
import xml.etree.ElementTree as ET

REPORT_XLSX = os.environ["REPORT_XLSX"]
REFERENCE_CSV = os.environ["REFERENCE_CSV"]
RAW_IMAGE_DIR = os.environ["RAW_IMAGE_DIR"]
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"
PHOTO_COLUMNS = ("photosExterior", "photosInterior", "photosFloorPlan")
CATEGORY_DIR = {
    "photosExterior": "exterior",
    "photosInterior": "interior",
    "photosFloorPlan": "floorplan",
}
NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
MISSING_PATTERN = re.compile(r"^([^:\n]+\.(?:jpe?g|png|webp|avif|gif)):\s+(?:not found in watermark status|[^\n]*failed|[^\n]*Failed)", re.IGNORECASE)


def image_key(value):
    parsed = urllib.parse.urlparse(str(value or ""))
    path = parsed.path or str(value or "")
    return urllib.parse.unquote(posixpath.basename(path)).strip().lower()


def parse_photo_list(raw):
    if raw is None:
        return []
    text = str(raw).strip()
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


def build_reference_url_map(path):
    mapping = {}
    with open(path, newline="", encoding="utf-8-sig") as input_file:
        reader = csv.DictReader(input_file)
        for row in reader:
            for column in PHOTO_COLUMNS:
                for url in parse_photo_list(row.get(column)):
                    key = image_key(url)
                    if key and str(url).startswith(("http://", "https://")):
                        mapping.setdefault(key, (url, CATEGORY_DIR[column]))
    return mapping


def column_index(cell_ref):
    letters = "".join(char for char in cell_ref if char.isalpha())
    value = 0
    for char in letters:
        value = value * 26 + ord(char.upper()) - 64
    return value - 1


def shared_strings(archive):
    try:
        xml = archive.read("xl/sharedStrings.xml")
    except KeyError:
        return []
    root = ET.fromstring(xml)
    values = []
    for item in root.findall("m:si", NS):
        texts = [node.text or "" for node in item.findall(".//m:t", NS)]
        values.append("".join(texts))
    return values


def workbook_sheet_path(archive, sheet_name):
    workbook = ET.fromstring(archive.read("xl/workbook.xml"))
    rels = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
    rel_map = {rel.attrib["Id"]: rel.attrib["Target"] for rel in rels}
    for sheet in workbook.findall("m:sheets/m:sheet", NS):
        if sheet.attrib.get("name") == sheet_name:
            rel_id = sheet.attrib.get("{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id")
            target = rel_map[rel_id]
            return "xl/" + target.lstrip("/") if not target.startswith("xl/") else target
    return "xl/worksheets/sheet1.xml"


def read_sheet_rows(path, sheet_name):
    with zipfile.ZipFile(path) as archive:
        strings = shared_strings(archive)
        sheet_path = workbook_sheet_path(archive, sheet_name)
        root = ET.fromstring(archive.read(sheet_path))
        rows = []
        for row in root.findall("m:sheetData/m:row", NS):
            values = []
            for cell in row.findall("m:c", NS):
                index = column_index(cell.attrib.get("r", "A1"))
                while len(values) <= index:
                    values.append("")
                cell_type = cell.attrib.get("t")
                if cell_type == "inlineStr":
                    texts = [node.text or "" for node in cell.findall(".//m:t", NS)]
                    values[index] = "".join(texts)
                elif cell_type == "s":
                    value_node = cell.find("m:v", NS)
                    values[index] = strings[int(value_node.text)] if value_node is not None and value_node.text else ""
                else:
                    value_node = cell.find("m:v", NS)
                    values[index] = value_node.text if value_node is not None else ""
            rows.append(values)
        return rows


def missing_names_from_report(path):
    rows = read_sheet_rows(path, "Venue Image Report")
    if not rows:
        return []
    headers = rows[0]
    try:
        status_index = headers.index("status")
        reason_index = headers.index("reason")
    except ValueError as error:
        raise RuntimeError("XLSX report missing status/reason columns") from error
    names = []
    seen = set()
    for row in rows[1:]:
        status = row[status_index] if status_index < len(row) else ""
        reason = row[reason_index] if reason_index < len(row) else ""
        if str(status).strip().upper() != "NOK":
            continue
        for line in str(reason).splitlines():
            match = MISSING_PATTERN.match(line.strip())
            if not match:
                continue
            name = match.group(1).strip()
            key = image_key(name)
            if key and key not in seen:
                seen.add(key)
                names.append(name)
    return names


def download(url, destination):
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept": "*/*"})
    with urllib.request.urlopen(request, timeout=90) as response:
        data = response.read()
    with open(destination, "wb") as output_file:
        output_file.write(data)
    return len(data)


try:
    reference_urls = build_reference_url_map(REFERENCE_CSV)
    missing_names = missing_names_from_report(REPORT_XLSX)
except Exception as error:
    print(f"Failed reading inputs: {error}", file=sys.stderr)
    sys.exit(1)

os.makedirs(RAW_IMAGE_DIR, exist_ok=True)
for category_dir in CATEGORY_DIR.values():
    os.makedirs(os.path.join(RAW_IMAGE_DIR, category_dir), exist_ok=True)
downloaded = 0
skipped = 0
not_found = 0
failed = 0

print(f"Report XLSX: {REPORT_XLSX}")
print(f"Reference CSV: {REFERENCE_CSV}")
print(f"Raw image dir: {RAW_IMAGE_DIR}")
print(f"Missing image names: {len(missing_names)}")

for name in missing_names:
    key = image_key(name)
    reference_item = reference_urls.get(key)
    if not reference_item:
        not_found += 1
        print(f"NOT_FOUND\t{name}")
        continue
    url, category_dir = reference_item
    destination = os.path.join(RAW_IMAGE_DIR, category_dir, key)
    if os.path.exists(destination):
        skipped += 1
        print(f"SKIP\t{key}")
        continue
    if DRY_RUN:
        print(f"DRY_RUN\t{key}\t{url}")
        continue
    try:
        size = download(url, destination)
        downloaded += 1
        print(f"DOWNLOADED\t{key}\t{size}\t{url}")
    except Exception as error:
        failed += 1
        print(f"FAILED\t{key}\t{error}", file=sys.stderr)

print(f"Summary: downloaded={downloaded} skipped={skipped} not_found={not_found} failed={failed}")
PY
