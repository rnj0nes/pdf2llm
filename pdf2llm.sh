#!/usr/bin/env bash
set -euo pipefail

# pdf2llm.sh
# Detects if OCR is needed, runs OCR if necessary, and outputs:
#   - TXT with page markers
#   - Markdown via pandoc
#   - JSONL (one record per page) for retrieval/citation
#   - Metadata JSON describing what happened

# ---------- Config defaults ----------
MIN_TEXT_CHARS_PER_PAGE_DEFAULT=200   # heuristic: page with <200 chars is "thin"
THIN_PAGE_FRACTION_THRESHOLD_DEFAULT=0.35  # if >35% pages are thin, OCR
MAX_PAGES_TO_SAMPLE_DEFAULT=20        # speed: sample first N pages for heuristics
OCR_LANG_DEFAULT="eng"
OUTPUT_DIR_DEFAULT="llm_out"

usage() {
  cat <<'EOF'
Usage:
  pdf2llm.sh [options] input.pdf

Options:
  -o, --outdir DIR         Output directory (default: llm_out)
  -l, --lang LANG          OCR language(s) for ocrmypdf (default: eng)
  --min-chars N            Minimum chars per page before considered "thin" (default: 200)
  --thin-frac F            Fraction of thin pages to trigger OCR (default: 0.35)
  --sample-pages N         Max pages to sample for OCR decision (default: 20)
  --force-ocr              Always run OCR
  --no-ocr                 Never run OCR (extract directly)
  --keep-intermediate       Keep intermediate files (like sampled page text)
  -h, --help               Show help

Outputs (in OUTDIR):
  basename.txt             Plain text with explicit page markers
  basename.md              Markdown (pandoc)
  basename.jsonl           JSON lines: {"page":1,"text":"..."}
  basename.meta.json       Decision + tool provenance
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

# ---------- Parse args ----------
OUTDIR="$OUTPUT_DIR_DEFAULT"
OCR_LANG="$OCR_LANG_DEFAULT"
MIN_TEXT_CHARS_PER_PAGE="$MIN_TEXT_CHARS_PER_PAGE_DEFAULT"
THIN_PAGE_FRACTION_THRESHOLD="$THIN_PAGE_FRACTION_THRESHOLD_DEFAULT"
MAX_PAGES_TO_SAMPLE="$MAX_PAGES_TO_SAMPLE_DEFAULT"
FORCE_OCR=0
NO_OCR=0
KEEP_INTERMEDIATE=0

if [[ $# -eq 0 ]]; then usage; exit 1; fi

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--outdir) OUTDIR="$2"; shift 2;;
    -l|--lang) OCR_LANG="$2"; shift 2;;
    --min-chars) MIN_TEXT_CHARS_PER_PAGE="$2"; shift 2;;
    --thin-frac) THIN_PAGE_FRACTION_THRESHOLD="$2"; shift 2;;
    --sample-pages) MAX_PAGES_TO_SAMPLE="$2"; shift 2;;
    --force-ocr) FORCE_OCR=1; shift;;
    --no-ocr) NO_OCR=1; shift;;
    --keep-intermediate) KEEP_INTERMEDIATE=1; shift;;
    -h|--help) usage; exit 0;;
    --) shift; POSITIONAL+=("$@"); break;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1;;
    *) POSITIONAL+=("$1"); shift;;
  esac
done

