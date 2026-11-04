import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';
import '../preset_coins.dart';
import '../services/price_service.dart';

/// Scrolling live-price tape of the preset coins (mirrors the web ticker).
/// Auto-scrolls via a ScrollController (normal layout — never a giant
/// composited transform, which drops out on phone GPUs).
class TickerTape extends StatefulWidget {
  const TickerTape({super.key});

  @override
  State<TickerTape> createState() => _TickerTapeState();
}

class _TickerTapeState extends State<TickerTape> {
  final PriceService _price = PriceService();
  final ScrollController _scroll = ScrollController();
  Map<String, Map<String, double>> _markets = {};
  Timer? _scrollTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _scrollTimer =
        Timer.periodic(const Duration(milliseconds: 40), (_) => _advance());
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final m = await _price.presetMarkets(presetCoins);
    if (!mounted) return;
    setState(() => _markets = m);
  }

  void _advance() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent) {
      _scroll.jumpTo(0);
    } else {
      _scroll.jumpTo(pos.pixels + 1.5);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      color: AppColors.panel,
      child: ListView.builder(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        itemCount: presetCoins.length * 3,
        itemBuilder: (ctx, i) =>
            _item(presetCoins[i % presetCoins.length]),
      ),
    );
  }

  Widget _item(Coin c) {
    final m = _markets[c.cgId];
    final px = m?['price'] ?? 0;
    final pct = m?['pct24h'] ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(c.symbol,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(width: 10),
          Text(px > 0 ? '\$${_px(px)}' : '—',
              style: const TextStyle(color: AppColors.dim, fontSize: 13)),
          const SizedBox(width: 10),
          Text(
            pct != 0 ? '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(1)}%' : '—',
            style: TextStyle(
                color: pct >= 0 ? AppColors.green : AppColors.red,
                fontSize: 12,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  String _px(double v) {
    if (v >= 1000) return v.toStringAsFixed(0);
    if (v >= 1) return v.toStringAsFixed(2);
    return v.toStringAsFixed(4);
  }
}