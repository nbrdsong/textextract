#### PART 1: Tesseract OCR ####

library(reticulate)

venv_py <- file.path(getwd(), "venv", "bin", "python")
use_python(venv_py, required = TRUE)

py_install("pymupdf", pip = TRUE) 

py_config() 
reticulate::py_install(c("pytesseract", "pillow"), pip = TRUE)

source_python(file.path("pythonscript", "tesseract_ocr.py"))

#### PART 2: LLM ####

# EDIT THESE
model  <- "qwen3-vl:8b"  # MUST match exactly what you see in: `ollama list`
												# Run bigger models for important, hard text
												# smaller models for speed. Also...
												# delete llm_script.py before running if you change the model
prompt <- paste(
	"Extract all text from this image exactly as it appears.",
	"Transcribe all visible text in reading order, preserving line breaks.",
	"Do not interpret, summarize, or add anything.",
	sep = "\n"
)

input_folder <- "inputs"
output_dir   <- "outputs"
output_csv   <- file.path(output_dir, "llm_output.csv")

ollama_url <- "http://localhost:11434/api/generate"
dpi <- 150

# speed/robustness knobs
image_format <- "png"   # "png" (best fidelity) or "jpeg" (smaller/faster)
jpeg_quality <- 90       # only used if image_format == "jpeg"
keep_alive   <- "30m"    # keeps model loaded between pages
num_predict  <- 4096     # raise if you see truncation
temperature  <- 0        # deterministic
resume       <- TRUE     # skip pages already in output_csv
timeout_sec  <- 600
num_ctx      <- 8192

## - ##

dir.create(input_folder, showWarnings = FALSE, recursive = TRUE)
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
dir.create("pythonscript", showWarnings = FALSE, recursive = TRUE)

for (p in c("/opt/homebrew/bin", "/usr/local/bin")) {
	if (dir.exists(p) && !grepl(p, Sys.getenv("PATH"), fixed = TRUE)) {
		Sys.setenv(PATH = paste(p, Sys.getenv("PATH"), sep = ":"))
	}
}

# Helper: single-quote a string safely for Python
py_quote <- function(x) {
	x <- gsub("\\\\", "\\\\\\\\", x)  
	x <- gsub("'", "\\\\'", x)        
	paste0("'", x, "'")
}

# 1) Choose Python
venv_py <- file.path(".", "venv", "bin", "python")
base_py <- Sys.which("python3")
if (base_py == "") base_py <- "/opt/homebrew/bin/python3"

if (!file.exists(venv_py)) {
	cat("No ./venv found; creating it now...\n")
	system2(base_py, c("-m", "venv", "venv"))
}

py <- venv_py 
cat("Using Python:", py, "\n")

# 2) Ensure Python deps in THIS venv
system2(py, c("-m", "ensurepip", "--upgrade"))
system2(py, c("-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"))
system2(py, c("-m", "pip", "install", "--upgrade", "requests", "pillow"))

# 3) Generate the Python script (fresh each run)
py_file <- file.path(".", "pythonscript", "llm_script.py")

# Keep prompt safe inside Python triple-double-quoted string
prompt_safe  <- gsub('"""', '\\\"\\\"\\\"', prompt, fixed = TRUE)
prompt_lines <- strsplit(prompt_safe, "\n", fixed = TRUE)[[1]]
resume_py    <- if (isTRUE(resume)) "True" else "False"

