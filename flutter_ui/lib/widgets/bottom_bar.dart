import 'package:flutter/material.dart';
import '../constants/colors.dart';

class BottomBar extends StatelessWidget {
  final bool running;
  final VoidCallback onClear;
  final VoidCallback? onProcess;
  final VoidCallback? onSubmit;
  final VoidCallback onSave;

  const BottomBar({
    super.key,
    required this.running,
    required this.onClear,
    required this.onProcess,
    this.onSubmit,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: kSidebar,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          const Text(
            '© 2024 Tự Động Hóa Video',
            style: TextStyle(color: kMuted, fontSize: 12),
          ),
          const Spacer(),
          _BarBtn(label: 'Xóa nhật ký', onTap: onClear),
          const SizedBox(width: 8),
          _BarBtn(label: 'Lưu cài đặt', onTap: onSave),
          if (onSubmit != null) ...[
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: running ? null : onSubmit,
              icon: const Icon(Icons.upload_rounded, size: 16),
              label: const Text('Thêm vào hàng đợi',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              style: OutlinedButton.styleFrom(
                foregroundColor: kAccent,
                side: const BorderSide(color: kAccent, width: 1.5),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                minimumSize: const Size(0, 38),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
          const SizedBox(width: 8),
          _GradientButton(
            running: running,
            onPressed: onProcess,
          ),
        ],
      ),
    );
  }
}

class _GradientButton extends StatelessWidget {
  final bool running;
  final VoidCallback? onPressed;
  const _GradientButton({required this.running, required this.onPressed});

  static const _gradientProcess = LinearGradient(
    colors: [Color(0xFF0EA5E9), Color(0xFF6366F1)],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
  static const _gradientStop = LinearGradient(
    colors: [Color(0xFFEF4444), Color(0xFFEC4899)],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
  static const _gradientDisabled = LinearGradient(
    colors: [Color(0xFF7DD3FC), Color(0xFFA5B4FC)],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final gradient =
        !enabled ? _gradientDisabled : running ? _gradientStop : _gradientProcess;

    return GestureDetector(
      onTap: onPressed,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(12),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: (running
                            ? const Color(0xFFEF4444)
                            : const Color(0xFF0EA5E9))
                        .withValues(alpha: 0.45),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              running ? Icons.stop_rounded : Icons.play_arrow_rounded,
              size: 18,
              color: Colors.white,
            ),
            const SizedBox(width: 6),
            Text(
              running ? 'DỪNG' : 'XỬ LÝ VIDEO',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _BarBtn({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: kTextDim,
        side: const BorderSide(color: kBorder, width: 1.5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        minimumSize: const Size(0, 38),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}
