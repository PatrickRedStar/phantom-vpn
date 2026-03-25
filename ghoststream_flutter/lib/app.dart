import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/ghost_colors.dart';
import 'core/theme/ghost_theme.dart';
import 'providers/theme_provider.dart';
import 'providers/profiles_provider.dart';
import 'providers/preferences_provider.dart';
import 'ui/screens/dashboard_screen.dart';

class GhostStreamApp extends ConsumerStatefulWidget {
  const GhostStreamApp({super.key});

  @override
  ConsumerState<GhostStreamApp> createState() => _GhostStreamAppState();
}

class _GhostStreamAppState extends ConsumerState<GhostStreamApp> {
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await ref.read(preferencesProvider.notifier).init();
    await ref.read(profilesProvider.notifier).load();
    if (mounted) setState(() => _initialized = true);
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);

    if (!_initialized) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ghostDarkTheme(),
        home: const Scaffold(
          backgroundColor: Color(0xFF090b16),
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return MaterialApp(
      title: 'GhostStream VPN',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: ghostLightTheme(),
      darkTheme: ghostDarkTheme(),
      builder: (context, child) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final colors = isDark ? GhostColors.darkColors : GhostColors.lightColors;
        return GhostColorsProvider(colors: colors, child: child!);
      },
      home: const DashboardScreen(),
    );
  }
}
