# textextract

Two-stage text extraction for images, including  multi-page .pdf files or single image files. It runs two extraction paths:

- **Tesseract (fast, deterministic)**: great for printed text; tries embedded PDF text first.
- **Vision LLM via Ollama (slower, often stronger on hard cases)**: sends rendered pages/images to a local vision model for transcription.

Outputs are merged into a single R data file (`.rds`) for analysis.

---

## Features

- Accepts inputs:
  - PDFs (`.pdf`, multi-page)
  - Images (commonly `.png`, `.jpg/.jpeg`, `.tif/.tiff`, `.gif`, `.webp`, `.bmp`; anything Pillow can open)
  - Multi-frame images (TIFF/GIF) are treated like multi-page documents
- Produces:
  - `outputs/tesseract_output.csv`
  - `outputs/llm_output.csv`
  - `outputs/combined_ocr.rds` (merged on `filename + page_number`)
- Resume-friendly LLM extraction (skips pages already in CSV, if enabled)
- Local by default.

---

## How it works (high level)

### Part 1 — Tesseract (`pythonscript/tesseract_pdf_ocr.py`)
- **PDFs**: for each page, attempts **embedded text** via PyMuPDF first; if empty, renders and OCRs via Tesseract.
- **Images**: OCRs directly via Tesseract (multi-frame => multiple pages).

### Part 2 — Ollama Vision LLM (generated script: `pythonscript/llm_script.py`)
- **PDFs**: uses Poppler (`pdfinfo` + `pdftoppm`) to render each page to an image, then sends to Ollama `/api/generate` with `images=[base64]`.
- **Images**: opens via Pillow; may re-encode to PNG/JPEG for sending (configurable).

### Part 3 — Combine results (in `run_pdfscan.R`)
- Loads `outputs/llm_output.csv` and `outputs/tesseract_output.csv`
- Full outer-joins on `filename` + `page_number`
- Saves `outputs/combined_ocr.rds`

---

## Requirements

### Core
- MacOS (requires some adjustment for Linux/Windows)
- R (to run the pipeline)
- Python 3.12+ (recommended: 3.12 or 3.13)
- Ollama (local LLM server)
- Poppler tools: `pdfinfo`, `pdftoppm` (for PDF → image rendering in Part 2)
- Tesseract OCR engine (system binary) (for Part 1)

### R packages
- `reticulate` (required)
- `data.table` (optional but recommended for faster CSV reads)

### Python packages (in the project venv)
Part 1 (Tesseract):
- `pymupdf` (provides `fitz`)
- `pytesseract`
- `pillow`
- `pandas`

Part 2 (LLM / Ollama):
- `requests`
- `pillow`

---

## Installation Instructions (tested with MacOS - Apple Silicon)

1) Download this repository  
   - Click the green **Code** button → **Download ZIP**  
   - Unzip it (you’ll have a folder named something like `pdfscan`)

2) Install Ollama (the local LLM app)  
   - Download/install: https://ollama.com/download  
   - Open Ollama (leave it running)

3) Install R + RStudio  
   - Install R: https://cran.r-project.org/bin/macosx/  
   - Install RStudio: https://posit.co/download/rstudio-desktop/

4) Open Terminal (you only need to do this once)  
   - Finder → Applications → Utilities → **Terminal**

5) In Terminal: “go into” the pdfscan folder  
   - Type: `cd ` (that’s `cd` plus a space)  
   - Drag the **pdfscan** folder from Finder into the Terminal window  
   - Press **Return**

6) In Terminal: copy/paste this whole block, then press Return  
   (This installs the PDF tools + Tesseract, downloads the LLM model, sets up Python, and installs R packages.)

   ```bash
   # Install Homebrew (skip if you already have it)
   if ! command -v brew >/dev/null 2>&1; then
     /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
     echo 'Homebrew installed. Now close/reopen Terminal and run this step again.'; exit 0
   fi

   # Install system tools needed for PDFs + OCR + Python
   brew install poppler tesseract python@3.13

   # Download the Ollama model used for OCR (change if you use a different model)
   ollama pull qwen3-vl:8b # recommended NOT using 8b version without 32gb+ ram.
                           # If resource-constrained, switch to something like:
                           # qwen3-vl:2b or translategemma:4b or ministral-3:3b or whatever else
                           # for more options, see: https://ollama.com/search?c=vision 
 
   # Create the project Python environment + install Python packages
   python3 -m venv venv
   ./venv/bin/python -m pip install --upgrade pip
   ./venv/bin/python -m pip install pymupdf pytesseract pillow pandas requests

   # Install required R packages
   Rscript -e 'install.packages(c("reticulate","data.table"))'
   ```

7) Quick checks (optional, but helpful if something goes wrong later)  
   - In Terminal:
     - `tesseract --version`
     - `pdfinfo -v`
     - `ollama list`
     - `./venv/bin/python -c "import fitz, pytesseract, PIL, pandas, requests; print('python ok')"`

## How to Use

1) Make sure Ollama is running  
   - Open the Ollama app (leave it open), or in Terminal run:
     - `ollama serve`

2) Put your files in the input folder  
   - Copy PDFs and/or images into:
     - `pdfscan/inputs/`
   - Supported: PDFs + common image formats (PNG/JPG/TIFF/etc.)

3) Open the project in RStudio  
   - Open RStudio  
   - File → Open File… → select `run_pdfscan.R` inside the `pdfscan` folder

4) Run the script  
   - Click **Source** (top-right of the editor)
   - Or highlight all code and click **Run**

5) Be prepared for long runtimes (important)  
   - This tool processes documents **page-by-page** (and multi-frame images frame-by-frame).  
   - The LLM step can be **slow**. Depending on the model, DPI, and page complexity, it can take:
     - **tens of seconds to several minutes per page**
   - Large PDFs or folders of images may take **hours**. This is normal.  
   - Plan for “start it and let it run” (overnight runs are common), even on a strong computer and even with smaller models.

6) Find your outputs  
   - `pdfscan/outputs/tesseract_output.csv`  
   - `pdfscan/outputs/llm_output.csv`  
   - `pdfscan/outputs/combined_ocr.rds`

7) Load the combined file in R (optional)
```r
combined <- readRDS("outputs/combined_ocr.rds")
head(combined, 3)
```

8) Common adjustments (if results are poor or it’s too slow)
- Handwriting / faint scans:
  - In `run_pdfscan.R` set: `image_format <- "png"` (usually much better than JPEG)
- Faster runs on printed documents:
  - Try `dpi <- 120` (PDFs only)
  - Keep `image_format <- "jpeg"` for speed if handwriting isn’t involved
- If the LLM output seems cut off:
  - Increase: `num_predict <- 8192`

Notes:
- The script is designed to be re-run. If `resume <- TRUE` in the LLM settings, it will skip pages already in `outputs/llm_output.csv`.
- Avoid opening the output CSVs in Excel/Numbers and saving over them (it can break multi-line text formatting).
