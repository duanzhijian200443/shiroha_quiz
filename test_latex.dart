import 'dart:convert';
import 'lib/utils/ai_data_sanitizer.dart';

void main() {
  String input1 = r"设 A,B,C 为随机事件,且 A 与 B 互不相容,A 与 C 互不相容,B 与 C 相互独立," + "\n" + r"P(A) = P(B) = P(C) = \frac{1}{3}" + "\n" + r",则 $P(B \cup C \mid A \cup B \cup C) = ____.";
  String input2 = r"设 A,B,C 为随机事件,且 A 与 B 互不相容,A 与 C 互不相容,B 与 C 相互独立," + "\n" + r"P(A) = P(B) = P(C) = \frac{1}{3}" + "\n" + r",则 $P(B \cup C \mid A \cup B \cup C) = $ ____.";
  String input3 = r"设 A,B,C 为随机事件,且 A 与 B 互不相容,A 与 C 互不相容,B 与 C 相互独立," + "\n" + r"P(A) = P(B) = P(C) = \frac{1}{3}" + "\n" + r",则 $P(B \backslash cup C \backslash mid A \backslash cup B \backslash cup C) = $ ____.";

  print("=== Input 1 ===");
  print(AiDataSanitizer.formatLatex(input1));
  print("\n=== Input 2 ===");
  print(AiDataSanitizer.formatLatex(input2));
}
