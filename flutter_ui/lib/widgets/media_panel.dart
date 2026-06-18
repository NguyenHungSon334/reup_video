import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../constants/colors.dart';
import 'panel_card.dart';

class MediaPanel extends StatelessWidget {
  final bool useLogo;
  final bool useMusic;
  final String logoPath;
  final String musicPath;
  final ValueChanged<bool> onLogo;
  final ValueChanged<bool> onMusic;
  final ValueChanged<String> onLogoPath;
  final ValueChanged<String> onMusicPath;

  const MediaPanel({
    super.key,
    required this.useLogo,
    required this.useMusic,
    required this.logoPath,
    required this.musicPath,
    required this.onLogo,
    required this.onMusic,
    required this.onLogoPath,
    required this.onMusicPath,
  });

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      title: 'LỚP PHỦ MEDIA',
      actionWidget: const Icon(Icons.close_rounded, size: 14, color: kMuted),
      child: Column(
        children: [
          OverlayRow(
            icon: Icons.image_outlined,
            label: 'Watermark Logo',
            sub: 'Hỗ trợ: PNG, WEBP',
            path: logoPath,
            enabled: useLogo,
            onToggle: onLogo,
            onBrowse: () async {
              final res = await FilePicker.platform.pickFiles(type: FileType.image);
              if (res?.files.single.path != null) {
                onLogoPath(res!.files.single.path!);
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Container(height: 1, color: kBorder),
          ),
          OverlayRow(
            icon: Icons.music_note_outlined,
            label: 'Nhạc nền',
            sub: 'Âm thanh gốc sẽ giảm xuống 80%',
            path: musicPath,
            enabled: useMusic,
            onToggle: onMusic,
            onBrowse: () async {
              final res = await FilePicker.platform.pickFiles(type: FileType.audio);
              if (res?.files.single.path != null) {
                onMusicPath(res!.files.single.path!);
              }
            },
          ),
        ],
      ),
    );
  }
}

class OverlayRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  final String path;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onBrowse;

  const OverlayRow({
    super.key,
    required this.icon,
    required this.label,
    required this.sub,
    required this.path,
    required this.enabled,
    required this.onToggle,
    required this.onBrowse,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: kInputBg,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: kBorder),
              ),
              child: Icon(icon, size: 17, color: kTextDim),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: kText, fontSize: 12.5, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(sub,
                      style: const TextStyle(color: kMuted, fontSize: 10.5)),
                ],
              ),
            ),
            Switch(value: enabled, onChanged: onToggle),
            const SizedBox(width: 4),
            TextButton(
              onPressed: enabled ? onBrowse : null,
              style: TextButton.styleFrom(
                foregroundColor: kTextDim,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Chọn', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        if (enabled && path.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 5, left: 50),
            child: Text(
              path,
              style: const TextStyle(
                  color: kTextDim, fontSize: 10, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}