py_lines <- c(
	'from pathlib import Path',
	'import base64, csv, os, shutil, subprocess, tempfile, time',
	'from io import BytesIO',
	'',
	'import requests',
	'from PIL import Image, ImageSequence, ImageOps',
	'',
	'# This script lives in: PROJECT_ROOT/pythonscript/llm_script.py',
	'PROJECT_ROOT = Path(__file__).resolve().parents[1]',
	paste0('INPUT_DIR    = PROJECT_ROOT / ', py_quote(input_folder)),
	paste0('OUTPUT_CSV   = PROJECT_ROOT / ', py_quote(output_csv)),
	'',
	paste0('OLLAMA_URL   = ', py_quote(ollama_url)),
	paste0('OLLAMA_MODEL = ', py_quote(model)),
	'PROMPT = """',
	prompt_lines,
	'"""',
	'',
	paste0('DPI = ', as.integer(dpi)),
	paste0('IMAGE_FORMAT = ', py_quote(tolower(image_format)), '  # "png" or "jpeg"'),
	paste0('JPEG_QUALITY = ', as.integer(jpeg_quality)),
	'',
	paste0('KEEP_ALIVE  = ', py_quote(keep_alive)),
	paste0('NUM_PREDICT = ', as.integer(num_predict)),
	paste0('NUM_CTX     = ', as.integer(num_ctx)),
	paste0('TEMPERATURE = ', as.numeric(temperature)),
	paste0('RESUME      = ', resume_py),
	paste0('TIMEOUT_SEC = ', as.integer(timeout_sec)),
	'',
	'def which(cmd: str) -> bool:',
	'    from shutil import which as _which',
	'    return _which(cmd) is not None',
	'',
	'def require_poppler():',
	'    missing = [c for c in ("pdfinfo", "pdftoppm") if not which(c)]',
	'    if missing:',
	'        raise RuntimeError(',
	'            "Missing Poppler tool(s): " + ", ".join(missing) +',
	'            ". Install with: brew install poppler (macOS) and ensure it is on PATH."',
	'        )',
	'',
	'def pdf_page_count(pdf_path: Path) -> int:',
	'    p = subprocess.run(["pdfinfo", str(pdf_path)], capture_output=True, text=True)',
	'    if p.returncode != 0:',
	'        raise RuntimeError(f"pdfinfo failed for {pdf_path.name}: {p.stderr.strip()[:400]}")',
	'    for line in p.stdout.splitlines():',
	'        if line.startswith("Pages:"):',
	'            return int(line.split(":", 1)[1].strip())',
	'    raise RuntimeError(f"Could not parse page count from pdfinfo for {pdf_path.name}")',
	'',
	'def render_page_to_file(pdf_path: Path, page_num: int, out_dir: Path) -> Path:',
	'    stem = pdf_path.stem.replace(os.sep, "_")',
	'    out_prefix = out_dir / f"{stem}_p{page_num:05d}"',
	'',
	'    if IMAGE_FORMAT.lower() == "png":',
	'        args = [',
	'            "pdftoppm", "-png",',
	'            "-r", str(DPI),',
	'            "-f", str(page_num), "-l", str(page_num),',
	'            "-singlefile",',
	'            str(pdf_path),',
	'            str(out_prefix)',
	'        ]',
	'        out_file = out_prefix.with_suffix(".png")',
	'    else:',
	'        args = [',
	'            "pdftoppm", "-jpeg",',
	'            "-jpegopt", f"quality={JPEG_QUALITY}",',
	'            "-r", str(DPI),',
	'            "-f", str(page_num), "-l", str(page_num),',
	'            "-singlefile",',
	'            str(pdf_path),',
	'            str(out_prefix)',
	'        ]',
	'        out_file = out_prefix.with_suffix(".jpg")',
	'',
	'    p = subprocess.run(args, capture_output=True, text=True)',
	'    if p.returncode != 0 or not out_file.exists():',
	'        raise RuntimeError(f"pdftoppm failed on {pdf_path.name} page {page_num}: {p.stderr.strip()[:400]}")',
	'    return out_file',
	'',
	'def bytes_to_b64(b: bytes) -> str:',
	'    return base64.b64encode(b).decode("utf-8")',
	'',
	'def file_to_b64(path: Path) -> str:',
	'    return bytes_to_b64(path.read_bytes())',
	'',
	'def iter_image_b64_pages(img_path: Path):',
	'    suf = img_path.suffix.lower()',
	'',
	'    # Fast path: already in desired format (single-frame)',
	'    if IMAGE_FORMAT.lower() == "png" and suf == ".png":',
	'        yield 1, file_to_b64(img_path)',
	'        return',
	'    if IMAGE_FORMAT.lower() == "jpeg" and suf in (".jpg", ".jpeg"):',
	'        yield 1, file_to_b64(img_path)',
	'        return',
	'',
	'    # General path: open with Pillow, handle multi-frame, and re-encode',
	'    with Image.open(img_path) as im:',
	'        for idx, frame in enumerate(ImageSequence.Iterator(im), start=1):',
	'            fr = frame.copy()',
	'            fr = ImageOps.exif_transpose(fr)',
	'',
	'            buf = BytesIO()',
	'            if IMAGE_FORMAT.lower() == "png":',
	'                if fr.mode not in ("RGB", "L"):',
	'                    fr = fr.convert("RGB")',
	'                fr.save(buf, format="PNG")',
	'            else:',
	'                if fr.mode != "RGB":',
	'                    fr = fr.convert("RGB")',
	'                fr.save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)',
	'',
	'            yield idx, bytes_to_b64(buf.getvalue())',
	'',
	'SESSION = requests.Session()',
	'',
	'def llm_ocr_b64(img_b64: str):',
	'    payload = {',
	'        "model": OLLAMA_MODEL,',
	'        "prompt": PROMPT,',
	'        "images": [img_b64],',
	'        "stream": False,',
	'        "keep_alive": KEEP_ALIVE,',
	'        "options": {',
	'            "temperature": TEMPERATURE,',
	'            "num_predict": NUM_PREDICT,',
	'            "num_ctx": NUM_CTX',
	'        }',
	'    }',
	'    r = SESSION.post(OLLAMA_URL, json=payload, timeout=TIMEOUT_SEC)',
	'    if r.status_code != 200:',
	'        return "", {"error": f"HTTP {r.status_code}: {r.text[:1000]}"}',
	'    j = r.json()',
	'    if j.get("error"):',
	'        return "", j',
	'    return (j.get("response") or "").strip(), j',
	'',
	'def load_done_set(csv_path: Path):',
	'    done = set()',
	'    if not (RESUME and csv_path.exists()):',
	'        return done',
	'    with csv_path.open("r", newline="", encoding="utf-8") as f:',
	'        reader = csv.DictReader(f)',
	'        for row in reader:',
	'            try:',
	'                done.add((row.get("filename",""), int(row.get("page_number","0"))))',
	'            except:',
	'                pass',
	'    return done',
	'',
	'def main():',
	'    INPUT_DIR.mkdir(exist_ok=True)',
	'    OUTPUT_CSV.parent.mkdir(parents=True, exist_ok=True)',
	'',
	'    inputs = sorted([p for p in INPUT_DIR.iterdir() if p.is_file() and not p.name.startswith(".")])',
	'    if not inputs:',
	'        print("No files found in", INPUT_DIR)',
	'        return 0',
	'',
	'    if any(p.suffix.lower() == ".pdf" for p in inputs):',
	'        require_poppler()',
	'',
	'    done = load_done_set(OUTPUT_CSV)',
	'',
	'    write_header = not OUTPUT_CSV.exists()',
	'    fieldnames = [',
	'        "filename","page_number","source_type","llm_model","dpi","image_format",',
	'        "llm_seconds","eval_count","load_duration","eval_duration",',
	'        "llm_ocr_text","error"',
	'    ]',
	'',
	'    tmp_root = Path(tempfile.mkdtemp(prefix="pdfscan_"))',
	'    try:',
	'        with OUTPUT_CSV.open("a", newline="", encoding="utf-8") as f:',
	'            w = csv.DictWriter(f, fieldnames=fieldnames)',
	'            if write_header:',
	'                w.writeheader()',
	'',
	'            for p in inputs:',
	'                suf = p.suffix.lower()',
	'',
	'                if suf == ".pdf":',
	'                    n = pdf_page_count(p)',
	'                    print(f"Processing {p.name} ({n} pages)")',
	'                    for page in range(1, n + 1):',
	'                        if (p.name, page) in done:',
	'                            print(f"  Page {page}/{n} (skip; already in CSV)")',
	'                            continue',
	'',
	'                        t0 = time.time()',
	'                        err = ""',
	'                        txt = ""',
	'                        meta = {}',
	'',
	'                        try:',
	'                            img_path = render_page_to_file(p, page, tmp_root)',
	'                            img_b64 = file_to_b64(img_path)',
	'                            txt, meta = llm_ocr_b64(img_b64)',
	'                        except Exception as e:',
	'                            err = str(e)',
	'',
	'                        dt = time.time() - t0',
	'                        row = {',
	'                            "filename": p.name,',
	'                            "page_number": page,',
	'                            "source_type": "pdf",',
	'                            "llm_model": OLLAMA_MODEL,',
	'                            "dpi": DPI,',
	'                            "image_format": IMAGE_FORMAT,',
	'                            "llm_seconds": round(dt, 3),',
	'                            "eval_count": meta.get("eval_count",""),',
	'                            "load_duration": meta.get("load_duration",""),',
	'                            "eval_duration": meta.get("eval_duration",""),',
	'                            "llm_ocr_text": txt,',
	'                            "error": err or meta.get("error","") or ""',
	'                        }',
	'                        w.writerow(row)',
	'                        f.flush()',
	'',
	'                        if row["error"]:',
	'                            msg = str(row["error"])[:120]',
	'                            print(f"  Page {page}/{n} ERROR: {msg}")',
	'                        else:',
	'                            secs = row["llm_seconds"]',
	'                            print(f"  Page {page}/{n} OK ({len(txt)} chars, {secs}s)")',
	'',
	'                else:',
	'                    print(f"Processing {p.name} (image)")',
	'                    try:',
	'                        for page, img_b64 in iter_image_b64_pages(p):',
	'                            if (p.name, page) in done:',
	'                                print(f"  Frame {page} (skip; already in CSV)")',
	'                                continue',
	'',
	'                            t0 = time.time()',
	'                            err = ""',
	'                            txt = ""',
	'                            meta = {}',
	'',
	'                            try:',
	'                                txt, meta = llm_ocr_b64(img_b64)',
	'                            except Exception as e:',
	'                                err = str(e)',
	'',
	'                            dt = time.time() - t0',
	'                            row = {',
	'                                "filename": p.name,',
	'                                "page_number": page,',
	'                                "source_type": "image",',
	'                                "llm_model": OLLAMA_MODEL,',
	'                                "dpi": "",',
	'                                "image_format": IMAGE_FORMAT,',
	'                                "llm_seconds": round(dt, 3),',
	'                                "eval_count": meta.get("eval_count",""),',
	'                                "load_duration": meta.get("load_duration",""),',
	'                                "eval_duration": meta.get("eval_duration",""),',
	'                                "llm_ocr_text": txt,',
	'                                "error": err or meta.get("error","") or ""',
	'                            }',
	'                            w.writerow(row)',
	'                            f.flush()',
	'',
	'                            if row["error"]:',
	'                                msg = str(row["error"])[:120]',
	'                                print(f"  Frame {page} ERROR: {msg}")',
	'                            else:',
	'                                secs = row["llm_seconds"]',
	'                                print(f"  Frame {page} OK ({len(txt)} chars, {secs}s)")',
	'',
	'                    except Exception as e:',
	'                        row = {',
	'                            "filename": p.name,',
	'                            "page_number": 1,',
	'                            "source_type": "image",',
	'                            "llm_model": OLLAMA_MODEL,',
	'                            "dpi": "",',
	'                            "image_format": IMAGE_FORMAT,',
	'                            "llm_seconds": "",',
	'                            "eval_count": "",',
	'                            "load_duration": "",',
	'                            "eval_duration": "",',
	'                            "llm_ocr_text": "",',
	'                            "error": f"Could not open image: {e}"',
	'                        }',
	'                        w.writerow(row)',
	'                        f.flush()',
	'                        print(f"  ERROR: Could not open image: {str(e)[:200]}")',
	'',
	'        print("Wrote", OUTPUT_CSV)',
	'        return 0',
	'    finally:',
	'        shutil.rmtree(tmp_root, ignore_errors=True)',
	'',
	'if __name__ == "__main__":',
	'    raise SystemExit(main())'
)

