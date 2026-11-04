import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../main.dart';
import '../models.dart';
import '../services/challenge_service.dart';
import '../widgets/ticker_tape.dart';
import 'challenge_screen.dart';
import 'leaderboard_screen.dart';
import 'settings_screen.dart';

/// Home after auth: Quick Start, your challenges (pending/active + completed),
/// create, and join-by-code.
class LobbyScreen extends StatefulWidget {
  const LobbyScreen({
    super.key,
    required this.api,
    required this.username,
    required this.onLogout,
  });

  final ApiClient api;
  final String username;
  final VoidCallback onLogout;

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  late final ChallengeService _svc = ChallengeService(widget.api);

  List<Challenge> _created = const [];
  List<Map<String, dynamic>> _participations = const [];
  bool _loading = true;
  bool _showCompleted = false;
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
      await _svc.runExpiry();
      final created = await _svc.myCreatedChallenges();
      final parts = await _svc.myParticipations();
      if (!mounted) return;
      setState(() {
        _created = created;
        _participations = parts;
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

  Map<String, Challenge> _mine() {
    final m = <String, Challenge>{};
    for (final c in _created) {
      m[c.id] = c;
    }
    for (final p in _participations) {
      if (p['removed_at'] != null || p['dismissed_at'] != null) continue;
      final ch = p['challenges'];
      if (ch is Map) {
        final c = Challenge.fromJson(ch.cast<String, dynamic>());
        m[c.id] = c;
      }
    }
    return m;
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsScreen(
        api: widget.api,
        username: widget.username,
        onLoggedOut: widget.onLogout,
      ),
    ));
  }

