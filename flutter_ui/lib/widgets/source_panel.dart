import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../constants/colors.dart';
import '../utils/douyin_parser.dart';
import 'panel_card.dart';

class SourcePanel extends StatefulWidget {
  final TextEditingController ctrl;
  const SourcePanel({super.key, required this.ctrl});

  @override
  State<SourcePanel> createState() => _SourcePanelState();
}

class _SourcePanelState extends State<SourcePanel> {
  int _urlCount = 0;

  @override
  void initState() {
    super.initState();
    widget.ctrl.addListener(_onTextChanged);
    _urlCount = DouyinParser.parse(widget.ctrl.text).length;
  }

  @override
  void dispose() {
    widget.ctrl.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    final count = DouyinParser.parse(widget.ctrl.text).length;
    if (count != _urlCount) setState(() => _urlCount = count);
  }

  @override
  Widget build(BuildContext context) {
    Widget badge = const Icon(Icons.visibility_outlined, size: 14, color: kMuted);
    if (_urlCount > 0) {
      badge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFBFDBFE), width: 1.5),
        ),
        child: Text(
          '$_urlCount đường dẫn',
          style: const TextStyle(
              color: kAccent, fontSize: 11, fontWeight: FontWeight.w700),
        ),
      );
    }

    return PanelCard(
      title: 'NỘI DUNG NGUỒN',
      actionWidget: badge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: widget.ctrl,
            maxLines: 5,
            minLines: 3,
            style: const TextStyle(
                color: kText, fontSize: 13, fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: 'Dán text chia sẻ Douyin hoặc URL...',
              hintStyle: const TextStyle(color: kMuted, fontSize: 13),
              filled: true,
              fillColor: kInputBg,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: kBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: kBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: kAccent, width: 2),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) widget.ctrl.text = data!.text!;
                },
                icon: const Icon(Icons.content_paste_rounded, size: 15),
                label: const Text('Dán',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kAccent,
                  side: const BorderSide(color: kAccent, width: 1.5),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => widget.ctrl.clear(),
                icon: const Icon(Icons.clear_rounded, size: 15),
                label: const Text('Xóa',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kTextDim,
                  side: const BorderSide(color: kBorder, width: 1.5),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
