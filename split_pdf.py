import fitz
import os

pdf_path = r"C:\Users\34331\Downloads\Linear Algebra and Learning from Data (Gilbert Strang) (Z-Library).pdf"
output_dir = r"C:\Users\34331\Downloads"

# Define the parts with their 1-indexed start and end pages
parts = [
    ("00_Front_Matter", 1, 14),
    ("01_Part_I_Highlights_of_Linear_Algebra", 15, 126),
    ("02_Part_II_Computations_with_Large_Matrices", 127, 172),
    ("03_Part_III_Low_Rank_and_Compressed_Sensing", 173, 216),
    ("04_Part_IV_Special_Matrices", 217, 270),
    ("05_Part_V_Probability_and_Statistics", 271, 334),
    ("06_Part_VI_Optimization", 335, 384),
    ("07_Part_VII_Learning_from_Data", 385, 448)
]

print("Starting to split the PDF...")
try:
    doc = fitz.open(pdf_path)

    for title, start_page, end_page in parts:
        new_doc = fitz.open()
        # insert_pdf uses 0-indexed page numbers
        new_doc.insert_pdf(doc, from_page=start_page-1, to_page=end_page-1)
        
        output_filename = f"{title}.pdf"
        output_path = os.path.join(output_dir, output_filename)
        new_doc.save(output_path)
        new_doc.close()
        print(f"Successfully saved: {output_filename} (Pages {start_page} to {end_page})")

    doc.close()
    print("All parts have been successfully extracted and saved!")
except Exception as e:
    print(f"An error occurred: {e}")