writeLines(py_lines, py_file, useBytes = TRUE)

# 4) Run the generated Python script
cat("\nRunning generated Python OCR script...\n")
status <- system2(py, c(py_file))
if (status != 0) stop("Python script failed (exit status ", status, ").")

# 5) Load results
if (file.exists(output_csv)) {
	cat("\nDone. Output CSV:", output_csv, "\n")
	results <- read.csv(output_csv)
	print(head(results, 3))
} else {
	stop("No CSV produced. Check the messages above for the cause.")
}

#### PART 3: Combine results ####

args <- commandArgs(trailingOnly = TRUE)

output_dir <- "outputs"

llm_csv  <- if (length(args) >= 1) args[[1]] else file.path(output_dir, "llm_output.csv")
tess_csv <- if (length(args) >= 2) args[[2]] else file.path(output_dir, "tesseract_output.csv")
out_rds  <- if (length(args) >= 3) args[[3]] else file.path(output_dir, "combined_ocr.rds")

dir.create(dirname(out_rds), showWarnings = FALSE, recursive = TRUE)

if (!file.exists(llm_csv))  stop("LLM CSV not found: ", llm_csv)
if (!file.exists(tess_csv)) stop("Tesseract CSV not found: ", tess_csv)

detect_header_skip <- function(path) {
	lines <- readLines(path, n = 300, warn = FALSE)
	idx <- which(
		grepl("^\\s*filename\\s*,\\s*page_number\\b", lines, ignore.case = TRUE) |
			grepl("^\\s*pdf_file\\s*,\\s*page\\b", lines, ignore.case = TRUE) |
			grepl("^\\s*filename\\s*,\\s*page\\b", lines, ignore.case = TRUE)
	)[1]
	
	if (is.na(idx)) return(0L)
	as.integer(idx - 1L) 
}

