import 'package:shiroha_quiz/utils/ai_data_sanitizer.dart';

void main() {
  String text = r'A. ( )2 1 2 2 , S Fnm S \sim';
  
  // Simulated auto-wrapper
  const knownCmds = r'frac|sum|int|alpha|beta|gamma|delta|epsilon|varepsilon|zeta|eta|'
        r'theta|vartheta|iota|kappa|lambda|mu|nu|xi|pi|varpi|rho|varrho|'
        r'sigma|varsigma|tau|upsilon|phi|varphi|chi|psi|omega|'
        r'Gamma|Delta|Theta|Lambda|Xi|Pi|Sigma|Upsilon|Phi|Psi|Omega|'
        r'infty|limits|left|right|begin|end|'
        r'sin|cos|tan|cot|sec|csc|log|ln|max|min|lim|sqrt|'
        r'cdot|cdots|ldots|times|div|pm|mp|neq|leq|geq|approx|equiv|'
        r'propto|in|notin|subset|supset|cup|cap|emptyset|forall|exists|'
        r'nabla|partial|mathbf|mathrm|mathit|mathbb|mathcal|'
        r'text|textbf|textit|underline|overline|hat|tilde|vec|dot|ddot|'
        r'overbrace|underbrace|cases|matrix|pmatrix|bmatrix|vmatrix|Vmatrix|array|'
        r'boldsymbol|widehat|widetilde|operatorname|DeclareMathOperator|'
        r'mid|nmid|to|gets|rightarrow|leftarrow|Rightarrow|Leftarrow|iff|implies|'
        r'xrightarrow|xleftarrow|bigoplus|bigotimes|bigcup|bigcap|biguplus|bigwedge|bigvee|'
        r'lfloor|rfloor|lceil|rceil|langle|rangle|binom|dbinom|tbinom|'
        r'stackrel|overset|underset|pmod|because|therefore|ell|perp|parallel|angle|Im|Re|not|quad|qquad|sim|simeq|cong|propto';

  text = text.replaceAllMapped(RegExp(r'([^\u4e00-\u9fa5，。、！？：；（）\n]+)'), (match) {
        String segment = match.group(1)!;
        if (segment.contains('![')) return segment;
        if (segment.contains(r'$')) return segment;
        String segmentNoUrl = segment.replaceAll(RegExp(r'https?://\S+|sandbox://\S+'), '');
        bool hasMathUnderscore = segmentNoUrl.replaceAll(RegExp(r'_{2,}'), '').contains('_');
        bool hasMathCmd = RegExp(r'\\(' + knownCmds + r')\b').hasMatch(segment);
        
        if (segment.contains(r'^') || hasMathUnderscore || hasMathCmd) {
            return '\$$segment\$';
        }
        return segment;
  });

  print(text);
}
