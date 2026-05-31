#!/usr/bin/env bash
set -euo pipefail

# png2md.sh
# Processes all PNG files in a directory via OCR (tesseract)
# and combines them into a single Markdown file.

usage() {
  cat <<'EOF'
Usage:
  png2md.sh [input_directory]

Description:
  Takes all .png files in the specified directory (sorted alphanumerically),
  runs OCR on each, and appends the text to 'png2md_output.md' in the current directory.
  If no directory is provided, it uses the current directory.
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

# Check for tesseract
need_cmd tesseract

# Input directory defaults to current directory
INDIR="${1:-.}"

if [[ ! -d "$INDIR" ]]; then
  echo "ERROR: Directory not found: $INDIR" >&2
  exit 1
fi

OUTFILE="png2md_output.md"
: > "$OUTFILE"

# Temporary directory for OCR results
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Processing PNGs in $INDIR..."

# Use nullglob to handle no matches gracefully
shopt -s nullglob
PNGS=("$INDIR"/*.png)

if [ ${#PNGS[@]} -eq 0 ]; then
  echo "No PNG files found in $INDIR"
  exit 0
fi

# Sort files alphanumerically
# Using printf + sort -V for standard version/natural sort order
IFS=$'\n' SORTED_PNGS=($(printf "%s\n" "${PNGS[@]}" | sort -V))
unset IFS

COUNT=0
for png in "${SORTED_PNGS[@]}"; do
  BASENAME=$(basename "$png")
  echo "OCR-ing: $BASENAME"
  
  # Tesseract appends .txt to the output filename automatically
  tesseract "$png" "$WORKDIR/out" -l eng > /dev/null 2>&1
  
  echo "<!-- $BASENAME -->" >> "$OUTFILE"
  
  # Process text:
  # 1. Remove single newlines within paragraphs (lines followed by a non-empty line)
  # 2. Preserve double (or more) newlines as paragraph breaks
  python3 - <<PY >> "$OUTFILE"
import pathlib, re
t = pathlib.Path("$WORKDIR/out.txt").read_text(errors="ignore")
# Replace single newlines with a space, but only if not followed by another newline
# Standard trick: use a lookahead to ensure we aren't at a paragraph break
t = re.sub(r'(?<!\n)\n(?!\n)', ' ', t)
print(t.strip())
PY

  echo -e "\n" >> "$OUTFILE"
  
  COUNT=$((COUNT+1))
done

echo "Done! Processed $COUNT files."
echo "Resulting Markdown is in $OUTFILE"
