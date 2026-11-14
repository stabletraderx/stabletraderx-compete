import 'dart:async';

import 'package:flutter/material.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../api/api_client.dart';
import '../main.dart';
import '../models.dart';
import '../services/challenge_service.dart';

/// Next Friday 13:00 America/New_York (DST-aware) as epoch milliseconds.
int nextFridayNyMs() {
  tzdata.initializeTimeZones(); // idempotent
  final ny = tz.getLocation('America/New_York');
  final now = tz.TZDateTime.now(ny);
  final diff = (DateTime.friday - now.weekday) % 7; // 0 = today is Friday
  final today1300 = tz.TZDateTime(ny, now.year, now.month, now.day, 13);
  if (diff == 0 && !now.isBefore(today1300)) {
    return tz.TZDateTime(
      ny,
      now.year,
      now.month,
      now.day + 7,
      13,
    ).millisecondsSinceEpoch;
  }
  return tz.TZDateTime(
    ny,
    now.year,
    now.month,
    now.day + diff,
    13,
  ).millisecondsSinceEpoch;
}

String _countdown(int targetMs, DateTime now) {
  final left = targetMs - now.millisecondsSinceEpoch;
  if (left <= 0) return 'now';
  final d = left ~/ 86400000;
  final h = (left % 86400000) ~/ 3600000;
  final m = (left % 3600000) ~/ 60000;
  final s = (left % 60000) ~/ 1000;
  if (d > 0) return '${d}d ${h}h';
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

/// The Friday Futures weekly-event card, rendered on the Home tab. Mirrors the
/// shipped web card: kickoff countdown, join/leave, "who's in" count, and the
/// streak readout.
class FridayFuturesCard extends StatefulWidget {
  const FridayFuturesCard({super.key, required this.api, required this.onOpen});

  final ApiClient api;

  /// Open a challenge (push the detail screen).
  final Future<void> Function(Challenge ch) onOpen;

  @override
  State<FridayFuturesCard> createState() => _FridayFuturesCardState();
}

class _FridayFuturesCardState extends State<FridayFuturesCard> {
  late final ChallengeService _svc = ChallengeService(widget.api);

  Challenge? _ff;
  Map<String, dynamic>? _seat; // my participant row
  int _joined = 0;
  int _streak = 0;
  bool _loading = true;
  Timer? _ticker;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final ff = await _svc.fridayFutures();
      Map<String, dynamic>? seat;
      var joined = 0;
      if (ff != null) {
        seat = await _svc.mySeat(ff.id);
        if (seat != null && seat['removed_at'] != null) seat = null;
        final v = await widget.api.restGet(
          '/challenge_participants',
          query: {
            'challenge_id': 'eq.${ff.id}',
            'removed_at': 'is.null',
            'select': 'id',
            'limit': '200',
          },
        );
        joined = (v is List) ? v.length : 0;
      }
      final streak = await _svc.myStreak();
      if (!mounted) return;
      setState(() {
        _ff = ff;
        _seat = seat;
        _joined = joined;
        _streak = streak;
        _loading = false;
      });
      _startTicker();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    if (_ff == null || _ff!.status != 'pending') return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
    });
  }

  Future<void> _join() async {
    final ff = _ff;
    if (ff == null) return;
    setState(() => _loading = true);
    try {
      final err = await _svc.joinFridayFutures(ff);
      if (!mounted) return;
      if (err != null) {
        _toast(err);
        await _load();
        return;
      }
      await widget.onOpen(await _svc.getChallenge(ff.id) ?? ff);
      if (mounted) await _load();
    } catch (e) {
      _toast(e.toString());
      await _load();
    }
  }

  Future<void> _leave() async {
    final ff = _ff;
    if (ff == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave Friday Futures?'),
        content: const Text("You'll give up your spot in this week's race."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _loading = true);
    try {
      await _svc.leaveFridayFutures(ff.id);
      try {
        await _svc.revertFridayStreak(ff.id);
      } catch (_) {}
      await _load();
    } catch (e) {
      _toast(e.toString());
      await _load();
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  bool get _submitted => _seat != null && _seat!['submitted_at'] != null;

  @override
  Widget build(BuildContext context) {
    final ff = _ff;
    final maxPlayers = ff?.maxPlayers ?? 100;
    final launchMs = nextFridayNyMs();

    return Card(
      color: AppColors.panel,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: AppColors.green.withValues(alpha: 0.4),
          width: 1.2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'WEEKLY EVENT',
                  style: TextStyle(
                    color: AppColors.green,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                Icon(Icons.bolt, color: AppColors.green, size: 16),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Friday Futures',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              _statusLine(ff, launchMs, maxPlayers),
            if (!_loading && _streak >= 1) ...[
              const SizedBox(height: 12),
              _streakLine(),
            ],
            if (!_loading && ff != null && _seat != null) ...[
              const SizedBox(height: 12),
              _actions(ff),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusLine(Challenge? ff, int launchMs, int maxPlayers) {
    final joined = _joined;
    final joinedTxt = '$joined/$maxPlayers joined';
    if (ff == null || (ff.status != 'pending' && ff.status != 'active')) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'launches in ${_countdown(launchMs, _now)}',
            style: const TextStyle(color: AppColors.gold),
          ),
          Text(joinedTxt, style: const TextStyle(color: AppColors.dim)),
          const SizedBox(height: 12),
          _joinButton(),
        ],
      );
    }
    if (ff.status == 'active') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _seat != null ? '● LIVE — you\'re locked in' : '● LIVE now',
            style: const TextStyle(color: AppColors.green),
          ),
          Text(joinedTxt, style: const TextStyle(color: AppColors.dim)),
        ],
      );
    }
    // pending
    final submitted = _submitted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _seat == null
              ? 'launches in ${_countdown(launchMs, _now)}'
              : (submitted ? 'You\'re locked in' : 'Holdings locked'),
          style: TextStyle(
            color: _seat == null
                ? AppColors.gold
                : (submitted ? AppColors.green : AppColors.gold),
          ),
        ),
        Text(
          '$joinedTxt · launches in ${_countdown(launchMs, _now)}',
          style: const TextStyle(color: AppColors.dim),
        ),
      ],
    );
  }

  Widget _streakLine() {
    final submitted = _submitted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: submitted
              ? AppColors.green.withValues(alpha: 0.45)
              : AppColors.gold.withValues(alpha: 0.35),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        submitted
            ? '🔥 $_streak-week streak · added to Achievements'
            : '🔥 $_streak-week streak · submit this week\'s picks to keep it alive',
        style: TextStyle(
          fontSize: 12,
          color: submitted ? AppColors.green : AppColors.gold,
        ),
      ),
    );
  }

  Widget _actions(Challenge ff) {
    final submitted = _submitted;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => widget.onOpen(ff),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.green,
              side: BorderSide(color: AppColors.green),
              minimumSize: const Size.fromHeight(44),
            ),
            child: Text(submitted ? 'See picks' : 'Set your picks'),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Leave Friday Futures',
          icon: const Icon(
            Icons.delete_outline,
            size: 20,
            color: AppColors.red,
          ),
          onPressed: _leave,
        ),
      ],
    );
  }

  Widget _joinButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _join,
        icon: const Icon(Icons.bolt),
        label: const Text('Compete for a shot'),
      ),
    );
  }
}
