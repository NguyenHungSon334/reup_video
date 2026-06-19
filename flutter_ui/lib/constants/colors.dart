import 'package:flutter/material.dart';

// ── Backgrounds ───────────────────────────────────────────────────────────────
const kBg      = Color(0xFFF1F5F9);
const kSidebar = Color(0xFFFFFFFF);
const kCard    = Color(0xFFFFFFFF);
const kLogBg   = Color(0xFFF8FAFC);

// ── Borders & inputs ──────────────────────────────────────────────────────────
const kBorder  = Color(0xFFE2E8F0);
const kInputBg = Color(0xFFF8FAFC);

// ── Accent ────────────────────────────────────────────────────────────────────
const kAccent  = Color(0xFF2563EB);

// ── Text ──────────────────────────────────────────────────────────────────────
const kText    = Color(0xFF0D1117);
const kTextDim = Color(0xFF374151);
const kMuted   = Color(0xFF6B7280);

// ── Status ────────────────────────────────────────────────────────────────────
const kGreen   = Color(0xFF16A34A);
const kRed     = Color(0xFFDC2626);
const kAmber   = Color(0xFFD97706);

// ── Shadow helper ─────────────────────────────────────────────────────────────
const kShadow = [
  BoxShadow(
    color: Color(0x0A000000),
    blurRadius: 12,
    offset: Offset(0, 2),
  ),
  BoxShadow(
    color: Color(0x06000000),
    blurRadius: 4,
    offset: Offset(0, 1),
  ),
];

const kShadowMd = [
  BoxShadow(
    color: Color(0x10000000),
    blurRadius: 20,
    offset: Offset(0, 4),
  ),
  BoxShadow(
    color: Color(0x06000000),
    blurRadius: 6,
    offset: Offset(0, 1),
  ),
];
