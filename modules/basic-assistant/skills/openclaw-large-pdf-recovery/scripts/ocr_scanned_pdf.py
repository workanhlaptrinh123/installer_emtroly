#!/usr/bin/env python3
"""Render a scanned PDF and extract searchable text with Tesseract."""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path


def run(command: list[str]) -> None:
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)


def page_count(pdf_path: Path) -> int:
    result = subprocess.run(
        ["pdfinfo", str(pdf_path)], check=True, capture_output=True, text=True
    )
    for line in result.stdout.splitlines():
        if line.startswith("Pages:"):
            return int(line.split(":", 1)[1].strip())
    raise RuntimeError("Khong xac dinh duoc so trang PDF")


def page_ranges(value: str, total_pages: int) -> list[tuple[int, int]]:
    ranges = []
    for part in value.split(","):
        bounds = part.strip().split("-", 1)
        start = int(bounds[0])
        end = int(bounds[-1])
        if start < 1 or end < start or end > total_pages:
            raise SystemExit("--pages nam ngoai pham vi PDF")
        ranges.append((start, end))
    return ranges


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--lang", default="vie+eng")
    parser.add_argument("--dpi", type=int, default=300)
    parser.add_argument("--pages", default="", help="Khoang trang, vi du 1-5 hoac 1,3,7")
    args = parser.parse_args()

    if not args.input.is_file() or args.input.stat().st_size < 5:
        raise SystemExit("PDF dau vao khong ton tai hoac qua nho")
    if args.dpi < 150 or args.dpi > 600:
        raise SystemExit("--dpi phai nam trong khoang 150..600")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    total_pages = page_count(args.input)
    page_range = args.pages or f"1-{total_pages}"
    ranges = page_ranges(page_range, total_pages)
    output_text = args.output_dir / "ocr.txt"
    manifest = {
        "source_name": args.input.name,
        "pages": total_pages,
        "page_range": page_range,
        "language": args.lang,
        "dpi": args.dpi,
        "pages_with_text": 0,
        "warnings": [],
    }

    with tempfile.TemporaryDirectory(prefix="pdf-ocr-", dir=args.output_dir) as temp_name:
        temp_dir = Path(temp_name)
        for index, (start, end) in enumerate(ranges):
            prefix = temp_dir / f"range-{index:03d}-page"
            run(["pdftoppm", "-f", str(start), "-l", str(end), "-r", str(args.dpi), "-png", str(args.input), str(prefix)])
        pages = sorted(temp_dir.glob("range-*-page-*.png"))
        with output_text.open("w", encoding="utf-8") as text_file:
            for image in pages:
                result = subprocess.run(
                    ["tesseract", str(image), "stdout", "-l", args.lang, "--psm", "3"],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                page_text = result.stdout.strip()
                if page_text:
                    manifest["pages_with_text"] += 1
                text_file.write(f"\n--- {image.stem} ---\n{page_text}\n")

    if not manifest["pages_with_text"]:
        manifest["warnings"].append("OCR khong nhan duoc chu ro; can kiem tra anh trang bang vision")
    (args.output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(manifest, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
