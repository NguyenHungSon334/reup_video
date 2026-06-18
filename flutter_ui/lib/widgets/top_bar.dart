import 'package:flutter/material.dart';
import '../constants/colors.dart';

class TopBar extends StatelessWidget {
  const TopBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: kSidebar,
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          const Text(
            'Reup Douyin',
            style: TextStyle(color: kText, fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: Color.fromRGBO(37, 99, 235, 0.18),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Color.fromRGBO(37, 99, 235, 0.35)),
            ),
            child: const Text(
              'CÔNG CỤ PRO',
              style: TextStyle(
                color: kAccent, fontSize: 9,
                fontWeight: FontWeight.w800, letterSpacing: 0.8,
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}
