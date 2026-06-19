import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../constants/colors.dart';
import 'panel_card.dart';

class DestPanel extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTab;
  final TextEditingController localPathCtrl;
  final TextEditingController gdriveCtrl;

  const DestPanel({
    super.key,
    required this.tab,
    required this.onTab,
    required this.localPathCtrl,
    required this.gdriveCtrl,
  });

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      title: 'ĐÍCH LƯU KẾT QUẢ',
      actionWidget: const Icon(Icons.crop_square_rounded, size: 14, color: kMuted),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 40,
            decoration: BoxDecoration(
              color: kInputBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kBorder),
            ),
            child: Row(
              children: [
                DestTab(label: 'Google Drive', active: tab == 0, onTap: () => onTab(0)),
                DestTab(label: 'Thư mục cục bộ', active: tab == 1, onTap: () => onTab(1)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (tab == 0) ...[
            const Text(
              'ID Thư mục',
              style: TextStyle(
                  color: kTextDim, fontSize: 12,
                  fontWeight: FontWeight.w700, letterSpacing: 0.4),
            ),
            const SizedBox(height: 6),
            DarkInput(
              ctrl: gdriveCtrl,
              hint: '1ABC_folder_id_xyz  (để trống = Thư mục gốc Drive)',
            ),
          ] else ...[
            const Text(
              'Đường dẫn lưu video',
              style: TextStyle(
                  color: kTextDim, fontSize: 12,
                  fontWeight: FontWeight.w700, letterSpacing: 0.4),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: DarkInput(ctrl: localPathCtrl, hint: 'C:\\Videos\\output'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () async {
                    final path = await FilePicker.platform.getDirectoryPath();
                    if (path != null) localPathCtrl.text = path;
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kAccent,
                    side: const BorderSide(color: kAccent, width: 1.5),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Chọn',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class DestTab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const DestTab({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: active ? kAccent : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : kMuted,
              fontSize: 13,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
