import fitz  # PyMuPDF
import sys

pdf_path = r"C:\Users\34331\Downloads\2022数学一解析.pdf"
doc = fitz.open(pdf_path)

print(f"Total pages: {len(doc)}")
for page_num in range(len(doc)):
    page = doc[page_num]
    text = page.get_text()
    if "微分方程" in text:
        print(f"Page {page_num + 1} contains '微分方程'")
    if "渐近线" in text:
        print(f"Page {page_num + 1} contains '渐近线'")

doc.close()
