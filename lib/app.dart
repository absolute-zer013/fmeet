import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/settings_controller.dart';
import 'theme/app_theme.dart';
import 'ui/home_shell.dart';

class PixyControlApp extends StatelessWidget {
  const PixyControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    return MaterialApp(
      title: 'PixyControl',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: settings.darkMode ? ThemeMode.dark : ThemeMode.light,
      home: const HomeShell(),
    );
  }
}
