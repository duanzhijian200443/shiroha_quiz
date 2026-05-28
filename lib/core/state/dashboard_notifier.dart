import 'package:flutter/foundation.dart';

/// Lightweight跨页面状态通知：任何页面调用 [notify] 后，
/// 所有监听 [notifier] 的 Widget 自动重建。
class DashboardNotifier {
  DashboardNotifier._();

  static final ValueNotifier<int> _instance = ValueNotifier<int>(0);

  /// 监听此 notifier 的 Widget 会在值变化时重建。
  static ValueNotifier<int> get notifier => _instance;

  /// 触发一次刷新（value 自增）。
  static void notify() {
    _instance.value++;
  }
}
