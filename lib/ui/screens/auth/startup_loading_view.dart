import 'package:flutter/material.dart';
import 'package:moonfin_design/moonfin_design.dart';

/// The Android first frame, before preferences and services are available.
/// Keep this independent of dependency injection and the authenticated router.
class StartupLoadingApp extends StatelessWidget {
  const StartupLoadingApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark),
    home: const StartupLoadingView(),
  );
}

/// Shared by the early bootstrap and the session-restoration screen so the
/// loading state stays visible through both stages of startup.
class StartupLoadingView extends StatelessWidget {
  const StartupLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    final wideScreen = MediaQuery.sizeOf(context).width >= 800;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColorScheme.background,
              AppColorScheme.surfaceVariant,
              AppColorScheme.surface,
            ],
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/images/logo_and_text.png',
                    height: wideScreen ? 80 : 56,
                    width: double.infinity,
                    fit: BoxFit.contain,
                    semanticLabel: 'Moonfin',
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: 240,
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2),
                      color: AppColorScheme.accent.withValues(alpha: 0.85),
                      backgroundColor: AppColorScheme.accent.withValues(
                        alpha: 0.15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
