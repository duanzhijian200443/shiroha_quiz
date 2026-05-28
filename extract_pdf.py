import fitz

pdf_path = r"C:\Users\34331\Downloads\Linear Algebra and Learning from Data (Gilbert Strang) (Z-Library).pdf"
doc = fitz.open(pdf_path)

with open("toc_output.txt", "w", encoding="utf-8") as f:
    for i in range(15):
        page = doc[i]
        text = page.get_text()
        if "Contents" in text or "Chapter" in text or "Part " in text:
            f.write(f"--- Page {i + 1} ---\n")
            lines = text.split('\n')
            for line in lines:
                if line.strip():
                    f.write(line.strip() + "\n")
