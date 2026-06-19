import 'package:flutter/material.dart';
import '../constants/colors.dart';

class Sidebar extends StatelessWidget {
  final int navIdx;
  final void Function(int) onNav;
  const Sidebar({super.key, required this.navIdx, required this.onNav});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      decoration: const BoxDecoration(
        color: kSidebar,
        border: Border(right: BorderSide(color: kBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Logo area ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: kAccent,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x402563EB),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 20),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ReupPro',
                        style: TextStyle(
                          color: kText,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                      Text(
                        'v2.4.0',
                        style: TextStyle(
                          color: kMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Divider ────────────────────────────────────────────────────────
          Container(height: 1, color: kBorder, margin: const EdgeInsets.symmetric(horizontal: 16)),
          const SizedBox(height: 8),

          // ── Label ──────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Text(
              'MENU',
              style: TextStyle(
                color: kMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ),

          NavItem(icon: Icons.view_list_rounded, label: 'Hàng Đợi', idx: 1, cur: navIdx, onTap: onNav),

          const Spacer(),

          Container(height: 1, color: kBorder, margin: const EdgeInsets.symmetric(horizontal: 16)),
          const SizedBox(height: 8),

          NavItem(icon: Icons.tune_rounded, label: 'Cài Đặt', idx: 99, cur: navIdx, onTap: onNav),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class NavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final int idx;
  final int cur;
  final void Function(int) onTap;
  const NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.idx,
    required this.cur,
    required this.onTap,
  });

  @override
  State<NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<NavItem> {
  bool _hovered = false;
  bool get _active => widget.idx == widget.cur;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: () => widget.onTap(widget.idx),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _active
                  ? kAccent
                  : _hovered
                      ? const Color(0xFFF1F5F9)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  widget.icon,
                  size: 16,
                  color: _active ? Colors.white : (_hovered ? kAccent : kTextDim),
                ),
                const SizedBox(width: 10),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: _active ? Colors.white : (_hovered ? kText : kTextDim),
                    fontSize: 14,
                    fontWeight: _active ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
