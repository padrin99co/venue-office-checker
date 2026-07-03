#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
REFERENCE_DIR="${REFERENCE_DIR:-$ROOT_DIR/reference}"
REPORT_DIR="${REPORT_DIR:-$ROOT_DIR/report}"
REFERENCE_CSV="${REFERENCE_CSV:-}"
WATERMARK_STATUS_TSV="${WATERMARK_STATUS_TSV:-$REFERENCE_DIR/watermark-import-status.tsv}"
REPORT_CSV="${REPORT_CSV:-}"
REPORT_XLSX="${REPORT_XLSX:-}"
OUTPUT_XLSX="${OUTPUT_XLSX:-0}"

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
if [[ "$OUTPUT_XLSX" == "1" && -z "$REPORT_XLSX" ]]; then
  REPORT_XLSX="${REPORT_CSV%.csv}.xlsx"
fi

: "${STRAPI_URL:?STRAPI_URL missing in .env}"
: "${STRAPI_CONTENT_REF:?STRAPI_CONTENT_REF missing in .env}"

export STRAPI_OFFICE_VENUE_IMAGE_FIELD="${STRAPI_OFFICE_VENUE_IMAGE_FIELD:-image}"
export STRAPI_API_TOKEN="${STRAPI_API_TOKEN:-}"
export STRAPI_API_PATH="${STRAPI_API_PATH:-}"
export STRAPI_URL STRAPI_CONTENT_REF STRAPI_FOLDER_NAME="${STRAPI_FOLDER_NAME:-}" STRAPI_FOLDER_ID="${STRAPI_FOLDER_ID:-}"
export REFERENCE_CSV WATERMARK_STATUS_TSV REPORT_CSV REPORT_XLSX OUTPUT_XLSX

run_checker() {
python3 <<'PY'
import ast
import csv
import json
import os
import re
import sys
import time
import posixpath
import urllib.parse
import urllib.error
import urllib.request
import zipfile
from xml.sax.saxutils import escape

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
watermark_status_tsv = os.environ["WATERMARK_STATUS_TSV"]
report_csv = os.environ["REPORT_CSV"]
report_xlsx = os.environ.get("REPORT_XLSX", "")
output_xlsx = os.environ.get("OUTPUT_XLSX", "0") == "1"
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
    return len(parse_photo_list(raw))


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


def image_key(value):
    parsed = urllib.parse.urlparse(str(value or ""))
    path = parsed.path or str(value or "")
    return urllib.parse.unquote(posixpath.basename(path)).strip().lower()


def load_watermark_status(path):
    if not os.path.exists(path):
        return None
    records = {}
    with open(path, newline="", encoding="utf-8-sig") as input_file:
        reader = csv.DictReader(input_file, delimiter="\t")
        for row in reader:
            image = row.get("image", "")
            output = row.get("output", "")
            for value in (image, output):
                key = image_key(value)
                if key:
                    records[key] = row
    return records


def column_name(index):
    name = ""
    while index:
        index, remainder = divmod(index - 1, 26)
        name = chr(65 + remainder) + name
    return name


def clean_xml_text(value):
    text = str(value if value is not None else "")
    return "".join(char for char in text if char in "\t\n\r" or ord(char) >= 32)


def sheet_xml(rows):
    xml_rows = []
    for row_index, row in enumerate(rows, 1):
        cells = []
        for column_index, value in enumerate(row, 1):
            cell_ref = f"{column_name(column_index)}{row_index}"
            text = escape(clean_xml_text(value))
            cells.append(f'<c r="{cell_ref}" t="inlineStr" s="1"><is><t>{text}</t></is></c>')
        xml_rows.append(f'<row r="{row_index}">{"".join(cells)}</row>')
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
        '<sheetFormatPr defaultRowHeight="15"/>'
        '<sheetData>' + "".join(xml_rows) + '</sheetData>'
        '</worksheet>'
    )


def workbook_xml():
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets>'
        '<sheet name="Venue Image Report" sheetId="1" r:id="rId1"/>'
        '<sheet name="Watermark Import Status" sheetId="2" r:id="rId2"/>'
        '</sheets>'
        '</workbook>'
    )


def workbook_rels_xml():
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>'
        '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>'
    )


def root_rels_xml():
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>'
    )


def content_types_xml():
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '</Types>'
    )


def styles_xml():
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="1"><fill><patternFill patternType="none"/></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="2">'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>'
        '</cellXfs>'
        '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
        '</styleSheet>'
    )


def read_tsv_rows(path):
    if not os.path.exists(path):
        return [["status", "image", "output", "message", "updated_at"], ["missing", path, "", "Watermark import status file not found", ""]]
    with open(path, newline="", encoding="utf-8-sig") as input_file:
        return list(csv.reader(input_file, delimiter="\t"))


