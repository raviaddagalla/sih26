import 'package:flutter/material.dart';

import 'screens/navigation_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IdrNavigationApp());
}

class IdrNavigationApp extends StatelessWidget {
  const IdrNavigationApp({super.key});

  static const ink = Color(0xFF11120F);
  static const paper = Color(0xFFF3F0E8);
  static const lime = Color(0xFFD9F16F);
  static const muted = Color(0xFF7E8276);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'IDR / Intelligent Dead Reckoning',
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: paper,
        colorScheme: ColorScheme.fromSeed(
          seedColor: lime,
          brightness: Brightness.light,
          surface: paper,
        ),
        fontFamily: 'Georgia',
        textTheme: const TextTheme(
          displayLarge: TextStyle(fontFamily: 'Georgia', fontWeight: FontWeight.w400),
          headlineMedium: TextStyle(fontFamily: 'Georgia', fontWeight: FontWeight.w400),
          titleLarge: TextStyle(fontFamily: 'Georgia', fontWeight: FontWeight.w400),
          bodyMedium: TextStyle(fontFamily: 'Arial', height: 1.35),
          labelLarge: TextStyle(fontFamily: 'Arial', fontWeight: FontWeight.w700, letterSpacing: 1.1),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: paper,
          foregroundColor: ink,
          elevation: 0,
        ),
      ),
      home: const NavigationScreen(),
    );
  }
}
