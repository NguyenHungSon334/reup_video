import 'package:flutter/material.dart';
import 'constants/colors.dart';
import 'screens/app_shell.dart';

class ReupApp extends StatelessWidget {
  const ReupApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hồn Đá Reup',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light().copyWith(
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.light(
          primary: kAccent,
          surface: kCard,
          onSurface: kText,
        ),
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: kText,
          displayColor: kText,
        ),
        switchTheme: SwitchThemeData(
          trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
          thumbColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected) ? Colors.white : Colors.white),
          trackColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected) ? kAccent : kMuted),
        ),
        scrollbarTheme: ScrollbarThemeData(
          thumbColor: WidgetStateProperty.all(const Color(0xFFCBD5E1)),
          trackColor: WidgetStateProperty.all(Colors.transparent),
          radius: const Radius.circular(8),
        ),
        dividerColor: kBorder,
        dialogTheme: const DialogThemeData(backgroundColor: Colors.white),
      ),
      home: const AppShell(),
    );
  }
}
