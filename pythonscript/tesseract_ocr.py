from pathlib import Path
from io import BytesIO

import fitz  # PyMuPDF
import pytesseract
import pandas as pd
from PIL import Image, ImageSequence, ImageOps

PROJECT_ROOT = Path(__file__).resolve().parents[1]
INPUT_DIR = PROJECT_ROOT / "inputs"
OUTPUT_DIR = PROJECT_ROOT / "outputs"
OUTPUT_CSV = OUTPUT_DIR / "tesseract_output.csv"

# Rendering resolution for OCR when a PDF page has no embedded text
OCR_DPI = 300  # common sweet spot for Tesseract on scanned pages

def ocr_pil_image(img: Image.Image) -> str:
    # Correct EXIF rotation if present (important for phone images)
    img = ImageOps.exif_transpose(img)

    # Tesseract generally does well with RGB; you can also try grayscale if needed
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")

    return pytesseract.image_to_string(img)

def process_pdf(pdf_path: Path):
    results = []
    zoom = OCR_DPI / 72.0
    matrix = fitz.Matrix(zoom, zoom)

    with fitz.open(pdf_path) as doc:
        for i in range(len(doc)):
            page_number = i + 1
            page = doc[i]

            embedded = (page.get_text("text") or "").strip()
            if embedded:
                results.append({
                    "filename": pdf_path.name,
                    "page_number": page_number,
                    "source_type": "pdf",
                    "extraction_method": "PDF_embedded",
                    "tesseract_ocr_text": "",
                    "embedded_text": embedded,
                    "error": ""
                })
                continue

            # No embedded text => render page to an image and OCR it
            try:
                pix = page.get_pixmap(matrix=matrix, alpha=False)
                img = Image.open(BytesIO(pix.tobytes("png")))
                ocr_text = ocr_pil_image(img)

                results.append({
                    "filename": pdf_path.name,
                    "page_number": page_number,
                    "source_type": "pdf",
                    "extraction_method": "Tesseract_OCR",
                    "tesseract_ocr_text": ocr_text,
                    "embedded_text": "",
                    "error": ""
                })
            except Exception as e:
                results.append({
                    "filename": pdf_path.name,
                    "page_number": page_number,
                    "source_type": "pdf",
                    "extraction_method": "Tesseract_OCR",
                    "tesseract_ocr_text": "",
                    "embedded_text": "",
                    "error": str(e)
                })

    return results


def process_image_file(img_path: Path):
    results = []
    # Treat an image file like a “single document”; multi-frame images => multiple pages
    try:
        with Image.open(img_path) as im:
            # Iterate frames if present (TIFF/GIF); otherwise this yields one frame
            for idx, frame in enumerate(ImageSequence.Iterator(im), start=1):
                try:
                    # copy() so each frame is independent of the underlying file pointer
                    frame_copy = frame.copy()
                    ocr_text = ocr_pil_image(frame_copy)

                    results.append({
                        "filename": img_path.name,
                        "page_number": idx,
                        "source_type": "image",
                        "extraction_method": "Tesseract_OCR",
                        "tesseract_ocr_text": ocr_text,
                        "embedded_text": "",
                        "error": ""
                    })
                except Exception as e:
                    results.append({
                        "filename": img_path.name,
                        "page_number": idx,
                        "source_type": "image",
                        "extraction_method": "Tesseract_OCR",
                        "tesseract_ocr_text": "",
                        "embedded_text": "",
                        "error": str(e)
                    })
    except Exception as e:
        # Could not open as an image
        results.append({
            "filename": img_path.name,
            "page_number": 1,
            "source_type": "image",
            "extraction_method": "Tesseract_OCR",
            "tesseract_ocr_text": "",
            "embedded_text": "",
            "error": f"Could not open image: {e}"
        })

    return results


def main():
    INPUT_DIR.mkdir(exist_ok=True)
    OUTPUT_DIR.mkdir(exist_ok=True)

    input_files = sorted([p for p in INPUT_DIR.iterdir() if p.is_file() and not p.name.startswith(".")])

    if not input_files:
        print(f"No files found in '{INPUT_DIR}'. Put PDFs/images there and re-run.")
        return

    all_results = []

    for path in input_files:
        suf = path.suffix.lower()

        if suf == ".pdf":
            print(f"Processing PDF '{path.name}' ...")
            all_results.extend(process_pdf(path))
        else:
            # Try to treat anything else as an image Pillow can open (jpg/png/tif/tiff/webp/bmp/gif/etc.)
            print(f"Processing image '{path.name}' ...")
            all_results.extend(process_image_file(path))

    df = pd.DataFrame(all_results)
    df.to_csv(OUTPUT_CSV, index=False)
    print(f"Wrote: '{OUTPUT_CSV}'")


if __name__ == "__main__":
    main()