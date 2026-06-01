import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/utils/ai_data_sanitizer.dart';
import 'package:shiroha_quiz/ui/widgets/markdown_extensions.dart';

void main() {
  test('isLikelyMathFormula detects genuine LaTeX correctly', () {
    const validMath1 = r'D(\hat{\theta}) = D\left[\frac{2\sum_{i=1}^{n}X_i + \sum_{j=1}^{m}Y_j}{2(m+n)}\right]';
    const validMath2 = r'I = \oint_{\Sigma + \Sigma_1 + \Sigma_2 + \Sigma_3} (-2xz)\mathrm{d}y\mathrm{d}z + z^2\mathrm{d}x\mathrm{d}y';
    const plainText = r'This is a long sentence with a path C:\Users\Test\Documents and no math.';
    
    expect(AiDataSanitizer.isLikelyMathFormula(validMath1), isTrue);
    expect(AiDataSanitizer.isLikelyMathFormula(validMath2), isTrue);
    expect(AiDataSanitizer.isLikelyMathFormula(plainText), isFalse);
  });

  test('formatLatex upgrades long math inline to block', () {
    const input = r'设公式为 $D(\hat{\theta}) = D\left[\frac{2\sum_{i=1}^{n}X_i + \sum_{j=1}^{m}Y_j}{2(m+n)}\right] = \frac{\theta^2}{m+n}$。';
    final output = AiDataSanitizer.formatLatex(input);
    
    // It should have upgraded the long math formula to block ($$)
    expect(output.contains(r'$$'), isTrue);
  });

  testWidgets('buildLatexWidget repairs matrix and renders 2D correctly', (WidgetTester tester) async {
    const text = '矩阵为\$\$ \\begin{pmatrix} 1 & 2 & 3 \\ 2 & 4 & 6 \\ 3 & 6 & 9 \\end{pmatrix} \$\$；';
    
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => buildLatexWidget(context, text),
          ),
        ),
      ),
    );

    // Verify it contains a Math widget representing the rendered LaTeX
    final mathFinder = find.byWidgetPredicate((widget) => widget.runtimeType.toString() == 'Math');
    expect(mathFinder, findsOneWidget);
    
    // Check elements inside the widget tree to ensure it rendered row layout
    final widgetTree = tester.allWidgets;
    bool foundPar = false;
    for (var widget in widgetTree) {
      if (widget is RichText) {
        final plainText = widget.text.toPlainText();
        if (plainText.contains('⎛') || plainText.contains('⎝')) {
          foundPar = true;
        }
      }
    }
    expect(foundPar, isTrue);
  });

  testWidgets('buildLatexWidget bypasses 200-char check for long formulas', (WidgetTester tester) async {
    const longMath = r'公式为 $I = \oint_{\Sigma + \Sigma_1 + \Sigma_2 + \Sigma_3} (-2xz)\mathrm{d}y\mathrm{d}z + z^2\mathrm{d}x\mathrm{d}y - \iint_{\Sigma_1 + \Sigma_2 + \Sigma_3} (-2xz)\mathrm{d}y\mathrm{d}z + z^2\mathrm{d}x\mathrm{d}y = 0 - 0 = 0$。';
    
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => buildLatexWidget(context, longMath),
          ),
        ),
      ),
    );

    // This long formula should render as block or math widget, not as plain raw text SelectableText
    final selectableTextFinder = find.byType(SelectableText);
    expect(selectableTextFinder, findsNothing);
    
    final mathFinder = find.byWidgetPredicate((widget) => widget.runtimeType.toString() == 'Math');
    expect(mathFinder, findsAtLeast(1));
  });
}
