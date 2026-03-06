from pathlib import Path
import base64, csv, os, shutil, subprocess, tempfile, time
from io import BytesIO

import requests
from PIL import Image, ImageSequence, ImageOps

# This script lives in: PROJECT_ROOT/pythonscript/llm_script.py
PROJECT_ROOT = Path(__file__).resolve().parents[1]
INPUT_DIR    = PROJECT_ROOT / 'inputs'
OUTPUT_CSV   = PROJECT_ROOT / 'outputs/llm_output.csv'

OLLAMA_URL   = 'http://localhost:11434/api/generate'
OLLAMA_MODEL = 'qwen3-vl:8b'
PROMPT = """
Extract all text from this image exactly as it appears.
Transcribe all visible text in reading order, preserving line breaks.
Do not interpret, summarize, or add anything.
"""

DPI = 150
IMAGE_FORMAT = 'png'  # "png" or "jpeg"
JPEG_QUALITY = 90

KEEP_ALIVE  = '30m'
NUM_PREDICT = 4096
NUM_CTX     = 8192
TEMPERATURE = 0
RESUME      = True
TIMEOUT_SEC = 600

def which(cmd: str) -> bool:
    from shutil import which as _which
    return _which(cmd) is not None

def require_poppler():
    missing = [c for c in ("pdfinfo", "pdftoppm") if not which(c)]
    if missing:
        raise RuntimeError(
            "Missing Poppler tool(s): " + ", ".join(missing) +
            ". Install with: brew install poppler (macOS) and ensure it is on PATH."
        )

def pdf_page_count(pdf_path: Path) -> int:
    p = subprocess.run(["pdfinfo", str(pdf_path)], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"pdfinfo failed for {pdf_path.name}: {p.stderr.strip()[:400]}")
    for line in p.stdout.splitlines():
        if line.startswith("Pages:"):
            return int(line.split(":", 1)[1].strip())
    raise RuntimeError(f"Could not parse page count from pdfinfo for {pdf_path.name}")

def render_page_to_file(pdf_path: Path, page_num: int, out_dir: Path) -> Path:
    stem = pdf_path.stem.replace(os.sep, "_")
    out_prefix = out_dir / f"{stem}_p{page_num:05d}"

    if IMAGE_FORMAT.lower() == "png":
        args = [
            "pdftoppm", "-png",
            "-r", str(DPI),
            "-f", str(page_num), "-l", str(page_num),
            "-singlefile",
            str(pdf_path),
            str(out_prefix)
        ]
        out_file = out_prefix.with_suffix(".png")
    else:
        args = [
            "pdftoppm", "-jpeg",
            "-jpegopt", f"quality={JPEG_QUALITY}",
            "-r", str(DPI),
            "-f", str(page_num), "-l", str(page_num),
            "-singlefile",
            str(pdf_path),
            str(out_prefix)
        ]
        out_file = out_prefix.with_suffix(".jpg")

    p = subprocess.run(args, capture_output=True, text=True)
    if p.returncode != 0 or not out_file.exists():
        raise RuntimeError(f"pdftoppm failed on {pdf_path.name} page {page_num}: {p.stderr.strip()[:400]}")
    return out_file

def bytes_to_b64(b: bytes) -> str:
    return base64.b64encode(b).decode("utf-8")

def file_to_b64(path: Path) -> str:
    return bytes_to_b64(path.read_bytes())

def iter_image_b64_pages(img_path: Path):
    suf = img_path.suffix.lower()

    # Fast path: already in desired format (single-frame)
    if IMAGE_FORMAT.lower() == "png" and suf == ".png":
        yield 1, file_to_b64(img_path)
        return
    if IMAGE_FORMAT.lower() == "jpeg" and suf in (".jpg", ".jpeg"):
        yield 1, file_to_b64(img_path)
        return

    # General path: open with Pillow, handle multi-frame, and re-encode
    with Image.open(img_path) as im:
        for idx, frame in enumerate(ImageSequence.Iterator(im), start=1):
            fr = frame.copy()
            fr = ImageOps.exif_transpose(fr)

            buf = BytesIO()
            if IMAGE_FORMAT.lower() == "png":
                if fr.mode not in ("RGB", "L"):
                    fr = fr.convert("RGB")
                fr.save(buf, format="PNG")
            else:
                if fr.mode != "RGB":
                    fr = fr.convert("RGB")
                fr.save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)

            yield idx, bytes_to_b64(buf.getvalue())

SESSION = requests.Session()

def llm_ocr_b64(img_b64: str):
    payload = {
        "model": OLLAMA_MODEL,
        "prompt": PROMPT,
        "images": [img_b64],
        "stream": False,
        "keep_alive": KEEP_ALIVE,
        "options": {
            "temperature": TEMPERATURE,
            "num_predict": NUM_PREDICT,
            "num_ctx": NUM_CTX
        }
    }
    r = SESSION.post(OLLAMA_URL, json=payload, timeout=TIMEOUT_SEC)
    if r.status_code != 200:
        return "", {"error": f"HTTP {r.status_code}: {r.text[:1000]}"}
    j = r.json()
    if j.get("error"):
        return "", j
    return (j.get("response") or "").strip(), j

