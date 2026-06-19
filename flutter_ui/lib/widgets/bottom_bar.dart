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
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: kSidebar,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          const Text(
            '© 2024 Tự Động Hóa Video',
            style: TextStyle(color: kMuted, fontSize: 10.5),
          ),
          const Spacer(),
          _BarBtn(label: 'Xóa nhật ký', onTap: onClear),
          const SizedBox(width: 8),
          _BarBtn(label: 'Lưu cài đặt', onTap: onSave),
          if (onSubmit != null) ...[
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: running ? null : onSubmit,
              icon: const Icon(Icons.upload_rounded, size: 15),
              label: const Text('Thêm vào hàng đợi',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                foregroundColor: kAccent,
                side: const BorderSide(color: kAccent),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9)),
                minimumSize: const Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: onProcess,
            icon: Icon(
              running ? Icons.stop_rounded : Icons.play_arrow_rounded,
              size: 16,
            ),
            label: Text(
              running ? 'DỪNG' : 'XỬ LÝ VIDEO',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: running ? kRed : kAccent,
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFF2563EB66),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
              elevation: 0,
              minimumSize: const Size(0, 34),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
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
        side: const BorderSide(color: kBorder),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        minimumSize: const Size(0, 34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

class _FooterLink extends StatelessWidget {
  final String label;
  const _FooterLink(this.label);

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () {},
      style: TextButton.styleFrom(
        foregroundColor: kTextDim,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: const TextStyle(fontSize: 10.5)),
    );
  }
}
