import 'package:flutter/material.dart';
import '../constants/colors.dart';

class Sidebar extends StatelessWidget {
  final int navIdx;
  final void Function(int) onNav;
  const Sidebar({super.key, required this.navIdx, required this.onNav});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 136,
      color: kSidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Tự Động\nHóa Video',
                  style: TextStyle(
                    color: kText, fontSize: 12.5,
                    fontWeight: FontWeight.w700, height: 1.4,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: Color.fromRGBO(37, 99, 235, 0.15),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: Color.fromRGBO(37, 99, 235, 0.3)),
                  ),
                  child: const Text(
                    'V2.4.0 ỔN ĐỊNH',
                    style: TextStyle(
                      color: kAccent, fontSize: 8.5,
                      fontWeight: FontWeight.w700, letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(height: 1, color: kBorder),
          const SizedBox(height: 4),
          NavItem(icon: Icons.dataset_outlined, label: 'Hàng Đợi', idx: 1, cur: navIdx, onTap: onNav),
          const Spacer(),
          Container(height: 1, color: kBorder),
          NavItem(icon: Icons.settings_outlined, label: 'Cài Đặt', idx: 99, cur: navIdx, onTap: onNav),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class NavItem extends StatelessWidget {
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

  bool get _active => idx == cur;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onTap(idx),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: _active
              ? Color.fromRGBO(37, 99, 235, 0.12)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: _active ? kAccent : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 15, color: _active ? kAccent : kTextDim),
            const SizedBox(width: 9),
            Text(
              label,
              style: TextStyle(
                color: _active ? kText : kTextDim,
                fontSize: 12,
                fontWeight: _active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
