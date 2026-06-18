import 'package:flutter/material.dart';
import 'constants/colors.dart';
import 'screens/app_shell.dart';

class ReupApp extends StatelessWidget {
  const ReupApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Douyin Reup Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kAccent, surface: kCard),
        switchTheme: SwitchThemeData(
          trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
          thumbColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected) ? Colors.white : kTextDim),
          trackColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected) ? kAccent : kBorder),
        ),
        scrollbarTheme: ScrollbarThemeData(
          thumbColor: WidgetStateProperty.all(kBorder),
          trackColor: WidgetStateProperty.all(Colors.transparent),
        ),
      ),
      home: const AppShell(),
    );
  }
}
