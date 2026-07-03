#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
REFERENCE_DIR="${REFERENCE_DIR:-$ROOT_DIR/reference}"
REPORT_DIR="${REPORT_DIR:-$ROOT_DIR/report}"
REFERENCE_CSV="${REFERENCE_CSV:-}"
REPORT_CSV="${REPORT_CSV:-}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -z "$REFERENCE_CSV" ]]; then
  mapfile -t csv_files < <(find "$REFERENCE_DIR" -maxdepth 1 -type f -name '*.csv' | sort)
  if [[ ${#csv_files[@]} -eq 0 ]]; then
    echo "No CSV found in $REFERENCE_DIR" >&2
    exit 1
  fi
  if [[ ${#csv_files[@]} -gt 1 ]]; then
    echo "Multiple CSV files found in $REFERENCE_DIR. Set REFERENCE_CSV=path/to/file.csv" >&2
    printf ' - %s\n' "${csv_files[@]}" >&2
    exit 1
  fi
  REFERENCE_CSV="${csv_files[0]}"
fi

mkdir -p "$REPORT_DIR"
if [[ -z "$REPORT_CSV" ]]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  REPORT_CSV="$REPORT_DIR/strapi-venue-images-$stamp.csv"
fi

: "${STRAPI_URL:?STRAPI_URL missing in .env}"
: "${STRAPI_CONTENT_REF:?STRAPI_CONTENT_REF missing in .env}"

export STRAPI_OFFICE_VENUE_IMAGE_FIELD="${STRAPI_OFFICE_VENUE_IMAGE_FIELD:-image}"
export STRAPI_API_TOKEN="${STRAPI_API_TOKEN:-}"
export STRAPI_API_PATH="${STRAPI_API_PATH:-}"
export STRAPI_URL STRAPI_CONTENT_REF STRAPI_FOLDER_NAME="${STRAPI_FOLDER_NAME:-}" STRAPI_FOLDER_ID="${STRAPI_FOLDER_ID:-}"
export REFERENCE_CSV REPORT_CSV

run_checker() {
python3 <<'PY'
import ast
import csv
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.error
import urllib.request

CATEGORIES = ["photosExterior", "photosInterior", "photosFloorPlan"]
CATEGORY_BY_SUB_TYPE = {
    "Fasad Gedung": "photosExterior",
    "Foto Lainnya": "photosInterior",
    "Denah Ruang": "photosFloorPlan",
}

strapi_url = os.environ["STRAPI_URL"].rstrip("/")
content_ref = os.environ["STRAPI_CONTENT_REF"]
if not content_ref.startswith("api::"):
    content_ref = f"api::{content_ref}"
image_field = os.environ.get("STRAPI_OFFICE_VENUE_IMAGE_FIELD", "image")
api_token = os.environ.get("STRAPI_API_TOKEN", "")
api_path = os.environ.get("STRAPI_API_PATH", "")
reference_csv = os.environ["REFERENCE_CSV"]
report_csv = os.environ["REPORT_CSV"]
folder_name_filter = os.environ.get("STRAPI_FOLDER_NAME", "")
folder_id_filter = os.environ.get("STRAPI_FOLDER_ID", "")


def request_json(path, params=None):
    url = f"{strapi_url}{path}"
    if params:
        url = f"{url}?{urllib.parse.urlencode(params, doseq=True)}"
    headers = {
        "Accept": "application/json,text/plain,*/*",
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
        "Referer": f"{strapi_url}/admin/",
    }
    if api_token:
        headers["Authorization"] = f"Bearer {api_token}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        print(f"HTTP {error.code}: {url}", file=sys.stderr)
        raise


def parse_photo_total(raw):
    if raw is None:
        return 0
    text = str(raw).strip()
    if not text:
        return 0
    if text.isdigit():
        return 1
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        try:
            data = ast.literal_eval(text)
        except (ValueError, SyntaxError):
            return 0
    if isinstance(data, dict):
        photos = data.get("photos", [])
        return len(photos) if isinstance(photos, list) else 0
    if isinstance(data, list):
        return len(data)
    return 0


def slugify(value):
    text = str(value or "").strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    return text.strip("-")


def default_api_path():
    api_name = content_ref.split("::", 1)[-1].split(".", 1)[0]
    if api_name.endswith("y"):
        return f"/api/{api_name[:-1]}ies"
    if api_name.endswith("s"):
        return f"/api/{api_name}es"
    return f"/api/{api_name}s"

def pick_entries(payload):
    data = payload.get("results", payload.get("data", payload))
    if isinstance(data, dict) and "results" in data:
        data = data["results"]
    return data if isinstance(data, list) else []


def fetch_all_entries():
    entries = []
    page = 1
    page_size = 100
    path = api_path or default_api_path()
    while True:
        payload = request_json(
            path,
            {
                "pagination[page]": page,
                "pagination[pageSize]": page_size,
                "populate[image][populate]": "imageUrl",
            },
        )
        batch = pick_entries(payload)
        entries.extend(batch)
        pagination = payload.get("pagination") or payload.get("meta", {}).get("pagination") or {}
        page_count = pagination.get("pageCount")
        total = pagination.get("total")
        if page_count and page >= int(page_count):
            break
        if total and len(entries) >= int(total):
            break
        if len(batch) < page_size:
            break
        page += 1
        time.sleep(0.1)
    return entries


def scalar(value):
    if isinstance(value, dict):
        if "data" in value:
            return scalar(value["data"])
        if "attributes" in value:
            return scalar(value["attributes"])
        for key in ("id", "documentId", "name", "url"):
            if key in value:
                return value[key]
    return value


def get_field(entry, *names):
    attrs = entry.get("attributes", entry)
    for name in names:
        if name in attrs:
            return attrs[name]
    return None


def normalize_id(value):
    value = scalar(value)
    if value is None:
        return ""
    return str(value).strip()


def entry_key(entry):
    for names in (("buildingId", "building_id"), ("complexId", "complex_id"), ("legacyId", "legacy_id"), ("slug",), ("name", "buildingName", "title")):
        for name in names:
            value = normalize_id(get_field(entry, name))
            if value:
                return name, value.lower()
    return "id", normalize_id(entry.get("id", "")).lower()


def image_items(value):
    if value is None:
        return []
    if isinstance(value, dict) and "data" in value:
        value = value["data"]
    if isinstance(value, list):
        items = value
    elif isinstance(value, dict):
        items = [value]
    else:
        return []
    normalized = []
    for item in items:
        if not isinstance(item, dict):
            continue
        attrs = item.get("attributes", item)
        if isinstance(attrs, dict):
            normalized.append(attrs)
    return normalized

def component_items(value):
    if value is None:
        return []
    if isinstance(value, dict) and "data" in value:
        value = value["data"]
    if not isinstance(value, list):
        return []
    components = []
    for item in value:
        if isinstance(item, dict):
            attrs = item.get("attributes", item)
            if isinstance(attrs, dict):
                components.append(attrs)
    return components


def absolute_url(url):
    if not url:
        return ""
    if str(url).startswith(("http://", "https://")):
        return str(url)
    return f"{strapi_url}{url}"


def folder_label(asset):
    folder = asset.get("folder") or asset.get("folderPath") or asset.get("path") or asset.get("folderName")
    if isinstance(folder, dict):
        attrs = folder.get("attributes", folder)
        folder_path = attrs.get("path") or attrs.get("name") or attrs.get("id") or ""
        return str(folder_path).replace("/", " > ")
    if folder:
        return str(folder).replace("/", " > ")
    asset_name = asset.get("name") or asset.get("hash")
    if asset_name:
        root_folder = folder_name_filter or "Office Venue"
        if not str(root_folder).startswith("Media Library"):
            root_folder = f"Media Library > {root_folder}"
        return f"{root_folder} > {asset_name}"
    return ""


def strapi_images(entry):
    urls = []
    urls_by_category = {category: [] for category in CATEGORIES}
    folders = []
    folders_by_category = {category: [] for category in CATEGORIES}
    labels = []
    labels_by_category = {category: [] for category in CATEGORIES}
    totals = {}
    components = component_items(get_field(entry, image_field))
    if components:
        for category in CATEGORIES:
            totals[category] = 0
        for component in components:
            category = CATEGORY_BY_SUB_TYPE.get(component.get("subType") or component.get("sub_type"))
            if not category:
                continue
            label_parts = [component.get("source"), component.get("type"), component.get("subType") or component.get("sub_type")]
            label = " > ".join(str(part) for part in label_parts if part)
            if label:
                labels.append(label)
                labels_by_category[category].append(label)
            items = image_items(component.get("imageUrl") or component.get("image_url"))
            if not items and component.get("imageUrl"):
                items = [{"id": component.get("imageUrl")}]
            totals[category] += len(items)
            for item in items:
                url = absolute_url(item.get("url"))
                if url:
                    urls.append(url)
                    urls_by_category[category].append(url)
                folder = folder_label(item)
                if folder:
                    folders.append(folder)
                    folders_by_category[category].append(folder)
    else:
        for category in CATEGORIES:
            items = image_items(get_field(entry, category))
            totals[category] = len(items)
            for item in items:
                url = absolute_url(item.get("url"))
                if url:
                    urls.append(url)
                    urls_by_category[category].append(url)
                folder = folder_label(item)
                if folder:
                    folders.append(folder)
                    folders_by_category[category].append(folder)
    seen_urls = list(dict.fromkeys(urls))
    seen_urls_by_category = {category: list(dict.fromkeys(values)) for category, values in urls_by_category.items()}
    seen_folders = list(dict.fromkeys(folders))
    seen_folders_by_category = {category: list(dict.fromkeys(values)) for category, values in folders_by_category.items()}
    seen_labels = list(dict.fromkeys(labels))
    seen_labels_by_category = {category: list(dict.fromkeys(values)) for category, values in labels_by_category.items()}
    return totals, seen_urls, seen_urls_by_category, seen_folders, seen_folders_by_category, seen_labels, seen_labels_by_category


def content_url(entry):
    entry_id = entry.get("documentId") or entry.get("id") or normalize_id(get_field(entry, "id"))
    return f"{strapi_url}/admin/content-manager/collectionType/{content_ref}/{entry_id}" if entry_id else ""


def index_entries(entries):
    index = {}
    for entry in entries:
        key_name, key_value = entry_key(entry)
        if key_value:
            index[(key_name, key_value)] = entry
            index.setdefault(("any", key_value), entry)
    return index


def find_entry(row, index):
    building_slug = slugify(row.get("buildingName", ""))
    candidates = [
        ("buildingId", row.get("buildingId", "")),
        ("building_id", row.get("buildingId", "")),
        ("complexId", row.get("complexId", "")),
        ("complex_id", row.get("complexId", "")),
        ("name", row.get("buildingName", "")),
        ("buildingName", row.get("buildingName", "")),
        ("title", row.get("buildingName", "")),
        ("slug", building_slug),
        ("any", row.get("buildingId", "")),
        ("any", row.get("complexId", "")),
        ("any", row.get("buildingName", "")),
        ("any", building_slug),
    ]
    for key_name, key_value in candidates:
        key = str(key_value or "").strip().lower()
        if key and (key_name, key) in index:
            return index[(key_name, key)]
    return None


def total_photos_comparison(reference_totals, strapi_totals):
    return "\n".join([
        f"Exterior: reference={reference_totals['photosExterior']} strapi={strapi_totals.get('photosExterior', 0)}",
        f"Interior: reference={reference_totals['photosInterior']} strapi={strapi_totals.get('photosInterior', 0)}",
        f"FloorPlan: reference={reference_totals['photosFloorPlan']} strapi={strapi_totals.get('photosFloorPlan', 0)}",
    ])


def grouped_folder_text(folders_by_category):
    sections = [
        ("Interior", folders_by_category.get("photosInterior", [])),
        ("Exterior", folders_by_category.get("photosExterior", [])),
        ("FloorPlan", folders_by_category.get("photosFloorPlan", [])),
    ]
    lines = []
    for label, folders in sections:
        if not folders:
            continue
        lines.append(f"{label}:")
        lines.extend(folders)
    return "\n".join(lines)


def grouped_url_text(urls_by_category):
    sections = [
        ("Interior", urls_by_category.get("photosInterior", [])),
        ("Exterior", urls_by_category.get("photosExterior", [])),
        ("FloorPlan", urls_by_category.get("photosFloorPlan", [])),
    ]
    lines = []
    for label, urls in sections:
        if not urls:
            continue
        lines.append(f"{label}:")
        lines.extend(urls)
    return "\n".join(lines)


def grouped_label_text(labels_by_category):
    sections = [
        ("Interior", labels_by_category.get("photosInterior", [])),
        ("Exterior", labels_by_category.get("photosExterior", [])),
        ("FloorPlan", labels_by_category.get("photosFloorPlan", [])),
    ]
    lines = []
    for label, values in sections:
        if not values:
            continue
        lines.append(f"{label}:")
        lines.extend(values)
    return "\n".join(lines)


try:
    entries = fetch_all_entries()
except Exception as error:
    print(f"Failed fetching Strapi entries: {error}", file=sys.stderr)
    sys.exit(1)

entry_index = index_entries(entries)

with open(reference_csv, newline="", encoding="utf-8-sig") as input_file:
    reader = csv.DictReader(input_file)
    fieldnames = list(reader.fieldnames or [])
    extra_fields = [
        "totalPhotos",
        "strapiContentUrl",
        "strapiImageUrl",
        "strapiImageLabel",
        "strapiImageFolder",
        "status",
    ]
    output_fields = fieldnames + [field for field in extra_fields if field not in fieldnames]
    rows = []
    ok_count = 0
    nok_count = 0
    for row in reader:
        reference_totals = {category: parse_photo_total(row.get(category)) for category in CATEGORIES}
        entry = find_entry(row, entry_index)
        if entry:
            strapi_totals, urls, urls_by_category, folders, folders_by_category, labels, labels_by_category = strapi_images(entry)
            status = "OK" if all(reference_totals[category] == strapi_totals.get(category, 0) for category in CATEGORIES) else "NOK"
            row.update({
                "totalPhotos": total_photos_comparison(reference_totals, strapi_totals),
                "strapiContentUrl": content_url(entry),
                "strapiImageUrl": grouped_url_text(urls_by_category) or "\n".join(urls),
                "strapiImageLabel": grouped_label_text(labels_by_category) or "\n".join(labels),
                "strapiImageFolder": grouped_folder_text(folders_by_category) or folder_name_filter or folder_id_filter,
            })
        else:
            status = "NOK"
            strapi_totals = {category: 0 for category in CATEGORIES}
            row.update({
                "totalPhotos": total_photos_comparison(reference_totals, strapi_totals),
                "strapiContentUrl": "",
                "strapiImageUrl": "",
                "strapiImageLabel": "",
                "strapiImageFolder": folder_name_filter or folder_id_filter,
            })
        row.update({
            "status": status,
        })
        ok_count += status == "OK"
        nok_count += status == "NOK"
        rows.append(row)

os.makedirs(os.path.dirname(report_csv), exist_ok=True)
with open(report_csv, "w", newline="", encoding="utf-8") as output_file:
    writer = csv.DictWriter(output_file, fieldnames=output_fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)

print(f"Reference CSV: {reference_csv}")
print(f"Report CSV: {report_csv}")
print(f"Rows: {len(rows)} | OK: {ok_count} | NOK: {nok_count}")
PY
}

run_checker
