void main() {
  String inner = r')2 1,N\mu\sigma 的简单随机样本， 12,,,mYYY是来自总';
  inner = inner.replaceAllMapped(RegExp(r'(?<!\\text\{)([\u4e00-\u9fa5]+)'), (m) {
             return r'\text{' + m.group(1)! + r'}';
  });
  print(inner);
}
