foreach ($file in @('lib/ui/pages/ai_generator_screen.dart', 'lib/ui/pages/practice_page.dart', 'lib/ui/pages/question_list_screen.dart')) {
  $content = Get-Content $file -Raw -Encoding UTF8
  
  $pattern = '(?s)class RobustLatexElementBuilder extends MarkdownElementBuilder \{.*?Widget visitElementAfter\(md\.Element element, TextStyle\? preferredStyle\) \{.*?return SingleChildScrollView\((.*?child: Math\.tex\(\s*mathText,\s*textStyle: textStyle,\s*)mathStyle: MathStyle\.text,\s*(onErrorFallback:.*?)\);.*?\}.*?\}'
  
  $replacement = 'class RobustLatexElementBuilder extends MarkdownElementBuilder {
  final TextStyle textStyle;
  RobustLatexElementBuilder({required this.textStyle});

  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    String mathText = element.textContent.replaceAll(''\$'', '''');
    
    // 修复括号导致渲染的非法转义
    mathText = mathText.replaceAll(r''\('', ''('').replaceAll(r''\)'', '')'');
    
    bool isDisplay = mathText.contains(r''\begin'') || mathText.contains(r''\\'');
    
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Math.tex(
        mathText,
        textStyle: textStyle,
        mathStyle: isDisplay ? MathStyle.display : MathStyle.text,
        onErrorFallback: (err) => Text(
          ''\$''+mathText+''\$'',
          style: textStyle.copyWith(color: Colors.redAccent),
        ),
      ),
    );
  }
}'

  $newContent = [regex]::Replace($content, '(?s)class RobustLatexElementBuilder extends MarkdownElementBuilder \{.*?^\}', $replacement, [System.Text.RegularExpressions.RegexOptions]::Multiline)
  
  Set-Content -Path $file -Value $newContent -Encoding UTF8
}
