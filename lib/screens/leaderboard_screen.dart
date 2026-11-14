import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../config.dart';
import '../main.dart';

/// The "Top players" tab: the full five-section worldwide leaderboard from the
/// `public-leaderboard` edge function — best single game, top traders (by XP),
/// season leaders, longest Friday Futures streaks, and recent games. Mirrors the
/// shipped landing leaderboard.
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  List<dynamic> _best = const [];
  List<dynamic> _top = const [];
  List<dynamic> _monthly = const [];
  List<dynamic> _streaks = const [];
  List<dynamic> _recent = const [];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final res = await widget.api.edgeGet(
        AppConfig.publicLeaderboardUrl,
        auth: false,
      );
      List<dynamic> list(dynamic v) => (v is List) ? v : const [];
      if (!mounted) return;
      setState(() {
        if (res is Map) {
          _best = list(res['leaderboard']);
          _top = list(res['top']);
          _monthly = list(res['monthly']);
          _streaks = list(res['streaks']);
          _recent = list(res['recent']);
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_err!, style: const TextStyle(color: AppColors.red)),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _heading('Best single-game returns'),
                if (_best.isEmpty)
                  _empty(
                    'No finished games yet — the leaderboard lights up after the first challenges complete.',
                  )
                else
                  ..._best.asMap().entries.map(
                    (e) => _bestRow(e.value as Map, e.key),
                  ),
                const SizedBox(height: 24),
                _heading('Top traders'),
                if (_top.isEmpty)
                  _empty('No XP yet — play to climb the ranks.')
                else
                  ..._top.asMap().entries.map(
                    (e) => _topRow(e.value as Map, e.key),
                  ),
                const SizedBox(height: 24),
                _heading('Season leaders'),
                if (_monthly.isEmpty)
                  _empty('No trophies handed out yet this season.')
                else
                  ..._monthly.asMap().entries.map(
                    (e) => _monthlyRow(e.value as Map, e.key),
                  ),
                const SizedBox(height: 24),
                _heading('🔥 Longest Friday Futures streaks'),
                if (_streaks.isEmpty)
                  _empty(
                    'No streaks yet — enter Friday Futures every week to start one.',
                  )
                else
                  ..._streaks.asMap().entries.map(
                    (e) => _streakRow(e.value as Map, e.key),
                  ),
                const SizedBox(height: 24),
                _heading('Recent games'),
                if (_recent.isEmpty)
                  _empty('No finished games yet.')
                else
                  ..._recent.map((r) => _recentRow(r as Map)),
              ],
            ),
    );
  }

  Widget _heading(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      t,
      style: const TextStyle(
        color: AppColors.dim,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
      ),
    ),
  );

  Widget _empty(String t) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(t, style: const TextStyle(color: AppColors.dim)),
  );

  String _medal(int i) => i < 3 ? const ['🥇', '🥈', '🥉'][i] : '#${i + 1}';

  String _pct(num n) {
    final v = n.toDouble();
    return '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}%';
  }

  Color _retColor(num n) =>
      (n.toDouble() >= 0) ? AppColors.green : AppColors.red;

  Widget _lbRow(String medal, Widget body, Widget figure) {
    return Card(
      color: AppColors.panel,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Text(medal, style: const TextStyle(fontSize: 20)),
            ),
            const SizedBox(width: 10),
            Expanded(child: body),
            figure,
          ],
        ),
      ),
    );
  }

  Widget _bestRow(Map e, int i) {
    final game = e['game'];
    final gameName = (game is Map) ? (game['name'] ?? '') : '';
    final gameMode = (game is Map) ? (game['mode'] ?? '') : '';
    return _lbRow(
      _medal((e['rank'] as num?)?.toInt() ?? (i + 1) - 1),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${e['name'] ?? '?'}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          if (gameName.isNotEmpty)
            Text(
              'from $gameName ($gameMode)',
              style: const TextStyle(color: AppColors.dim, fontSize: 12),
            ),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _pct((e['best_return_pct'] as num?) ?? 0),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: _retColor((e['best_return_pct'] as num?) ?? 0),
            ),
          ),
          Text(
            'all-time ${_pct((e['all_time_return_pct'] as num?) ?? 0)} · ${e['games_played'] ?? 0}g',
            style: const TextStyle(color: AppColors.dim, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _topRow(Map e, int i) {
    return _lbRow(
      _medal(i),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${e['name'] ?? '?'}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          Text(
            'Lv ${e['level'] ?? 0} · ${e['title'] ?? ''}',
            style: const TextStyle(color: AppColors.dim, fontSize: 12),
          ),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${(e['xp'] as num?)?.toInt() ?? 0}',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.green,
            ),
          ),
          const Text(
            'XP',
            style: TextStyle(color: AppColors.dim, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _monthlyRow(Map e, int i) {
    final wins = (e['wins'] as num?)?.toInt() ?? 0;
    final sub = i == 0
        ? 'Season leader · $wins ${wins == 1 ? 'trophy' : 'trophies'}'
        : '$wins ${wins == 1 ? 'trophy' : 'trophies'}';
    return _lbRow(
      _medal(i),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${e['name'] ?? '?'}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          Text(sub, style: const TextStyle(color: AppColors.dim, fontSize: 12)),
        ],
      ),
      Text(
        '$wins 🏆',
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.green,
        ),
      ),
    );
  }

  Widget _streakRow(Map e, int i) {
    final count = (e['count'] as num?)?.toInt() ?? 0;
    return _lbRow(
      _medal(i),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${e['name'] ?? '?'}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          Text(
            '$count ${count == 1 ? 'week' : 'weeks'} in a row',
            style: const TextStyle(color: AppColors.dim, fontSize: 12),
          ),
        ],
      ),
      Text(
        '🔥 $count',
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.green,
        ),
      ),
    );
  }

  Widget _recentRow(Map e) {
    final top3 = (e['top3'] is List) ? (e['top3'] as List) : const [];
    final when = (e['finalized_at'] != null && e['finalized_at'] is String)
        ? _shortDate(DateTime.tryParse(e['finalized_at'].toString()))
        : '';
    return Card(
      color: AppColors.panel,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${e['name'] ?? '?'}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '(${e['mode'] ?? ''}) · $when',
                  style: const TextStyle(color: AppColors.dim, fontSize: 12),
                ),
              ],
            ),
            ...top3.asMap().entries.map((te) {
              final p = te.value as Map;
              final ret = (p['return_pct'] as num?)?.toDouble() ?? 0;
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Text(_medal(te.key), style: const TextStyle(fontSize: 13)),
                    const SizedBox(width: 6),
                    Text(
                      '${p['name'] ?? '?'}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _pct(ret),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _retColor(ret),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  String _shortDate(DateTime? d) {
    if (d == null) return '';
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${m[d.month - 1]} ${d.day}';
  }
}
