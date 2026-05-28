import os

file_path = r"c:\Users\34331\shiroha_quiz\lib\services\ai_service.dart"

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

target = '{"type": "file", "file_url": {"url": fileId}}'
replacement = '{"type": "file_id", "file_id": fileId}'

if target in content:
    new_content = content.replace(target, replacement)
    with open(file_path, "w", encoding="utf-8") as f:
        f.write(new_content)
    print("Success: Replaced target payload.")
else:
    print("Error: Target not found.")
