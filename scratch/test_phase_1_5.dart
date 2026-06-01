import '../lib/utils/ai_data_sanitizer.dart';

void main() {
  String input1 = r"已知 \alpha = 1 且 \beta = 2";
  String input2 = r"极值点为 x = \pm 1";
  String input3 = r"我们有 \frac{1}{2} x";
  
  print('=== TEST A ===');
  print('Original: $input1');
  print('Formatted: ${testFormat(input1)}');
  print('\n=== TEST B ===');
  print('Original: $input2');
  print('Formatted: ${testFormat(input2)}');
  print('\n=== TEST C ===');
  print('Original: $input3');
  print('Formatted: ${testFormat(input3)}');
}

const knownCmdsSet = {'frac', 'sum', 'int', 'oint', 'iint', 'iiint', 'prod', 'coprod', 'alpha', 'beta', 'gamma', 'delta', 'epsilon', 'varepsilon', 'zeta', 'eta', 'theta', 'vartheta', 'iota', 'kappa', 'lambda', 'mu', 'nu', 'xi', 'pi', 'varpi', 'rho', 'varrho', 'sigma', 'varsigma', 'tau', 'upsilon', 'phi', 'varphi', 'chi', 'psi', 'omega', 'Gamma', 'Delta', 'Theta', 'Lambda', 'Xi', 'Pi', 'Sigma', 'Upsilon', 'Phi', 'Psi', 'Omega', 'infty', 'limits', 'left', 'right', 'begin', 'end', 'sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'log', 'ln', 'max', 'min', 'lim', 'sqrt', 'cdot', 'cdots', 'ldots', 'times', 'div', 'pm', 'mp', 'neq', 'leq', 'geq', 'approx', 'equiv', 'propto', 'in', 'notin', 'subset', 'supset', 'cup', 'cap', 'emptyset', 'forall', 'exists', 'nabla', 'partial', 'mathbf', 'mathrm', 'mathit', 'mathbb', 'mathcal', 'text', 'textbf', 'textit', 'underline', 'overline', 'hat', 'tilde', 'vec', 'dot', 'ddot', 'overbrace', 'underbrace', 'cases', 'matrix', 'pmatrix', 'bmatrix', 'vmatrix', 'Vmatrix', 'array', 'boldsymbol', 'widehat', 'widetilde', 'operatorname', 'DeclareMathOperator', 'mid', 'nmid', 'to', 'gets', 'rightarrow', 'leftarrow', 'Rightarrow', 'Leftarrow', 'iff', 'implies', 'xrightarrow', 'xleftarrow', 'bigoplus', 'bigotimes', 'bigcup', 'bigcap', 'biguplus', 'bigwedge', 'bigvee', 'lfloor', 'rfloor', 'lceil', 'rceil', 'langle', 'rangle', 'binom', 'dbinom', 'tbinom', 'stackrel', 'overset', 'underset', 'pmod', 'because', 'therefore', 'ell', 'perp', 'parallel', 'angle', 'Im', 'Re', 'not', 'quad', 'qquad', 'sim', 'simeq', 'cong', 'geqslant', 'leqslant', 'ge', 'le', 'd'};

String testFormat(String text) {
  if (text.isEmpty || !text.contains(r'\')) return text;

  final List<String> saved = [];
  String s = text;

  // Phase 1: 保护已经包裹好的块
  s = s.replaceAllMapped(RegExp(r'\$\$[\s\S]*?\$\$'), (m) {
    saved.add(m.group(0)!); return '⁕${saved.length - 1}⁕';
  });
  s = s.replaceAllMapped(RegExp(r'\$(?!\$)[\s\S]*?\$'), (m) {
    saved.add(m.group(0)!); return '⁕${saved.length - 1}⁕';
  });
  s = s.replaceAllMapped(RegExp(r'\\\([\s\S]*?\\\)'), (m) {
    saved.add(m.group(0)!); return '⁕${saved.length - 1}⁕';
  });
  s = s.replaceAllMapped(RegExp(r'\\\[[\s\S]*?\\\]'), (m) {
    saved.add(m.group(0)!); return '⁕${saved.length - 1}⁕';
  });

  // Phase 1.5: 把裸露的大型多行环境整体包裹进 $$...$$
  s = s.replaceAllMapped(RegExp(r'\\begin\{([a-zA-Z*]+)\}[\s\S]*?\\end\{\1\}'), (m) {
    saved.add('\n\$\$${m.group(0)!}\$\$\n');
    return '⁕${saved.length - 1}⁕';
  });

  // Phase 2: 新的连贯数学公式块匹配
  s = s.replaceAllMapped(
    RegExp(
      r'(\\[a-zA-Z]+)[^⁕\$\u4e00-\u9fa5，。：；！？（）\r\n]*'
    ),
    (m) {
      final full = m.group(0)!;
      if (full.contains('⁕')) return full;
      
      String trimmed = full;
      String trail = '';
      final endPunct = RegExp(r'[\s,，.。\s]+$');
      final punctMatch = endPunct.firstMatch(trimmed);
      if (punctMatch != null) {
        trimmed = trimmed.substring(0, punctMatch.start);
        trail = punctMatch.group(0)!;
      }
      
      if (trimmed.isEmpty || trimmed == r'\') return full;
      if (RegExp(r'^\n*\\[{}]\s*$').hasMatch(trimmed)) return full;
      
      return '\$$trimmed\$$trail';
    }
  );

  // Phase 3: 恢复已保护的块
  for (int i = 0; i < saved.length; i++) {
    s = s.replaceFirst('⁕$i⁕', saved[i]);
  }

  return s;
}