def write_xlsx(path, report_rows, watermark_rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", content_types_xml())
        archive.writestr("_rels/.rels", root_rels_xml())
        archive.writestr("xl/workbook.xml", workbook_xml())
        archive.writestr("xl/_rels/workbook.xml.rels", workbook_rels_xml())
        archive.writestr("xl/styles.xml", styles_xml())
        archive.writestr("xl/worksheets/sheet1.xml", sheet_xml(report_rows))
        archive.writestr("xl/worksheets/sheet2.xml", sheet_xml(watermark_rows))


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


def watermark_reason(reference_photos, reference_totals, strapi_totals, watermark_records):
    category_labels = [
        ("Exterior", "photosExterior"),
        ("Interior", "photosInterior"),
        ("FloorPlan", "photosFloorPlan"),
    ]
    lines = []
    for label, category in category_labels:
        if reference_totals[category] <= strapi_totals.get(category, 0):
            continue
        if watermark_records is None:
            lines.append(f"Watermark {label}: {watermark_status_tsv} not found")
            continue
        bad_items = []
        for image in reference_photos.get(category, []):
            key = image_key(image)
            record = watermark_records.get(key)
            if not record:
                bad_items.append(f"{key or image}: not found in watermark status")
                continue
            record_status = str(record.get("status", "")).strip()
            if record_status.lower() != "done":
                message = str(record.get("message", "")).strip()
                bad_items.append(f"{key}: {record_status or 'unknown'}{f' - {message}' if message else ''}")
        if bad_items:
            lines.append(f"Watermark {label}:")
            lines.extend(bad_items[:20])
            if len(bad_items) > 20:
                lines.append(f"... {len(bad_items) - 20} more")
        else:
            lines.append(f"Watermark {label}: all reference images Done")
    return "\n".join(lines)


def status_reason(status, reference_totals, strapi_totals, entry_found, reference_photos, watermark_records):
    if not entry_found:
        watermark_details = watermark_reason(reference_photos, reference_totals, strapi_totals, watermark_records)
        return f"Strapi entry not found\n{watermark_details}" if watermark_details else "Strapi entry not found"
    labels = [
        ("Exterior", "photosExterior"),
        ("Interior", "photosInterior"),
        ("FloorPlan", "photosFloorPlan"),
    ]
    mismatches = []
    for label, category in labels:
        reference_total = reference_totals[category]
        strapi_total = strapi_totals.get(category, 0)
        if status == "NOK" and reference_total > strapi_total:
            mismatches.append(f"{label}: reference={reference_total} strapi={strapi_total}")
        elif status == "INFO" and reference_total < strapi_total:
            mismatches.append(f"{label}: reference={reference_total} strapi={strapi_total}")
    watermark_details = watermark_reason(reference_photos, reference_totals, strapi_totals, watermark_records)
    details = "\n".join(mismatches)
    return f"{details}\n{watermark_details}" if watermark_details else details


def compare_status(reference_totals, strapi_totals, entry_found):
    if not entry_found:
        return "NOK"
    has_missing = any(reference_totals[category] > strapi_totals.get(category, 0) for category in CATEGORIES)
    if has_missing:
        return "NOK"
    has_extra = any(reference_totals[category] < strapi_totals.get(category, 0) for category in CATEGORIES)
    if has_extra:
        return "INFO"
    return "OK"


try:
    entries = fetch_all_entries()
except Exception as error:
    print(f"Failed fetching Strapi entries: {error}", file=sys.stderr)
    sys.exit(1)

entry_index = index_entries(entries)
watermark_records = load_watermark_status(watermark_status_tsv)

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
        "reason",
    ]
    output_fields = fieldnames + [field for field in extra_fields if field not in fieldnames]
    rows = []
    ok_count = 0
    info_count = 0
    nok_count = 0
    for row in reader:
        reference_photos = {category: parse_photo_list(row.get(category)) for category in CATEGORIES}
        reference_totals = {category: len(reference_photos[category]) for category in CATEGORIES}
        entry = find_entry(row, entry_index)
        if entry:
            strapi_totals, urls, urls_by_category, folders, folders_by_category, labels, labels_by_category = strapi_images(entry)
            status = compare_status(reference_totals, strapi_totals, True)
            row.update({
                "totalPhotos": total_photos_comparison(reference_totals, strapi_totals),
                "strapiContentUrl": content_url(entry),
                "strapiImageUrl": grouped_url_text(urls_by_category) or "\n".join(urls),
                "strapiImageLabel": grouped_label_text(labels_by_category) or "\n".join(labels),
                "strapiImageFolder": grouped_folder_text(folders_by_category) or folder_name_filter or folder_id_filter,
            })
        else:
            strapi_totals = {category: 0 for category in CATEGORIES}
            status = compare_status(reference_totals, strapi_totals, False)
            row.update({
                "totalPhotos": total_photos_comparison(reference_totals, strapi_totals),
                "strapiContentUrl": "",
                "strapiImageUrl": "",
                "strapiImageLabel": "",
                "strapiImageFolder": folder_name_filter or folder_id_filter,
            })
        row.update({
            "status": status,
            "reason": status_reason(status, reference_totals, strapi_totals, bool(entry), reference_photos, watermark_records) if status in ("NOK", "INFO") else "",
        })
        ok_count += status == "OK"
        info_count += status == "INFO"
        nok_count += status == "NOK"
        rows.append(row)

os.makedirs(os.path.dirname(report_csv), exist_ok=True)
with open(report_csv, "w", newline="", encoding="utf-8") as output_file:
    writer = csv.DictWriter(output_file, fieldnames=output_fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)

if output_xlsx:
    if not report_xlsx:
        report_xlsx = f"{os.path.splitext(report_csv)[0]}.xlsx"
    report_sheet_rows = [output_fields] + [[row.get(field, "") for field in output_fields] for row in rows]
    watermark_sheet_rows = read_tsv_rows(watermark_status_tsv)
    write_xlsx(report_xlsx, report_sheet_rows, watermark_sheet_rows)

print(f"Reference CSV: {reference_csv}")
print(f"Report CSV: {report_csv}")
if output_xlsx:
    print(f"Report XLSX: {report_xlsx}")
print(f"Rows: {len(rows)} | OK: {ok_count} | INFO: {info_count} | NOK: {nok_count}")
PY
}

run_checker