if [[ ${#POSITIONAL[@]} -ne 1 ]]; then
  echo "ERROR: Please provide exactly one input PDF." >&2
  usage
  exit 1
fi

INPDF="${POSITIONAL[0]}"
if [[ ! -f "$INPDF" ]]; then
  echo "ERROR: File not found: $INPDF" >&2
  exit 1
fi

# ---------- Dependencies ----------
need_cmd pdfinfo
need_cmd pdftotext
need_cmd pdffonts
need_cmd python3

# pandoc is optional but strongly recommended for md output
PANDOC_AVAILABLE=1
if ! command -v pandoc >/dev/null 2>&1; then
  PANDOC_AVAILABLE=0
fi

# ocrmypdf is only needed when OCR is run
OCRMY_AVAILABLE=1
if ! command -v ocrmypdf >/dev/null 2>&1; then
  OCRMY_AVAILABLE=0
fi

mkdir -p "$OUTDIR"

BASE="$(basename "$INPDF")"
BASENAME="${BASE%.*}"
WORKDIR="$OUTDIR/.work_${BASENAME}"
mkdir -p "$WORKDIR"

META_JSON="$OUTDIR/${BASENAME}.meta.json"
OUT_TXT="$OUTDIR/${BASENAME}.txt"
OUT_MD="$OUTDIR/${BASENAME}.md"
OUT_JSONL="$OUTDIR/${BASENAME}.jsonl"

# ---------- Helper: count pages ----------
PAGES="$(pdfinfo "$INPDF" | awk -F: '/^Pages:/ {gsub(/ /,"",$2); print $2}')"
if [[ -z "${PAGES}" ]]; then
  echo "ERROR: Could not determine page count via pdfinfo." >&2
  exit 1
fi

# ---------- Heuristic 1: does pdffonts show text fonts? ----------
# If there are no fonts listed beyond header lines, likely scanned/image-only.
FONT_LINES="$(pdffonts "$INPDF" 2>/dev/null | wc -l | awk '{print $1}')"
# pdffonts prints a header (~2 lines) even with no fonts; use <= 2 as "no fonts"
HAS_FONTS=1
if [[ "$FONT_LINES" -le 2 ]]; then
  HAS_FONTS=0
fi

# ---------- Heuristic 2: sample pages and measure extracted text ----------
SAMPLE_N="$MAX_PAGES_TO_SAMPLE"
if [[ "$PAGES" -lt "$SAMPLE_N" ]]; then SAMPLE_N="$PAGES"; fi

SAMPLE_DIR="$WORKDIR/sample_pages"
mkdir -p "$SAMPLE_DIR"

THIN_PAGES=0
SAMPLED=0

# Extract first SAMPLE_N pages one-by-one to measure per-page text.
# (Avoids full extraction cost on huge PDFs.)
for ((p=1; p<=SAMPLE_N; p++)); do
  # pdftotext -f/-l extracts a specific page range
  PAGE_TXT="$SAMPLE_DIR/page_${p}.txt"
  pdftotext -layout -nopgbrk -f "$p" -l "$p" "$INPDF" "$PAGE_TXT" >/dev/null 2>&1 || true

  # Count "meaningful" chars (exclude whitespace)
  CHARS="$(python3 - <<PY
import re, pathlib
t = pathlib.Path("$PAGE_TXT").read_text(errors="ignore")
t = re.sub(r"\s+", "", t)
print(len(t))
PY
)"
  if [[ -z "$CHARS" ]]; then CHARS=0; fi
  if [[ "$CHARS" -lt "$MIN_TEXT_CHARS_PER_PAGE" ]]; then
    THIN_PAGES=$((THIN_PAGES+1))
  fi
  SAMPLED=$((SAMPLED+1))
done

THIN_FRAC="$(python3 - <<PY
thin = $THIN_PAGES
sampled = $SAMPLED
print(0.0 if sampled == 0 else thin / sampled)
PY
)"

# ---------- Decide OCR ----------
DECISION="direct"
REASON=""

if [[ "$FORCE_OCR" -eq 1 && "$NO_OCR" -eq 1 ]]; then
  echo "ERROR: Cannot use --force-ocr and --no-ocr together." >&2
  exit 1
fi

if [[ "$FORCE_OCR" -eq 1 ]]; then
  DECISION="ocr"
  REASON="forced"
elif [[ "$NO_OCR" -eq 1 ]]; then
  DECISION="direct"
  REASON="ocr_disabled"
else
  # Automatic:
  # - If no fonts: almost certainly scanned -> OCR
  # - Else if many thin pages: likely image-heavy or poor text layer -> OCR
  # - Else: direct
  if [[ "$HAS_FONTS" -eq 0 ]]; then
    DECISION="ocr"
    REASON="no_fonts_detected"
  else
    # Compare thin fraction numerically
    NEED_OCR="$(python3 - <<PY
thin_frac = float("$THIN_FRAC")
threshold = float("$THIN_PAGE_FRACTION_THRESHOLD")
print("1" if thin_frac > threshold else "0")
PY
)"
    if [[ "$NEED_OCR" -eq 1 ]]; then
      DECISION="ocr"
      REASON="thin_text_layer"
    else
      DECISION="direct"
      REASON="sufficient_text_layer"
    fi
  fi
fi

# ---------- Execute path ----------
SOURCE_PDF="$INPDF"
OCR_PDF="$OUTDIR/${BASENAME}.ocr.pdf"

if [[ "$DECISION" == "ocr" ]]; then
  if [[ "$OCRMY_AVAILABLE" -ne 1 ]]; then
    echo "ERROR: OCR requested/needed but ocrmypdf is not installed." >&2
    echo "Install ocrmypdf, or rerun with --no-ocr to force direct extraction." >&2
    exit 1
  fi

  # OCR for mixed grant PDFs: keep text if present, OCR missing pages, deskew/clean.
  # --skip-text avoids re-OCRing pages that already have text.
  ocrmypdf \
    --skip-text \
    --deskew \
    --clean \
    --optimize 3 \
    -l "$OCR_LANG" \
    "$INPDF" "$OCR_PDF"

  SOURCE_PDF="$OCR_PDF"