read_csv_robust <- function(path) {
	skip_n <- detect_header_skip(path)
	
	if (requireNamespace("data.table", quietly = TRUE)) {
		df <- try(
			data.table::fread(
				path,
				sep = ",",
				quote = "\"",
				fill = TRUE,
				skip = skip_n,
				na.strings = c("", "NA"),
				showProgress = FALSE,
				encoding = "UTF-8",
				data.table = FALSE
			),
			silent = TRUE
		)
		if (!inherits(df, "try-error")) return(df)
	}
	
	# Fallback: base R
	read.csv(
		path,
		sep = ",",
		quote = "\"",
		fill = TRUE,
		skip = skip_n,
		stringsAsFactors = FALSE,
		na.strings = c("", "NA"),
		check.names = FALSE,
		fileEncoding = "UTF-8"
	)
}

stop_with_preview <- function(path, label) {
	preview <- readLines(path, n = 20, warn = FALSE)
	preview <- paste(sprintf("%02d: %s", seq_along(preview), preview), collapse = "\n")
	stop(
		"\n", label, " does not look like a valid CSV produced by textextract.\n",
		"File: ", path, "\n\n",
		"First lines:\n", preview, "\n\n",
		"Common causes:\n",
		"  - The CSV was opened/resaved by Excel/Numbers (can corrupt quoting/encoding)\n",
		"  - A non-CSV file was written to this path by mistake\n",
		"  - The OCR text contains commas/newlines but the file isn’t properly quoted\n\n",
		"Fix:\n",
		"  1) Delete the file and rerun the producing step (Tesseract/LLM)\n",
		"  2) Avoid resaving as CSV from spreadsheet apps; treat as machine output\n",
		call. = FALSE
	)
}