  Future<void> _openLeaderboard() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LeaderboardScreen(api: widget.api),
    ));
  }

  Future<void> _open(Challenge c) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChallengeScreen(api: widget.api, challengeId: c.id),
    ));
    if (mounted) _load();
  }

  Future<void> _create() async {
    final result = await _showCreateDialog();
    if (result == null) return;
    setState(() => _loading = true);
    try {
      await _svc.createChallenge(
        name: result['name']! as String,
        mode: result['mode']! as String,
        denomination: 'STX\$',
        startingValue: result['startingValue']! as double,
        maxAssets: result['maxAssets']! as int,
        maxPlayers: result['maxPlayers'] as int?,
      );
      await _load();
    } catch (e) {
      _toast(e.toString());
      await _load();
    }
  }

  Future<void> _join() async {
    final code = await _showJoinDialog();
    if (code == null || code.isEmpty) return;
    setState(() => _loading = true);
    try {
      final ch = await _svc.joinByCode(code);
      if (ch == null) {
        _toast('Challenge not found.');
      } else {
        await _open(ch);
      }
      await _load();
    } catch (e) {
      _toast(e.toString());
      await _load();
    }
  }

  Future<void> _quickStart() async {
    setState(() => _loading = true);
    try {
      final ch = await _svc.joinQuickStart();
      if (ch == null) {
        _toast('No open Quick Start challenge right now.');
      } else {
        await _open(ch);
      }
      await _load();
    } catch (e) {
      _toast(e.toString());
      await _load();
    }
  }

  Future<void> _dismiss(Challenge c) async {
    setState(() => _loading = true);
    try {
      await _svc.dismiss(c.id);
      await _load();
    } catch (e) {
      _toast(e.toString());
      await _load();
    }
  }

  Future<void> _deleteChallenge(Challenge c) async {
    setState(() => _loading = true);
    try {
      await _svc.deleteChallenge(c.id);
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

  @override
  Widget build(BuildContext context) {
    final all = _mine().values.toList();
    all.sort((a, b) =>
        (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
    final pending =
        all.where((c) => c.status == 'pending' && c.expiredAt == null).toList();
    final active = all.where((c) => c.status == 'active').toList();
    final completed = all.where((c) => c.status == 'completed').toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compete'),
        actions: [
          IconButton(
            tooltip: 'Leaderboard',
            icon: const Icon(Icons.emoji_events_outlined),
            onPressed: _openLeaderboard,
          ),
          Center(
            child: Text(
              widget.username,
              style: const TextStyle(color: AppColors.green),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
          IconButton(
            tooltip: 'Log out',
            icon: const Icon(Icons.logout),
            onPressed: widget.onLogout,
          ),
        ],
      ),
      body: Column(
        children: [
          const TickerTape(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _qsButton(),
            const SizedBox(height: 20),
            if (_loading && all.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_err != null && all.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Column(
                  children: [
                    Text(_err!, style: const TextStyle(color: AppColors.red)),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              )
            else ...[
              _sectionTitle('Your challenges'),
              if (pending.isEmpty && active.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'No active challenges — set one up below.',
                    style: TextStyle(color: AppColors.dim),
                  ),
                ),
              ...active.map((c) => _card(c)),
              ...pending.map((c) => _card(c)),
              if (completed.isNotEmpty) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () =>
                      setState(() => _showCompleted = !_showCompleted),
                  child: Text(_showCompleted
                      ? 'Hide completed games'
                      : 'Show ${completed.length} completed game${completed.length == 1 ? '' : 's'}'),
                ),
                if (_showCompleted) ...completed.map((c) => _card(c)),
              ],
              const SizedBox(height: 16),
              _sectionTitle('Set your challenge'),
              _actionButton('+ New challenge', Icons.add, _create),
              const SizedBox(height: 16),
              _sectionTitle('Join a challenge'),
              _actionButton('Enter invite code', Icons.keyboard, _join),
            ],
          ],
        ),
        ),
        ),
      ],
      ),
    );
  }

  Widget _qsButton() {
    return ElevatedButton.icon(
      onPressed: _quickStart,
      icon: const Icon(Icons.bolt),
      label: const Text('Quick Start — jump into an open game now'),
    );
  }

  Widget _sectionTitle(String t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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
  }

  Widget _actionButton(String label, IconData icon, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.ink,
        side: const BorderSide(color: AppColors.line),
        minimumSize: const Size.fromHeight(48),
      ),
    );
  }

  Widget _lobbyProgress(Challenge c) {
    final start = c.startAt;
    final end = c.endAt;
    if (start == null || end == null) return const SizedBox.shrink();
    final total = end.difference(start).inMilliseconds;
    if (total <= 0) return const SizedBox.shrink();
    final pct = (DateTime.now().difference(start).inMilliseconds / total * 100)
        .clamp(0.0, 99.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: pct / 100,
          minHeight: 5,
          backgroundColor: AppColors.line,
          color: AppColors.green,
        ),
      ),
    );
  }

  Widget _card(Challenge c) {
    final color = c.status == 'completed'
        ? AppColors.ink
        : (c.status == 'active' ? AppColors.green : AppColors.gold);
    final canDismiss = c.status == 'active' || c.status == 'completed';
    final canHardDelete =
        c.status == 'pending' && c.creatorId == widget.api.userAddress;
    return Card(
      color: AppColors.panel,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.line),
      ),
      child: Column(
        children: [
          ListTile(
            title: Text(c.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              '${c.mode} · ${c.denomination} · ${_statusLabel(c.status)}',
              style: const TextStyle(color: AppColors.dim),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (canDismiss)
                  IconButton(
                    tooltip: 'Hide from my list',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_outline,
                        size: 18, color: AppColors.red),
                    onPressed: () => _dismiss(c),
                  ),
                if (canHardDelete)
                  IconButton(
                    tooltip: 'Delete challenge',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_forever_outlined,
                        size: 18, color: AppColors.red),
                    onPressed: () => _deleteChallenge(c),
                  ),
                Icon(Icons.chevron_right, color: color),
              ],
            ),
            onTap: () => _open(c),
          ),
          if (c.status == 'active') _lobbyProgress(c),
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'pending':
        return 'pending';
      case 'active':
        return 'live';
      case 'completed':
        return 'done';
      default:
        return status;
    }
  }

  Future<Map<String, dynamic>?> _showCreateDialog() async {
    var name = '';
    var mode = '48h';
    var startingValue = 1000.0;
    var maxAssets = 3;
    int? maxPlayers;
    const startOpts = [1000.0, 5000.0, 10000.0, 100000.0, 500000.0, 1000000.0];

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Set your challenge'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name'),
                  onChanged: (v) => name = v,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: mode,
                  decoration: const InputDecoration(labelText: 'Duration'),
                  items: const [
                    DropdownMenuItem(value: '48h', child: Text('48 hours')),
                    DropdownMenuItem(value: '7d', child: Text('7 days')),
                  ],
                  onChanged: (v) => setD(() => mode = v ?? '48h'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<double>(
                  initialValue: startingValue,
                  decoration:
                      const InputDecoration(labelText: 'Starting balance (STX\$)'),
                  items: startOpts
                      .map((v) =>
                          DropdownMenuItem(value: v, child: Text(_fmtMoney(v))))
                      .toList(),
                  onChanged: (v) => setD(() => startingValue = v ?? 1000),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: maxAssets,
                  decoration: const InputDecoration(
                      labelText: 'Coins each player can pick'),
                  items: [1, 2, 3, 4, 5]
                      .map((v) =>
                          DropdownMenuItem(value: v, child: Text('$v')))
                      .toList(),
                  onChanged: (v) => setD(() => maxAssets = v ?? 3),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int?>(
                  initialValue: maxPlayers,
                  decoration: const InputDecoration(
                      labelText: 'Max players (optional)'),
                  items: [for (var i = 2; i <= 10; i++) i]
                      .map((v) =>
                          DropdownMenuItem(value: v, child: Text('$v')))
                      .toList(),
                  onChanged: (v) => setD(() => maxPlayers = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                if (name.trim().isEmpty) return;
                Navigator.pop(ctx, {
                  'name': name.trim(),
                  'mode': mode,
                  'startingValue': startingValue,
                  'maxAssets': maxAssets,
                  'maxPlayers': maxPlayers,
                });
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _showJoinDialog() async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join by invite code'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          autocorrect: false,
          textCapitalization: TextCapitalization.characters,
          decoration:
              const InputDecoration(labelText: 'Code', hintText: 'XXXXXXXX'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim().toUpperCase()),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return code;
  }

  String _fmtMoney(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(0)}K';
    return v.toStringAsFixed(0);
  }
}