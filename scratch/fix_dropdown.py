import os

file_path = r"c:\Users\34331\shiroha_quiz\lib\ui\pages\ai_settings_screen.dart"

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

# Target 1
target1 = '''    final cardBgColor = isDark ? (theme.cardTheme.color ?? theme.cardColor) : Colors.blue.shade50.withOpacity(0.3);
    final borderColor = isDark ? Colors.white.withOpacity(0.1) : Colors.blue.shade100;
    
    return Scaffold('''

replacement1 = '''    final cardBgColor = isDark ? (theme.cardTheme.color ?? theme.cardColor) : Colors.blue.shade50.withOpacity(0.3);
    final borderColor = isDark ? Colors.white.withOpacity(0.1) : Colors.blue.shade100;

    // 核心热修复：绝对防御 DropdownButton 幽灵选项崩溃
    // 检查当前 ID 是否真实存在于列表中，如果不存在则强制置空
    final safeTextId = _textEngines.any((e) => e['id'] == _currentTextId) ? _currentTextId : null;
    final safeVisionId = _visionEngines.any((e) => e['id'] == _currentVisionId) ? _currentVisionId : null;
    
    return Scaffold('''

# Target 2
target2 = '''                        hint: const Text('选择/新建...', style: TextStyle(fontSize: 13)),
                        value: _currentTextId,'''

replacement2 = '''                        hint: const Text('选择/新建...', style: TextStyle(fontSize: 13)),
                        value: safeTextId,'''

# Target 3
target3 = '''                        hint: const Text('选择/新建...', style: TextStyle(fontSize: 13)),
                        value: _currentVisionId,'''

replacement3 = '''                        hint: const Text('选择/新建...', style: TextStyle(fontSize: 13)),
                        value: safeVisionId,'''

if target1 in content and target2 in content and target3 in content:
    content = content.replace(target1, replacement1)
    content = content.replace(target2, replacement2)
    content = content.replace(target3, replacement3)
    
    with open(file_path, "w", encoding="utf-8") as f:
        f.write(content)
    print("Success: Applied all fixes.")
else:
    print("Error: Target strings not found.")
    print("Target1 found:", target1 in content)
    print("Target2 found:", target2 in content)
    print("Target3 found:", target3 in content)
