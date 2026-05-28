import 'package:markdown/markdown.dart' as md;
import 'lib/utils/ai_data_sanitizer.dart';

class LatexInlineSyntax extends md.InlineSyntax {
  LatexInlineSyntax() : super(r'\$(?!\$)([^$\n]+?)\$(?!\$)');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final tex = match.group(1)!;
    final element = md.Element('latex', [md.Text(tex)]);
    parser.addNode(element);
    return true;
  }
}

class LatexBlockSyntax extends md.BlockSyntax {
  static final RegExp _pattern = RegExp(r'^\$\$');
  static final RegExp _singleLine = RegExp(r'^\$\$(.+?)\$\$\s*$');

  @override
  RegExp get pattern => _pattern;

  @override
  bool canEndBlock(md.BlockParser parser) => false;

  @override
  bool canParse(md.BlockParser parser) {
    return _pattern.hasMatch(parser.current.content);
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final firstLine = parser.current.content;
    print("BlockSyntax parsing firstLine: $firstLine");

    final singleMatch = _singleLine.firstMatch(firstLine);
    if (singleMatch != null) {
      print("BlockSyntax: Single line matched!");
      parser.advance();
      final el = md.Element.text('latex', singleMatch[1]!);
      el.attributes['MathStyle'] = 'display';
      return md.Element('p', [el]);
    }

    final StringBuffer buffer = StringBuffer();
    final openContent = firstLine.substring(2).trim();
    if (openContent.isNotEmpty) buffer.write(openContent);
    parser.advance();

    while (!parser.isDone) {
      final line = parser.current.content;
      print("BlockSyntax multi-line reading: $line");
      if (line.trim() == r'$$' || (line.trim().endsWith(r'$$') && line.trim().length > 2)) {
        final closeIdx = line.lastIndexOf(r'$$');
        final trailing = line.substring(0, closeIdx).trim();
        if (trailing.isNotEmpty) {
          if (buffer.isNotEmpty) buffer.write('\n');
          buffer.write(trailing);
        }
        parser.advance();
        break;
      } else {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(line);
        parser.advance();
      }
    }

    print("BlockSyntax: Multi-line matched! Content: ${buffer.toString()}");
    final el = md.Element.text('latex', buffer.toString());
    el.attributes['MathStyle'] = 'display';
    return md.Element('p', [el]);
  }
}

