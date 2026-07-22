import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'core/database/database_helper.dart';
import 'core/observability/app_logger.dart';
import 'data/repositories/settings_repository.dart';
import 'services/bank_update_notifier.dart' as bank_updates;
import 'ui/pages/home_page.dart';
import 'ui/theme/app_theme.dart';
import 'ui/pages/main_screen.dart';
import 'package:flutter_tex/flutter_tex.dart';

final ValueNotifier<String> globalThemeNotifier = ValueNotifier('light');
// 核心新增：全局消息总线钥匙，用于跨页面/后台任务弹窗
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
// 核心新增：全局路由钥匙，用于后台任务完成后弹出弹窗
final GlobalKey<NavigatorState> globalNavigatorKey =
    GlobalKey<NavigatorState>();

// 新增：题库刷新事件总线
final ValueNotifier<int> globalBankUpdateNotifier =
    bank_updates.globalBankUpdateNotifier;

class DevHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      // 强制流量走本地 7890 端口 (绝大多数代理软件的默认混合端口)
      ..findProxy = (uri) {
        return "PROXY 127.0.0.1:7890;";
      }
      // 忽略证书校验，防止代理软件的中间人劫持报错
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
  }
}

void main() {
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await AppLogger.initialize();

    FlutterError.onError = (details) {
      AppLogger.error(
        'Unhandled Flutter framework error',
        module: 'Flutter',
        error: details.exception,
        stackTrace: details.stack,
      );
      FlutterError.presentError(details);
    };

    PlatformDispatcher.instance.onError = (error, stackTrace) {
      AppLogger.error(
        'Unhandled platform error',
        module: 'Platform',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    };

    // 桌面端（Windows / Linux）需通过 FFI 加载 SQLite 原生库
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final savedTheme = await SettingsRepository.instance.getAppTheme();
    if (savedTheme.isNotEmpty) {
      globalThemeNotifier.value = savedTheme;
    }

    // 初始化 flutter_tex MathJax 渲染服务
    // Windows/Linux/macOS 桌面端的 webview_flutter 无完整实现，跳过
    if (Platform.isAndroid || Platform.isIOS) {
      await TeXRenderingServer.start();
    }

    AppLogger.info('Application started', module: 'Application');
    runApp(const ShirohaQuizApp());
  }, (error, stackTrace) {
    AppLogger.error(
      'Unhandled root-zone error',
      module: 'Application',
      error: error,
      stackTrace: stackTrace,
    );
    Error.throwWithStackTrace(error, stackTrace);
  });
}

class ShirohaQuizApp extends StatelessWidget {
  const ShirohaQuizApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: globalThemeNotifier,
      builder: (context, themeName, _) {
        return MaterialApp(
          title: 'Shiroha Quiz',
          navigatorKey: globalNavigatorKey, // 核心新增：挂载全局路由引擎
          scaffoldMessengerKey: rootScaffoldMessengerKey, // 挂载全局钥匙
          debugShowCheckedModeBanner: false,
          theme: AppTheme.getTheme(themeName),
          home: const MainScreen(),
        );
      },
    );
  }
}

/// Displays the app logo / name while the database is initialised
/// in the background. On success, replaces itself with [HomePage].
/// On failure, shows an error with a retry button.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    try {
      // Offload the heavy I/O to the database isolate.
      await DatabaseHelper.instance.database;
      if (!mounted) return;
      _navigateToHome();
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.toString());
    }
  }

  void _navigateToHome() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MainScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colors.surface,
      body: Center(
        child: _errorMessage != null ? _buildError(colors) : _buildLoading(),
      ),
    );
  }

  Widget _buildLoading() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.school,
            size: 64, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 24),
        Text(
          'Shiroha Quiz',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 24),
        const CircularProgressIndicator(),
        const SizedBox(height: 12),
        Text(
          '正在准备题库...',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  Widget _buildError(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: colors.error),
          const SizedBox(height: 16),
          Text(
            '初始化失败',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colors.error,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            _errorMessage!,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () {
              setState(() => _errorMessage = null);
              _initApp();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
