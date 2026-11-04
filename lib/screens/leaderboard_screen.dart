import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../config.dart';
import '../main.dart';

/// Worldwide leaderboard: top 3 across all completed games (from the public
/// `leaderboard` edge function).
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  List<dynamic> _rows = const [];
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
      final res = await widget.api.edgeGet(AppConfig.leaderboardUrl, auth: false);
      final list = (res is Map && res['leaderboard'] is List)
          ? res['leaderboard'] as List
          : const [];
      if (!mounted) return;
      setState(() {
        _rows = list;
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
    return Scaffold(
      appBar: AppBar(title: const Text('Leaderboard')),
      body: RefreshIndicator(
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
                : _rows.isEmpty
                    ? const Center(
                        child: Text('No completed games yet — go win one.',
                            style: TextStyle(color: AppColors.dim)),
                      )
                    : ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          const Text(
                            'Best single-game returns, all-time',
                            style: TextStyle(
                                color: AppColors.dim,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.6),
                          ),
                          const SizedBox(height: 12),
                          ..._rows.asMap().entries.map((e) => _row(e.key, e.value)),
                        ],
                      ),
      ),
    );
  }

  Widget _row(int index, dynamic r) {
    final row = (r as Map).cast<String, dynamic>();
    final rank = index;
    final name = row['name'] ?? '?';
    final best = (row['best_return_pct'] as num?)?.toDouble() ?? 0;
    final allTime = (row['all_time_return_pct'] as num?)?.toDouble() ?? 0;
    final games = (row['games_played'] as num?)?.toInt() ?? 0;
    final game = row['game'];
    final gameName = (game is Map) ? (game['name'] ?? '') : '';
    final gameMode = (game is Map) ? (game['mode'] ?? '') : '';

    const medals = ['🥇', '🥈', '🥉'];
    return Card(
      color: AppColors.panel,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Text(medals[rank.clamp(0, 2)], style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  if (gameName.isNotEmpty)
                    Text('$gameName · $gameMode',
                        style: const TextStyle(
                            color: AppColors.dim, fontSize: 12)),
                  Text('all-time ${_pct(allTime)} · $games game${games == 1 ? '' : 's'}',
                      style: const TextStyle(
                          color: AppColors.dim, fontSize: 12)),
                ],
              ),
            ),
            Text(_pct(best),
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: best >= 0 ? AppColors.green : AppColors.red)),
          ],
        ),
      ),
    );
  }

  String _pct(double v) =>
      '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}%';
}