def load_done_set(csv_path: Path):
    done = set()
    if not (RESUME and csv_path.exists()):
        return done
    with csv_path.open("r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                done.add((row.get("filename",""), int(row.get("page_number","0"))))
            except:
                pass
    return done

def main():
    INPUT_DIR.mkdir(exist_ok=True)
    OUTPUT_CSV.parent.mkdir(parents=True, exist_ok=True)

    inputs = sorted([p for p in INPUT_DIR.iterdir() if p.is_file() and not p.name.startswith(".")])
    if not inputs:
        print("No files found in", INPUT_DIR)
        return 0

    if any(p.suffix.lower() == ".pdf" for p in inputs):
        require_poppler()

    done = load_done_set(OUTPUT_CSV)

    write_header = not OUTPUT_CSV.exists()
    fieldnames = [
        "filename","page_number","source_type","llm_model","dpi","image_format",
        "llm_seconds","eval_count","load_duration","eval_duration",
        "llm_ocr_text","error"
    ]

    tmp_root = Path(tempfile.mkdtemp(prefix="pdfscan_"))
    try:
        with OUTPUT_CSV.open("a", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=fieldnames)
            if write_header:
                w.writeheader()

            for p in inputs:
                suf = p.suffix.lower()

                if suf == ".pdf":
                    n = pdf_page_count(p)
                    print(f"Processing {p.name} ({n} pages)")
                    for page in range(1, n + 1):
                        if (p.name, page) in done:
                            print(f"  Page {page}/{n} (skip; already in CSV)")
                            continue

                        t0 = time.time()
                        err = ""
                        txt = ""
                        meta = {}

                        try:
                            img_path = render_page_to_file(p, page, tmp_root)
                            img_b64 = file_to_b64(img_path)
                            txt, meta = llm_ocr_b64(img_b64)
                        except Exception as e:
                            err = str(e)

                        dt = time.time() - t0
                        row = {
                            "filename": p.name,
                            "page_number": page,
                            "source_type": "pdf",
                            "llm_model": OLLAMA_MODEL,
                            "dpi": DPI,
                            "image_format": IMAGE_FORMAT,
                            "llm_seconds": round(dt, 3),
                            "eval_count": meta.get("eval_count",""),
                            "load_duration": meta.get("load_duration",""),
                            "eval_duration": meta.get("eval_duration",""),
                            "llm_ocr_text": txt,
                            "error": err or meta.get("error","") or ""
                        }
                        w.writerow(row)
                        f.flush()

                        if row["error"]:
                            msg = str(row["error"])[:120]
                            print(f"  Page {page}/{n} ERROR: {msg}")
                        else:
                            secs = row["llm_seconds"]
                            print(f"  Page {page}/{n} OK ({len(txt)} chars, {secs}s)")

                else:
                    print(f"Processing {p.name} (image)")
                    try:
                        for page, img_b64 in iter_image_b64_pages(p):
                            if (p.name, page) in done:
                                print(f"  Frame {page} (skip; already in CSV)")
                                continue

                            t0 = time.time()
                            err = ""
                            txt = ""
                            meta = {}

                            try:
                                txt, meta = llm_ocr_b64(img_b64)
                            except Exception as e:
                                err = str(e)

                            dt = time.time() - t0
                            row = {
                                "filename": p.name,
                                "page_number": page,
                                "source_type": "image",
                                "llm_model": OLLAMA_MODEL,
                                "dpi": "",
                                "image_format": IMAGE_FORMAT,
                                "llm_seconds": round(dt, 3),
                                "eval_count": meta.get("eval_count",""),
                                "load_duration": meta.get("load_duration",""),
                                "eval_duration": meta.get("eval_duration",""),
                                "llm_ocr_text": txt,
                                "error": err or meta.get("error","") or ""
                            }
                            w.writerow(row)
                            f.flush()

                            if row["error"]:
                                msg = str(row["error"])[:120]
                                print(f"  Frame {page} ERROR: {msg}")
                            else:
                                secs = row["llm_seconds"]
                                print(f"  Frame {page} OK ({len(txt)} chars, {secs}s)")

                    except Exception as e:
                        row = {
                            "filename": p.name,
                            "page_number": 1,
                            "source_type": "image",
                            "llm_model": OLLAMA_MODEL,
                            "dpi": "",
                            "image_format": IMAGE_FORMAT,
                            "llm_seconds": "",
                            "eval_count": "",
                            "load_duration": "",
                            "eval_duration": "",
                            "llm_ocr_text": "",
                            "error": f"Could not open image: {e}"
                        }
                        w.writerow(row)
                        f.flush()
                        print(f"  ERROR: Could not open image: {str(e)[:200]}")

        print("Wrote", OUTPUT_CSV)
        return 0
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)

if __name__ == "__main__":
    raise SystemExit(main())
