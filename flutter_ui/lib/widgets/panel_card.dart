import 'package:flutter/material.dart';
import '../constants/colors.dart';

class PanelCard extends StatelessWidget {
  final String title;
  final Widget? actionWidget;
  final Widget child;
  const PanelCard({
    super.key,
    required this.title,
    this.actionWidget,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 8),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: kMuted, fontSize: 10,
                    fontWeight: FontWeight.w700, letterSpacing: 1.1,
                  ),
                ),
                const Spacer(),
                if (actionWidget != null) actionWidget!,
              ],
            ),
          ),
          Container(height: 1, color: kBorder),
          Padding(padding: const EdgeInsets.all(14), child: child),
        ],
      ),
    );
  }
}

class DarkInput extends StatelessWidget {
  final TextEditingController ctrl;
  final String hint;
  final ValueChanged<String>? onChanged;
  const DarkInput({super.key, required this.ctrl, required this.hint, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: ctrl,
      onChanged: onChanged,
      style: const TextStyle(color: kText, fontSize: 12),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: kMuted, fontSize: 12),
        filled: true,
        fillColor: kInputBg,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: const BorderSide(color: kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: const BorderSide(color: kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: BorderSide(color: Color.fromRGBO(37, 99, 235, 0.55)),
        ),
      ),
    );
  }
}
