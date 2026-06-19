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
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
        boxShadow: kShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: kMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
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
  final bool readOnly;
  const DarkInput({
    super.key,
    required this.ctrl,
    required this.hint,
    this.onChanged,
    this.readOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: ctrl,
      onChanged: onChanged,
      readOnly: readOnly,
      style: TextStyle(
        color: readOnly ? kMuted : kText,
        fontSize: 12.5,
        fontFamily: readOnly ? 'monospace' : null,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: kMuted, fontSize: 12.5),
        filled: true,
        fillColor: readOnly ? const Color(0xFFF8FAFC) : kInputBg,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        suffixIcon: readOnly
            ? const Icon(Icons.lock_outline_rounded, size: 13, color: kMuted)
            : null,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: const BorderSide(color: kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(
            color: readOnly ? kBorder : kBorder,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(
            color: readOnly ? kBorder : kAccent,
            width: 1.5,
          ),
        ),
      ),
    );
  }
}
