import fitz  # PyMuPDF
import sys

def read_pdf(file_path):
    try:
        doc = fitz.open(file_path)
        text = ""
        for i, page in enumerate(doc):
            text += f"--- Page {i+1} ---\n"
            text += page.get_text()
            text += "\n"
        print(text)
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    read_pdf(r"C:\Users\34331\Downloads\2022数学一解析.pdf")