class TestSanitizer {
  static String formatLatex(String text) {
    if (text.isEmpty) return text;
    String result = text;

    // 0. 把公式内结尾的连续下划线移出公式，解决填空题下划线破坏 Markdown 加粗渲染的问题
    // 兼容闭合 $ 丢失的情况
    result = result.replaceAllMapped(RegExp(r'\$([^\$]+?)(_{2,}[^a-zA-Z\u4e00-\u9fa5$]*\$?)'), (match) {
        String mathPart = match.group(1)!;
        String underscorePart = match.group(2)!;
        if (underscorePart.endsWith(r'$')) {
            underscorePart = underscorePart.substring(0, underscorePart.length - 1);
        }
        return '\$$mathPart\$$underscorePart';
    });

    result = result.replaceAllMapped(RegExp(r'\\\\([a-zA-Z{(}\[\]|])'), (match) {
      return r'\' + match.group(1)!;
    });
    
    result = result.replaceAllMapped(RegExp(r'\\\((.*?)\\\)'), (match) => '\$${match.group(1)}\$');
    result = result.replaceAllMapped(RegExp(r'\\\[(.*?)\\\]'), (match) => '\$\$${match.group(1)}\$\$');

    result = result.replaceAllMapped(RegExp(r'`(\$+[^`]+?\$+)`'), (match) => match.group(1)!);
    result = result.replaceAllMapped(RegExp(r'```(?:math|latex|tex)?\s*([\s\S]+?)\s*```'), (match) {
        String inner = match.group(1)!.trim();
        if (inner.startsWith(r'$') && inner.endsWith(r'$')) {
            return '\n\n$inner\n\n';
        }
        return '\n\n\$\$$inner\$\$\n\n';
    });

    result = result.replaceAllMapped(RegExp(r'\$+(!\[.*?\]\(.*?\))\$+'), (match) => match.group(1)!);

    result = result.replaceAllMapped(RegExp(r'([^\u4e00-\u9fa5，。、！？：；（）\n]+)'), (match) {
        String segment = match.group(1)!;
        if (segment.contains('![')) return segment;
        if (segment.contains(r'$')) return segment;
        String segmentNoUrl = segment.replaceAll(RegExp(r'https?://\S+|sandbox://\S+'), '');
        bool hasMathUnderscore = segmentNoUrl.replaceAll(RegExp(r'_{2,}'), '').contains('_');
        if (segment.contains(r'\frac') || segment.contains(r'\partial') || 
            segment.contains(r'\lim') || segment.contains(r'\int') || 
            segment.contains(r'^') || hasMathUnderscore || segment.contains(r'\begin')) {
            if (segment.contains(r'\begin')) {
                return '\n\n\$\$$segment\$\$\n\n';
            }
            return '\$$segment\$';
        }
        return segment;
    });

    // 修复 \n 的替换逻辑，防止误伤 \neq 等 LaTeX 命令
    result = result.replaceAllMapped(RegExp(r'\\n(?![a-zA-Z])'), (m) => '\n');
    result = result.replaceAll(r'\t', '\t');

    result = result.replaceAll(r'\begin{split}', r'\begin{aligned}');
    result = result.replaceAll(r'\end{split}', r'\end{aligned}');

    result = result.replaceAllMapped(RegExp(r'(?<!\$)\$([^\$]+?)\$(?!\$)'), (match) {
        String inner = match.group(1)!;
        inner = _autoCloseLeftRight(inner);
        if (inner.contains(r'\begin')) {
            return '\n\n\$\$$inner\$\$\n\n';
        }
        inner = inner.replaceAll('\n', ' ');
        return ' \$${inner}\$ ';
    });
    
    result = result.replaceAllMapped(RegExp(r'\$\$([\s\S]+?)\$\$'), (match) {
        String inner = match.group(1)!;
        inner = _autoCloseLeftRight(inner);
        return '\n\n\$\$$inner\$\$\n\n';
    });
    
    return result;
  }

  static String _autoCloseLeftRight(String mathText) {
    mathText = mathText.replaceAllMapped(RegExp(r'_{2,}'), (match) {
      return r'\_' * match.group(0)!.length;
    });

    int leftCount = r'\left'.allMatches(mathText).length;
    int rightCount = r'\right'.allMatches(mathText).length;
    if (leftCount > rightCount) {
      mathText += r'\right.' * (leftCount - rightCount);
    }
    return mathText;
  }

  static void runTests() {
    var latexExtensionSet = md.ExtensionSet(
      [LatexBlockSyntax(), ...md.ExtensionSet.gitHubFlavored.blockSyntaxes],
      [LatexInlineSyntax(), ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes],
    );

    List<String> tests = [
      // 缺 $ 的情况
      "设 A,B,C 为随机事件,且 A 与 B 互不相容,\n\$P(A) = \\frac{1}{3}\$\n,则 \$P(B) = ____. 然后其他文字",
      // 有 $ 的情况
      "设 A,B,C 为随机事件,且 A 与 B 互不相容,\n\$P(A) = \\frac{1}{3}\$\n,则 \$P(B) = ____.\$ 然后其他文字",
    ];

    for (var text in tests) {
      var formatted = formatLatex(text);
      print("--- 格式化后 ---\n$formatted\n");
      
      var document = md.Document(extensionSet: latexExtensionSet);
      var lines = formatted.split('\n');
      var nodes = document.parseLines(lines);
      var html = md.HtmlRenderer().render(nodes);
      print("解析HTML: $html\n");
    }
  }
}

void main() {
  TestSanitizer.runTests();
}