standardize <- function(df, source_label) {
	nms <- names(df)
	if (!("filename" %in% nms)) {
		if ("pdf_file" %in% nms) names(df)[names(df) == "pdf_file"] <- "filename"
		if ("file" %in% nms)     names(df)[names(df) == "file"] <- "filename"
	}
	nms <- names(df)
	if (!("page_number" %in% nms)) {
		if ("page" %in% nms) names(df)[names(df) == "page"] <- "page_number"
	}
	if (!("filename" %in% names(df)) || !("page_number" %in% names(df))) {
		stop("MISSING_KEYS")
	}
	
	df$filename <- as.character(df$filename)
	df$page_number <- suppressWarnings(as.integer(df$page_number))
	
	if (source_label == "llm") {
		if ("llm_ocr_text" %in% names(df)) names(df)[names(df) == "llm_ocr_text"] <- "llm_text"
		if (!("llm_text" %in% names(df)) && "text" %in% names(df)) names(df)[names(df) == "text"] <- "llm_text"
	}
	
	if (source_label == "tesseract") {
		if ("tesseract_ocr_text" %in% names(df)) names(df)[names(df) == "tesseract_ocr_text"] <- "tesseract_text"
		if (!("tesseract_text" %in% names(df)) && "ocr_text" %in% names(df)) names(df)[names(df) == "ocr_text"] <- "tesseract_text"
		if (!("tesseract_text" %in% names(df)) && "text" %in% names(df)) names(df)[names(df) == "text"] <- "tesseract_text"
	}
	
	df
}

dedupe_keep_last <- function(df, label) {
	if (nrow(df) == 0) return(df)
	key <- paste(df$filename, df$page_number, sep = "\r")
	dup_count <- sum(duplicated(key))
	if (dup_count > 0) {
		message("WARNING: ", label, " has ", dup_count,
						" duplicate rows by (filename, page_number). Keeping last occurrence.")
		df <- df[!duplicated(key, fromLast = TRUE), , drop = FALSE]
	}
	df
}

message("Reading: ", llm_csv)
llm <- read_csv_robust(llm_csv)

message("Reading: ", tess_csv)
tess <- read_csv_robust(tess_csv)

llm <- tryCatch(
	standardize(llm, "llm"),
	error = function(e) {
		if (identical(conditionMessage(e), "MISSING_KEYS")) stop_with_preview(llm_csv, "LLM file")
		stop(e)
	}
)

tess <- tryCatch(
	standardize(tess, "tesseract"),
	error = function(e) {
		if (identical(conditionMessage(e), "MISSING_KEYS")) stop_with_preview(tess_csv, "Tesseract file")
		stop(e)
	}
)

llm  <- dedupe_keep_last(llm, "llm")
tess <- dedupe_keep_last(tess, "tesseract")

message("Merging...")
combined <- merge(
	llm, tess,
	by = c("filename", "page_number"),
	all = TRUE,
	suffixes = c("_llm", "_tesseract")
)

message("Rows: ", nrow(combined))

saveRDS(combined, out_rds, compress = "xz")
message("Wrote: ", out_rds)
message("Done.")