import fitz

def check_pdf(file_path):
    doc = fitz.open(file_path)
    total_images = 0
    total_text = 0
    for page in doc:
        total_text += len(page.get_text().strip())
        total_images += len(page.get_images(full=True))
    
    print(f"Total characters of text: {total_text}")
    print(f"Total images: {total_images}")

if __name__ == "__main__":
    check_pdf(r"C:\Users\34331\Downloads\2022数学一解析.pdf")
