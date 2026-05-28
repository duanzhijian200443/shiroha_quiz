import os

files = [
    r"c:\Users\34331\shiroha_quiz\lib\ui\pages\practice_page.dart",
    r"c:\Users\34331\shiroha_quiz\lib\ui\pages\question_list_screen.dart"
]

for file_path in files:
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    # fix string literals back
    content = content.replace("replaceAll('\\\\$', '');", "replaceAll('\\$', '');")
    content = content.replace("'\\\\$${mathText}\\\\$'", "'\\$${mathText}\\$'")
    
    with open(file_path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"Fixed {file_path}")
