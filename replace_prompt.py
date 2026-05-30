import sys

with open('lib/services/ai_service.dart', 'r', encoding='utf-8') as f:
    content = f.read()

content = content.replace('"content": "..."', '"content": "真实的题干内容", "options": ["A", "B"], "standard_answer": "完整的答案", "explanation": "完整的解析"')
content = content.replace('格式如：`{"questions": [ {"q_num": "1", "type": 0, "content": "真实的题干内容", "options": ["A", "B"], "standard_answer": "完整的答案", "explanation": "完整的解析"} ]}`。', '格式如：`{"questions": [ {"q_num": "1", "type": 0, "content": "真实的题干内容", "options": ["A", "B"], "standard_answer": "完整的答案", "explanation": "完整的解析"} ]}`。绝对禁止先输出 JSON 模板骨架然后再用普通文本解释！你生成的整个回复必须是唯一一个完整的、包含所有数据的巨大 JSON 字符串！')
content = content.replace('用 $...$ 包裹', '用 $[数学公式]$ 包裹')
content = content.replace('使用 $...$ 包裹', '使用 $[数学公式]$ 包裹')
content = content.replace('\"...\" 或', '省略号或')
content = content.replace('`[...]` 这样的字面量省略号', '缩写或骨架模板')
content = content.replace('`[...]` 这样的省略号', '省略号')

with open('lib/services/ai_service.dart', 'w', encoding='utf-8') as f:
    f.write(content)
print('Done!')
