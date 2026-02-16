# pdf2llm
Process PDF output for LLM AI Agent (VS-CODE)

Developed for academic workflows requiring strict LLM grounding and page-level citation integrity.

# pdf2llm.sh

CLI tool for extracting PDF text for LLM grounding and page-level citation.

`pdf2llm.sh` automatically detects whether a PDF needs OCR, runs it only if necessary, and produces structured, page-aware outputs suitable for grant and manuscript workflows.

---

## Requirements

* `pdfinfo`, `pdftotext`, `pdffonts` (Poppler)
* `python3`
* Optional: `ocrmypdf`, `pandoc`

macOS (Homebrew):

```bash
brew install poppler ocrmypdf pandoc
```

---

## Usage

```bash
chmod +x pdf2llm.sh
./pdf2llm.sh MyDocument.pdf
```

Outputs are written to:

```
llm_out/
```

---

## Outputs

For `MyDocument.pdf`:

```
llm_out/
├── MyDocument.txt
├── MyDocument.jsonl
├── MyDocument.md
├── MyDocument.meta.json
```

**.txt**
Plain text with explicit page markers.

**.jsonl**
One JSON object per page. Recommended source for page-level citation and retrieval.

**.md**
Pandoc Markdown (secondary, structural view).

**.meta.json**
Records OCR decision and extraction metadata.

---

## OCR Logic

The script:

* Checks for embedded fonts.
* Samples pages to detect “thin” text layers.
* Runs OCR only when needed.

Override with:

```bash
--force-ocr
--no-ocr
```

---

## Typical LLM Workflow

1. Treat `llm_out/` as your document corpus.
2. Use `.jsonl` for page-cited answers.
3. Cite as:
   `[MyDocument.pdf p.12]`

If content is not found in extracted text, do not guess.

## Windows Quick Start

The recommended way to run `pdf2llm.sh` on Windows is via **WSL (Windows Subsystem for Linux)**.

### 1. Install WSL (PowerShell as Admin)

```powershell
wsl --install
```

Reboot if prompted.

### 2. Install dependencies (inside WSL)

```bash
sudo apt update
sudo apt install poppler-utils python3 ocrmypdf pandoc
```

### 3. Run the script

```bash
chmod +x pdf2llm.sh
./pdf2llm.sh MyDocument.pdf
```

Your Windows files are available in WSL at:

```
/mnt/c/Users/<YourUsername>/
```

For best compatibility with macOS/Linux collaborators, use WSL.

---

## License

MIT 