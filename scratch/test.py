import re
# If AI outputs two backslashes:
s1 = r"\\lim" # correct json
s2 = r"\lim"  # single backslash

regex = r'(?<!\\)\\([^"\\/bfnrt])'
print("Using negative lookbehind:")
print(f"Original: {s1} -> Replaced: {re.sub(regex, r'\\\\\1', s1)}")
print(f"Original: {s2} -> Replaced: {re.sub(regex, r'\\\\\1', s2)}")
