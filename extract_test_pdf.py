import fitz
import os

pdf_path = r"C:\Users\34331\Downloads\01_Part_I_Highlights_of_Linear_Algebra.pdf"
output_path = r"C:\Users\34331\Downloads\test.pdf"

try:
    doc = fitz.open(pdf_path)
    new_doc = fitz.open()
    
    # 提取前 10 页 (页码索引为 0 到 9)
    end_page = min(9, len(doc) - 1)
    new_doc.insert_pdf(doc, from_page=0, to_page=end_page)
    
    new_doc.save(output_path)
    new_doc.close()
    doc.close()
    print(f"Successfully extracted {end_page + 1} pages and saved as test.pdf.")
except Exception as e:
    print(f"Error: {e}")
