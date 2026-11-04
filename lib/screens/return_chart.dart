import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../main.dart';
import '../models.dart';
import '../services/price_service.dart';

/// One participant's reconstructed return series.
class _Series {
  _Series(this.userId, this.name, this.color, this.points);
  final String userId;
  final String name;
  final Color color;
  final List<({double t, double ret})> points;
}

/// Live-returns line chart: reconstructs each player's return % over the
/// challenge window from their holdings × hourly prices (Binance), the same
/// approach as the web app. Lines are drawn in join order with the shared
/// palette, so a player is the same color here and on the leaderboard.
class ReturnChart extends StatefulWidget {
  const ReturnChart({
    super.key,
    required this.challenge,
    required this.participants,
    required this.holdings,
  });

  final Challenge challenge;
  final List<Participant> participants; // join order (joined_at asc)
  final List<Holding> holdings;

  @override
  State<ReturnChart> createState() => _ReturnChartState();
}

class _ReturnChartState extends State<ReturnChart> {
  final PriceService _price = PriceService();
  List<_Series> _series = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _compute();
  }

  Future<void> _compute() async {
    final ch = widget.challenge;
    final start = ch.startAt ?? DateTime.now().subtract(const Duration(hours: 48));
    final now = DateTime.now();

    // unique coins held anywhere in this challenge
    final coins = <String, Map<String, String>>{};
    for (final h in widget.holdings) {
      final id = h.coinId ?? h.assetSymbol.toLowerCase();
      coins[id] = {'symbol': h.assetSymbol, 'cgId': id};
    }

    // fetch hourly history per coin (parallel)
    final priceHist = <String, List<(DateTime, double)>>{};
    await Future.wait(coins.keys.map((id) async {
      final c = coins[id]!;
      final h = await _price.history(
          symbol: c['symbol']!, cgId: c['cgId']!, start: start, end: now);
      priceHist[id] = h;
    }));

    // unified hourly grid (union of all coins' timestamps)
    final grid = <int>{};
    for (final h in priceHist.values) {
      for (final p in h) {
        grid.add(p.$1.millisecondsSinceEpoch ~/ 3600000 * 3600000);
      }
    }
    final times = grid.toList()..sort();

    // per-coin price at each grid time, forward-filled
    final priceAt = <String, Map<int, double>>{};
    priceHist.forEach((id, hist) {
      final m = <int, double>{};
      var last = 0.0;
      for (final p in hist) {
        last = p.$2;
        m[p.$1.millisecondsSinceEpoch ~/ 3600000 * 3600000] = last;
      }
      // forward-fill missing grid slots
      final filled = <int, double>{};
      for (final t in times) {
        if (m.containsKey(t)) last = m[t]!;
        filled[t] = last;
      }
      priceAt[id] = filled;
    });

    // holdings by user
    final byUser = <String, List<Holding>>{};
    for (final h in widget.holdings) {
      byUser.putIfAbsent(h.userId, () => []).add(h);
    }

    final series = <_Series>[];
    for (var i = 0; i < widget.participants.length; i++) {
      final p = widget.participants[i];
      final hs = byUser[p.userId] ?? const [];
      final color = chartPalette[i % chartPalette.length];
      List<({double t, double ret})> points = [];
      if (hs.isNotEmpty) {
        final entries = hs
            .map((h) => (id: h.coinId ?? h.assetSymbol.toLowerCase(), h: h))
            .where((e) => priceAt.containsKey(e.id))
            .toList();
        for (final t in times) {
          double portfolio = 0;
          double spent = 0;
          for (final e in entries) {
            final stake = e.h.stakeAmount ?? 0;
            spent += stake;
            final entry = e.h.buyPrice ?? 0;
            final price = priceAt[e.id]![t]!;
            if (entry > 0 && price > 0) {
              portfolio += stake * (price / entry);
            } else if (entry <= 0) {
              portfolio += stake;
            }
          }
          final sv = p.startingValue;
          final ret = sv > 0 ? (portfolio - spent) / sv * 100 : 0.0;
          points.add((t: t.toDouble(), ret: ret));
        }
      }
      series.add(_Series(p.userId, p.username ?? p.userId, color, points));
    }

    if (!mounted) return;
    setState(() {
      _series = series;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_series.every((s) => s.points.isEmpty)) {
      return const SizedBox(
        height: 200,
        child: Center(
          child: Text('Chart will populate once the game goes live.',
              style: TextStyle(color: AppColors.dim)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _legend(),
        const SizedBox(height: 8),
        SizedBox(
          height: 220,
          width: double.infinity,
          child: CustomPaint(
            painter: _ChartPainter(_series, widget.challenge),
          ),
        ),
      ],
    );
  }

  Widget _legend() {
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: [
        for (final s in _series)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 10, height: 10, color: s.color),
              const SizedBox(width: 5),
              Text(s.name,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.ink)),
            ],
          ),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.series, this.challenge);

  final List<_Series> series;
  final Challenge challenge;

  @override
  void paint(Canvas canvas, Size size) {
    final padLeft = 44.0;
    final padRight = 8.0;
    final padTop = 8.0;
    final padBottom = 20.0;
    final plot = Rect.fromLTRB(padLeft, padTop, size.width - padRight,
        size.height - padBottom);

    // ---- gather all returns to set the y-range ----
    double minV = double.infinity, maxV = double.negativeInfinity;
    double minT = double.infinity, maxT = double.negativeInfinity;
    for (final s in series) {
      for (final p in s.points) {
        minV = math.min(minV, p.ret);
        maxV = math.max(maxV, p.ret);
        minT = math.min(minT, p.t);
        maxT = math.max(maxT, p.t);
      }
    }
    if (!minV.isFinite) return;
    // pad the y-range so the line never sits flush on the top/bottom edge
    final pad = (maxV - minV) * 0.12;
    minV -= pad;
    maxV += pad;
    if (maxV - minV < 1) {
      final mid = (maxV + minV) / 2;
      minV = mid - 0.5;
      maxV = mid + 0.5;
    }
    if (maxT <= minT) maxT = minT + 1;

    double x(double t) => plot.left + (t - minT) / (maxT - minT) * plot.width;
    double y(double v) => plot.bottom - (v - minV) / (maxV - minV) * plot.height;

    final grid = Paint()
      ..color = AppColors.line
      ..strokeWidth = 1;
    final textStyle = const TextStyle(color: AppColors.dim, fontSize: 10);

    // y gridlines + labels (nice step)
    final step = _niceStep((maxV - minV) / 5);
    final startTick = (minV / step).ceil() * step;
    for (var v = startTick; v <= maxV + 1e-9; v += step) {
      final yv = y(v);
      canvas.drawLine(Offset(plot.left, yv), Offset(plot.right, yv), grid);
      final tp = TextPainter(
        text: TextSpan(text: '${v.toStringAsFixed(1)}%', style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, yv - tp.height / 2));
    }

    // "now" marker (dotted vertical) at the latest timestamp
    final nowT = maxT;
    final nowPaint = Paint()
      ..color = AppColors.dim
      ..strokeWidth = 1;
    final nx = x(nowT);
    for (var yy = plot.top; yy < plot.bottom; yy += 6) {
      canvas.drawLine(Offset(nx, yy), Offset(nx, yy + 3), nowPaint);
    }

    // participant lines
    for (final s in series) {
      if (s.points.length < 2) continue;
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      final path = Path();
      for (var i = 0; i < s.points.length; i++) {
        final p = s.points[i];
        if (i == 0) {
          path.moveTo(x(p.t), y(p.ret));
        } else {
          path.lineTo(x(p.t), y(p.ret));
        }
      }
      canvas.drawPath(path, paint);
      // end dot (current position)
      final last = s.points.last;
      canvas.drawCircle(
          Offset(x(last.t), y(last.ret)), 3, Paint()..color = s.color);
    }
  }

  double _niceStep(double rough) {
    if (rough <= 0) return 0.5;
    final mag = math.pow(10, (math.log(rough) / math.ln10).floor()).toDouble();
    for (final m in [1.0, 2.0, 5.0, 10.0]) {
      if (rough <= m * mag) return m * mag;
    }
    return 10 * mag;
  }

  @override
  bool shouldRepaint(covariant _ChartPainter old) =>
      old.series != series || old.challenge != challenge;
}