fi

# ---------- Output 1: TXT with explicit page markers ----------
# We'll loop pages to produce stable page boundaries for citation.
TMP_TXT="$WORKDIR/pages_concat.txt"
: > "$TMP_TXT"

for ((p=1; p<=PAGES; p++)); do
  echo "===== PAGE ${p} =====" >> "$TMP_TXT"
  pdftotext -layout -nopgbrk -f "$p" -l "$p" "$SOURCE_PDF" - \
    2>/dev/null \
    | sed 's/\r$//' \
    >> "$TMP_TXT" || true
  echo "" >> "$TMP_TXT"
done

# Light normalization: remove trailing spaces and collapse excessive blank lines
python3 - <<PY
import re, pathlib
p = pathlib.Path("$TMP_TXT")
t = p.read_text(errors="ignore")
t = re.sub(r"[ \t]+\n", "\n", t)
t = re.sub(r"\n{4,}", "\n\n\n", t)
pathlib.Path("$OUT_TXT").write_text(t)
PY

# ---------- Output 2: Markdown (pandoc) ----------
if [[ "$PANDOC_AVAILABLE" -eq 1 ]]; then
  # For best results, run pandoc on the chosen SOURCE_PDF (OCR'd or original).
  pandoc "$SOURCE_PDF" --wrap=none -o "$OUT_MD" >/dev/null 2>&1 || {
    echo "WARNING: pandoc failed to convert PDF to Markdown; continuing without md." >&2
    rm -f "$OUT_MD"
  }
else
  # Create a minimal md placeholder from text if pandoc unavailable
  python3 - <<PY
import pathlib
t = pathlib.Path("$OUT_TXT").read_text(errors="ignore")
pathlib.Path("$OUT_MD").write_text(t)
PY
fi

# ---------- Output 3: JSONL per page ----------
python3 - <<PY
import json, re, pathlib

txt = pathlib.Path("$OUT_TXT").read_text(errors="ignore")
# Split on page markers we inserted
parts = re.split(r"^===== PAGE (\d+) =====\s*$", txt, flags=re.M)
# parts: ["", "1", "text...", "2", "text...", ...]
out = pathlib.Path("$OUT_JSONL").open("w", encoding="utf-8")

it = iter(parts)
_ = next(it, None)  # leading chunk before first marker
for page, body in zip(it, it):
    page_num = int(page.strip())
    body = body.strip("\n")
    obj = {"page": page_num, "text": body}
    out.write(json.dumps(obj, ensure_ascii=False) + "\n")
out.close()
PY

# ---------- Metadata ----------
python3 - <<PY
import json, pathlib

meta = {
  "input_pdf": str(pathlib.Path("$INPDF").resolve()),
  "pages": int("$PAGES"),
  "decision": "$DECISION",
  "reason": "$REASON",
  "has_fonts": bool(int("$HAS_FONTS")),
  "font_lines": int("$FONT_LINES"),
  "sampled_pages": int("$SAMPLED"),
  "thin_pages_in_sample": int("$THIN_PAGES"),
  "thin_fraction": float("$THIN_FRAC"),
  "min_chars_per_page": int("$MIN_TEXT_CHARS_PER_PAGE"),
  "thin_fraction_threshold": float("$THIN_PAGE_FRACTION_THRESHOLD"),
  "source_pdf_used_for_extraction": str(pathlib.Path("$SOURCE_PDF").resolve()),
  "outputs": {
    "txt": str(pathlib.Path("$OUT_TXT").resolve()),
    "md": str(pathlib.Path("$OUT_MD").resolve()),
    "jsonl": str(pathlib.Path("$OUT_JSONL").resolve()),
  }
}
pathlib.Path("$META_JSON").write_text(json.dumps(meta, indent=2))
PY

# ---------- Cleanup ----------
if [[ "$KEEP_INTERMEDIATE" -eq 0 ]]; then
  rm -rf "$WORKDIR"
fi

echo "Done."
echo "TXT:   $OUT_TXT"
echo "MD:    $OUT_MD"
echo "JSONL: $OUT_JSONL"
echo "META:  $META_JSON"
if [[ "$DECISION" == "ocr" ]]; then
  echo "OCR PDF: $OCR_PDF"
fi
