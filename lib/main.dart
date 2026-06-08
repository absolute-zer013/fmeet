import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/diag/crash_log.dart';
import 'state/device_controller.dart';
import 'state/settings_controller.dart';

Future<void> main() async {
  CrashLog.init();

  // Funnel every error channel into the breadcrumb log. A native SIGSEGV won't
  // reach these, but uncaught Dart exceptions and the last breadcrumb before a
  // hard crash will — exactly what's missing when diagnosing the field crash.
  FlutterError.onError = (details) {
    CrashLog.write('FlutterError: ${details.exceptionAsString()}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    CrashLog.write('PlatformDispatcher error: $error');
    return false;
  };
  Isolate.current.addErrorListener(RawReceivePort((dynamic pair) {
    CrashLog.write('Isolate error: $pair');
  }).sendPort);

  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsController(prefs);

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider(
            create: (_) => DeviceController(settings: settings),
          ),
        ],
        child: const PixyControlApp(),
      ),
    );
  }, (error, stack) {
    CrashLog.write('Zone uncaught: $error');
  });
}
