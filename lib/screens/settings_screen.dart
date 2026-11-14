import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../config.dart';
import '../main.dart';
import '../services/challenge_service.dart';

/// Profile tab: identity, rank (level · title · XP), Friday Futures streak
/// readout, the Levels & XP ladder, the achievements badge wall, and the
/// account actions (report / sign out / delete). Mirrors the shipped web
/// profile page.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.api,
    required this.username,
    required this.onLoggedOut,
  });

  final ApiClient api;
  final String username;
  final VoidCallback onLoggedOut;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final ChallengeService _svc = ChallengeService(widget.api);
  bool _busy = false;

  int _xp = 0;
  int _level = 1;
  String _title = 'Rookie';
  List<Map<String, dynamic>> _ladder = const [];
  List<Map<String, dynamic>> _catalog = const [];
  Map<String, String> _earned = {}; // badge -> earned_at
  int _streak = 0;
  String? _email;

  String get _me => widget.api.userAddress ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final xpRow = await _svc.myXp();
      final titles = await _svc.levelTitles();
      final catalog = await _svc.achievementsCatalog();
      final earned = await _svc.myAchievements();
      final streak = await _svc.myStreak();
      String? email;
      try {
        email = await _svc.myEmail();
      } catch (_) {}

      final titleByLevel = <int, String>{};
      for (final t in titles) {
        titleByLevel[(t['level'] as num?)?.toInt() ?? 0] = (t['title'] ?? '')
            .toString();
      }
      final xp = (xpRow?['xp'] as num?)?.toInt() ?? 0;
      final level = (xpRow?['level'] as num?)?.toInt() ?? 1;

      final earnedMap = <String, String>{};
      for (final e in earned) {
        earnedMap[(e['badge'] ?? '').toString()] = (e['earned_at'] ?? '')
            .toString();
      }
      final ladder = [...titles]
        ..sort(
          (a, b) =>
              ((a['level'] as num?)?.toInt() ?? 0) -
              ((b['level'] as num?)?.toInt() ?? 0),
        );

      if (!mounted) return;
      setState(() {
        _xp = xp;
        _level = level;
        _title = titleByLevel[level] ?? 'Rookie';
        _ladder = ladder;
        _catalog = catalog;
        _earned = earnedMap;
        _streak = streak;
        _email = email;
      });
    } catch (_) {}
  }

  Future<void> _reportIssue() async {
    final ctrl = TextEditingController();
    final msg = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report an issue'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          maxLength: 500,
          decoration: const InputDecoration(hintText: 'What went wrong?'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (msg == null || msg.isEmpty) return;

    setState(() => _busy = true);
    try {
      await widget.api.restPost('/reports', {
        'user_id': _me,
        'message': msg,
        'status': 'new',
      }, returning: false);
      _toast('Thanks — your report was sent.');
    } catch (e) {
      _toast('Could not send: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This permanently deletes your profile, picks, and credentials. '
          'Challenges you created are preserved for the other players, with '
          'your identity detached. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await widget.api.edgePost(AppConfig.deleteAccountUrl, body: {});
      widget.onLoggedOut();
    } catch (e) {
      _toast('Delete failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _identityCard(),
        const SizedBox(height: 16),
        _rankAndStreakCard(),
        const SizedBox(height: 16),
        _levelsCard(),
        const SizedBox(height: 16),
        _achievementsCard(),
        const SizedBox(height: 16),
        _accountActions(),
      ],
    );
  }

  Widget _identityCard() {
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.username,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            _email ?? 'no email on file',
            style: const TextStyle(color: AppColors.dim),
          ),
        ],
      ),
    );
  }

  Widget _rankAndStreakCard() {
    final children = <Widget>[
      Row(
        children: [
          Expanded(
            child: Text(
              'Lv $_level · $_title · ${_fmt(_xp)} XP',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      if (_streak >= 1) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.gold.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '🔥 $_streak-week streak · Friday Futures',
            style: const TextStyle(fontSize: 12, color: AppColors.gold),
          ),
        ),
      ],
    ];
    return _card(
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _levelsCard() {
    final next = _ladder.where(
      (t) => ((t['level'] as num?)?.toInt() ?? 0) == _level + 1,
    );
    Widget head;
    if (next.isNotEmpty) {
      final nx = next.first;
      final xpMin = (nx['xp_min'] as num?)?.toInt() ?? 0;
      final gap = (xpMin - _xp).clamp(0, 1 << 31);
      head = Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          'Next level ${nx['title'] ?? ''} at ${_fmt(xpMin)} XP — ${_fmt(gap)} XP to go',
          style: const TextStyle(fontSize: 13),
        ),
      );
    } else {
      head = const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text(
          "Max level reached — you're at the top.",
          style: TextStyle(fontSize: 13),
        ),
      );
    }

    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Levels & XP',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          head,
          ..._ladder.map((t) {
            final lv = (t['level'] as num?)?.toInt() ?? 0;
            final isCur = lv == _level;
            final isDone = lv < _level;
            return Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isCur
                    ? AppColors.green.withValues(alpha: 0.12)
                    : isDone
                    ? AppColors.panel
                    : AppColors.panel,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isCur ? AppColors.green : AppColors.line,
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      'Lv $lv',
                      style: TextStyle(
                        color: isCur ? AppColors.green : AppColors.dim,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${t['title'] ?? ''}',
                      style: TextStyle(
                        color: isCur
                            ? AppColors.green
                            : (isDone ? AppColors.ink : AppColors.dim),
                        fontWeight: isCur ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                  Text(
                    '${_fmt((t['xp_min'] as num?)?.toInt() ?? 0)} XP',
                    style: const TextStyle(color: AppColors.dim, fontSize: 12),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 8),
          const Text(
            'Earn XP by: finish +10 · win +50 · invite a friend +20 · Friday Futures streak +15 · each badge +10',
            style: TextStyle(color: AppColors.dim, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _achievementsCard() {
    final levelBadges = _catalog
        .where((b) => (b['badge'] ?? '').toString().startsWith('level_'))
        .toList();
    final otherBadges = _catalog
        .where((b) => !(b['badge'] ?? '').toString().startsWith('level_'))
        .toList();

    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Achievements',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          if (levelBadges.isNotEmpty) ...[
            const SizedBox(height: 8),
            _groupLabel('Levels'),
            _badgeWall(levelBadges, isLevel: true),
          ],
          if (otherBadges.isNotEmpty) ...[
            const SizedBox(height: 12),
            _groupLabel('Achievements'),
            _badgeWall(otherBadges, isLevel: false),
          ],
          if (_catalog.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No badges yet.',
                style: TextStyle(color: AppColors.dim),
              ),
            ),
        ],
      ),
    );
  }

  Widget _groupLabel(String t) => Text(
    t.toUpperCase(),
    style: const TextStyle(
      color: AppColors.dim,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.0,
    ),
  );

  Widget _badgeWall(
    List<Map<String, dynamic>> badges, {
    required bool isLevel,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: badges.map((b) => _badgeTile(b, isLevel)).toList(),
    );
  }

  Widget _badgeTile(Map<String, dynamic> b, bool isLevel) {
    final badge = (b['badge'] ?? '').toString();
    final has = _earned.containsKey(badge);
    final earnedAt = _earned[badge] ?? '';
    final xpRaw = (b['xp'] as num?)?.toInt() ?? 0;
    final xpLine = xpRaw > 0
        ? (isLevel ? '${_fmt(xpRaw)} XP' : '+${_fmt(xpRaw)} XP')
        : null;

    return Container(
      width: 150,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: has ? AppColors.green.withValues(alpha: 0.10) : AppColors.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: has ? AppColors.green.withValues(alpha: 0.5) : AppColors.line,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${b['emoji'] ?? ''}', style: const TextStyle(fontSize: 22)),
          const SizedBox(height: 4),
          Text(
            '${b['name'] ?? ''}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            '${b['description'] ?? ''}',
            style: const TextStyle(color: AppColors.dim, fontSize: 11),
          ),
          if (xpLine != null) ...[
            const SizedBox(height: 6),
            Text(
              xpLine,
              style: const TextStyle(color: AppColors.green, fontSize: 11),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            has
                ? '✓ Earned${earnedAt.isNotEmpty ? ' ${_shortDate(earnedAt)}' : ''}'
                : 'Locked',
            style: TextStyle(
              color: has ? AppColors.green : AppColors.dim,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _accountActions() {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.flag_outlined),
          title: const Text('Report an issue'),
          subtitle: const Text(
            'Send feedback to the team',
            style: TextStyle(color: AppColors.dim),
          ),
          onTap: _busy ? null : _reportIssue,
        ),
        const Divider(color: AppColors.line),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Sign out'),
          subtitle: const Text(
            'Return to the login screen',
            style: TextStyle(color: AppColors.dim),
          ),
          onTap: _busy ? null : widget.onLoggedOut,
        ),
        const Divider(color: AppColors.line),
        ListTile(
          leading: const Icon(
            Icons.delete_forever_outlined,
            color: AppColors.red,
          ),
          title: const Text(
            'Delete account',
            style: TextStyle(color: AppColors.red),
          ),
          subtitle: const Text(
            'Permanent — removes your data',
            style: TextStyle(color: AppColors.dim),
          ),
          onTap: _busy ? null : _deleteAccount,
        ),
      ],
    );
  }

  Widget _card(Widget child) {
    return Card(
      color: AppColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.line),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }

  String _fmt(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(0)}K';
    return v.toString();
  }

  String _shortDate(String iso) {
    final d = DateTime.tryParse(iso);
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
