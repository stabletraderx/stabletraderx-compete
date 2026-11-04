import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../main.dart';
import '../models.dart';
import '../preset_coins.dart';
import '../services/challenge_service.dart';
import '../services/price_service.dart';
import 'return_chart.dart';

/// Challenge detail. Renders pending (picks + submit + launch), active (live
/// leaderboard), and completed (frozen results) based on status.
class ChallengeScreen extends StatefulWidget {
  const ChallengeScreen({
    super.key,
    required this.api,
    required this.challengeId,
  });

  final ApiClient api;
  final String challengeId;

  @override
  State<ChallengeScreen> createState() => _ChallengeScreenState();
}

class _ChallengeScreenState extends State<ChallengeScreen> {
  late final ChallengeService _svc = ChallengeService(widget.api);
  final PriceService _price = PriceService();

  Challenge? _ch;
  List<Participant> _parts = const [];
  List<Holding> _holdings = const [];
  Map<String, double> _prices = {};
  bool _loading = true;
  bool _busy = false;
  Timer? _tick;
  final Set<String> _openBreakdowns = {};

  String get _me => widget.api.userAddress ?? '';

  bool get _isCreator => _ch?.creatorId == _me;

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 5), (_) => _tickRefresh());
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      var ch = await _svc.getChallenge(widget.challengeId);
      if (ch != null) ch = await _svc.ensureFinalized(ch) ?? ch;
      final parts = await _svc.participants(widget.challengeId);
      final holdings = await _svc.holdings(widget.challengeId);
      if (!mounted) return;
      setState(() {
        _ch = ch;
        _parts = parts;
        _holdings = holdings;
        _loading = false;
      });
      await _refreshPrices();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _tickRefresh() async {
    if (!mounted || _ch == null) return;
    if (_ch!.status == 'active') {
      await _refreshPrices();
    } else if (_ch!.status == 'pending') {
      final ch = await _svc.getChallenge(widget.challengeId);
      if (!mounted || ch == null) return;
      if (ch.status != _ch!.status) await _load();
    }
  }

  Future<void> _refreshPrices() async {
    final coins = <Map<String, String>>[];
    final seen = <String>{};
    for (final h in _holdings) {
      final id = h.coinId ?? h.assetSymbol.toLowerCase();
      if (seen.add(id)) {
        coins.add({'symbol': h.assetSymbol, 'cgId': id});
      }
    }
    if (coins.isEmpty) return;
    final p = await _price.currentPrices(coins);
    if (!mounted) return;
    setState(() => _prices = {..._prices, ...p});
  }

  Future<double?> _coinPrice(Coin c) async {
    final cached = _prices[c.cgId];
    if (cached != null) return cached;
    final p = await _price.currentPrices([
      {'symbol': c.symbol, 'cgId': c.cgId}
    ]);
    return p[c.cgId];
  }

  // ---- actions ----

  List<Holding> get _myHoldings =>
      _holdings.where((h) => h.userId == _me).toList();

  double get _mySpent =>
      _myHoldings.fold(0.0, (s, h) => s + (h.stakeAmount ?? 0));

  bool get _fullBalance {
    final remaining = (_ch?.startingValue ?? 0) - _mySpent;
    return remaining < 1e-6;
  }

  bool get _iSubmitted =>
      _parts.any((p) => p.userId == _me && p.submittedAt != null);

  Future<void> _addHolding() async {
    final ch = _ch!;
    if (_myHoldings.length >= ch.maxAssets) {
      _toast('You can only pick ${ch.maxAssets} coins.');
      return;
    }
    final pick = await _showAddHoldingDialog(
        await _price.presetMarkets(presetCoins));
    if (pick == null) return;
    setState(() => _busy = true);
    try {
      final bp = await _coinPrice(pick.coin) ?? 0;
      await _svc.addHolding(ch, pick.coin, pick.stake, bp);
      await _load();
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteHolding(Holding h) async {
    setState(() => _busy = true);
    try {
      await _svc.deleteHolding(h.id);
      await _load();
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (!_fullBalance) {
      _toast('Stake your full balance before submitting.');
      return;
    }
    setState(() => _busy = true);
    try {
      await _svc.submit(_ch!);
      await _load();
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _launch() async {
    setState(() => _busy = true);
    try {
      await _svc.launch(_ch!);
      await _load();
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteChallenge() async {
    final ok = await _confirm(
        'Delete this challenge? It removes everyone\'s holdings.');
    if (!ok) return;
    await _svc.deleteChallenge(_ch!.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
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

  Future<bool> _confirm(String msg) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(msg),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm')),
        ],
      ),
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final ch = _ch;
    return Scaffold(
      appBar: AppBar(
        title: Text(ch?.name ?? 'Challenge'),
        actions: [
          if (_isCreator && (ch?.status == 'pending'))
            IconButton(
              tooltip: 'Delete challenge',
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteChallenge,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(ch!),
    );
  }

  Widget _buildBody(Challenge ch) {
    switch (ch.status) {
      case 'pending':
        return _pendingView(ch);
      case 'active':
        return _activeView(ch);
      case 'completed':
        return _completedView(ch);
      default:
        return const Center(
            child: Text('This challenge has ended',
                style: TextStyle(color: AppColors.dim)));
    }
  }

  // ---- pending ----

  Widget _pendingView(Challenge ch) {
    final submitted = _parts.where((p) => p.submittedAt != null).length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _infoPanel(ch),
        const SizedBox(height: 16),
        _sectionTitle('Who\'s in (${_parts.length}/${ch.maxPlayers ?? '-'})'),
        ..._parts.map((p) => _participantTile(p)),
        const SizedBox(height: 16),
        _sectionTitle('Your picks (${_myHoldings.length}/${ch.maxAssets})'),
        if (_iSubmitted)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Submitted — picks locked.',
                style: TextStyle(color: AppColors.green)),
          )
        else ...[
          _myHoldingsView(ch),
          _countdownNote(ch),
          const SizedBox(height: 12),
          if (_isCreator)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '$submitted/${ch.maxPlayers ?? _parts.length} submitted — launch to lock it in and start the clock.',
                style: const TextStyle(color: AppColors.dim),
              ),
            ),
          ElevatedButton(
            onPressed: (_busy || _iSubmitted) ? null : _submit,
            child:
                Text(_fullBalance ? 'Submit picks' : 'Stake your full balance'),
          ),
          if (_isCreator) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _busy ? null : _launch,
              icon: const Icon(Icons.rocket_launch_outlined),
              label: const Text('Launch challenge'),
            ),
          ],
        ],
      ],
    );
  }

  Widget _countdownNote(Challenge ch) {
    if (!ch.quickstart) return const SizedBox.shrink();
    final my = _parts.where((p) => p.userId == _me).toList();
    if (my.isEmpty) return const SizedBox.shrink();
    final joined = my.first.joinedAt;
    if (joined == null) return const SizedBox.shrink();
    final deadline = joined.add(const Duration(minutes: 5));
    final left = deadline.difference(DateTime.now());
    final secs = left.inSeconds.clamp(0, 300);
    final color = secs <= 60 ? AppColors.red : AppColors.gold;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        'Submit within ${secs ~/ 60}m ${(secs % 60).toString().padLeft(2, '0')}s',
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _myHoldingsView(Challenge ch) {
    final budget = ch.startingValue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_myHoldings.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('No picks yet — add a coin below.',
                style: TextStyle(color: AppColors.dim)),
          )
        else
          ..._myHoldings.map((h) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(h.assetSymbol,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                    '${_stake(h)} ${ch.denomination}${h.buyPrice != null ? ' @ ${_money(h.buyPrice!)}' : ''}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, color: AppColors.red),
                  onPressed: _busy ? null : () => _deleteHolding(h),
                ),
              )),
        const SizedBox(height: 8),
        Text(
          'Staked ${_money(_mySpent)} / ${_money(budget)} ${ch.denomination}',
          style: const TextStyle(color: AppColors.dim),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed:
              (_busy || _myHoldings.length >= ch.maxAssets) ? null : _addHolding,
          icon: const Icon(Icons.add),
          label: const Text('Add coin'),
        ),
      ],
    );
  }

  Widget _participantTile(Participant p) {
    final submitted = p.submittedAt != null;
    final canRemove = _isCreator && p.userId != _me;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(p.username ?? p.userId,
          style: TextStyle(
              color: p.userId == _me ? AppColors.green : AppColors.ink)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          submitted
              ? const Icon(Icons.check_circle, color: AppColors.green, size: 18)
              : const Text('—', style: TextStyle(color: AppColors.dim)),
          if (canRemove) ...[
            const SizedBox(width: 8),
            InkWell(
              onTap: () => _removePlayer(p),
              child: const Icon(Icons.person_remove_outlined,
                  size: 18, color: AppColors.red),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _removePlayer(Participant p) async {
    final ok = await _confirm(
        'Remove ${p.username ?? p.userId} from this challenge?');
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await _svc.removeParticipant(_ch!.id, p.userId);
      await _load();
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _infoPanel(Challenge ch) {
    return Card(
      color: AppColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ch.name,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            _kv('Duration', ch.mode),
            _kv('Stakes', '${ch.denomination} ${_money(ch.startingValue)}'),
            _kv('Coins per player', '${ch.maxAssets}'),
            _inviteRow(ch),
          ],
        ),
      ),
    );
  }

  // ---- active ----

  Widget _activeView(Challenge ch) {
    final ranked = _ranked();
    final leader = ranked.isNotEmpty ? ranked.first : null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (leader != null) _leadCard(leader, ch),
        const SizedBox(height: 16),
        _sectionTitle('Leaderboard'),
        ...ranked.asMap().entries.map(
            (e) => _rankRow(e.value, e.key, ch.denomination)),
        const SizedBox(height: 16),
        _sectionTitle('Live returns'),
        ReturnChart(
          challenge: ch,
          participants: _parts,
          holdings: _holdings,
        ),
        const SizedBox(height: 16),
        _progressBar(ch),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _reportIssue,
          icon: const Icon(Icons.flag_outlined, size: 18),
          label: const Text('Report an issue'),
        ),
      ],
    );
  }

  List<({Participant p, double ret})> _ranked() {
    final byUser = <String, List<Holding>>{};
    for (final h in _holdings) {
      byUser.putIfAbsent(h.userId, () => []).add(h);
    }
    final rows = _parts.map((p) {
      if (_ch?.status == 'completed') {
        return (p: p, ret: p.finalReturnPct ?? 0);
      }
      final v = playMoneyValue(byUser[p.userId] ?? const [], _prices);
      final sv = p.startingValue;
      final ret = sv > 0 ? (v.portfolio - v.spent) / sv * 100 : 0.0;
      return (p: p, ret: ret);
    }).toList();
    rows.sort((a, b) => b.ret.compareTo(a.ret));
    return rows;
  }

  Widget _leadCard(({Participant p, double ret}) leader, Challenge ch) {
    return Card(
      color: AppColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.green),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.emoji_events, color: AppColors.gold, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('In the lead',
                      style: TextStyle(color: AppColors.dim, fontSize: 12)),
                  Text(leader.p.username ?? leader.p.userId,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            Text(_pct(leader.ret),
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: _retColor(leader.ret))),
          ],
        ),
      ),
    );
  }

  Widget _rankRow(({Participant p, double ret}) row, int index, String denom) {
    final isOpen = _openBreakdowns.contains(row.p.userId);
    final color = chartPalette[index % chartPalette.length];
    final isMe = row.p.userId == _me;
    return Column(
      children: [
        InkWell(
          onTap: () => setState(() {
            if (isOpen) {
              _openBreakdowns.remove(row.p.userId);
            } else {
              _openBreakdowns.add(row.p.userId);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${row.p.username ?? row.p.userId}${isMe ? ' (you)' : ''}',
                    style: TextStyle(
                        fontWeight: isMe ? FontWeight.w700 : FontWeight.w400,
                        color: isMe ? AppColors.green : AppColors.ink),
                  ),
                ),
                Text(_pct(row.ret),
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: _retColor(row.ret))),
                const SizedBox(width: 4),
                Icon(isOpen ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: AppColors.dim),
              ],
            ),
          ),
        ),
        if (isOpen) _breakdown(row.p, denom),
      ],
    );
  }

  Widget _breakdown(Participant p, String denom) {
    final mine = _holdings.where((h) => h.userId == p.userId).toList();
    if (mine.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(left: 22, bottom: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('No picks',
              style: TextStyle(color: AppColors.dim, fontSize: 12)),
        ),
      );
    }
    final isCompleted = _ch?.status == 'completed';
    return Padding(
      padding: const EdgeInsets.only(left: 22, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final h in mine) _holdingLine(h, isCompleted, denom)],
      ),
    );
  }

  Widget _holdingLine(Holding h, bool isCompleted, String denom) {
    final entry = h.buyPrice ?? 0;
    final cur = isCompleted
        ? (h.finalPrice ?? 0)
        : (_prices[h.coinId ?? h.assetSymbol.toLowerCase()] ?? 0);
    final hasPx = entry > 0 && cur > 0;
    final ret = hasPx ? (cur / entry - 1) * 100 : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(h.assetSymbol,
                style: const TextStyle(
                    fontWeight: FontWeight.w500, fontSize: 13)),
          ),
          Text('${_money(h.stakeAmount ?? 0)} $denom',
              style: const TextStyle(color: AppColors.dim, fontSize: 12)),
          const Spacer(),
          Text(hasPx ? '${_money(entry)} → ${_money(cur)}' : '—',
              style: const TextStyle(color: AppColors.dim, fontSize: 12)),
          const SizedBox(width: 10),
          Text(hasPx ? _pct(ret) : '—',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _retColor(ret))),
        ],
      ),
    );
  }

  Widget _progressBar(Challenge ch) {
    final start = ch.startAt;
    final end = ch.endAt;
    if (start == null || end == null) return const SizedBox.shrink();
    final total = end.difference(start).inMilliseconds;
    if (total <= 0) return const SizedBox.shrink();
    final now = DateTime.now();
    final pct =
        (now.difference(start).inMilliseconds / total * 100).clamp(0.0, 99.0);
    final left = end.difference(now);
    final leftStr = left.isNegative
        ? 'ended'
        : '${left.inHours}h ${(left.inMinutes % 60).toString().padLeft(2, '0')}m left';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct / 100,
            minHeight: 6,
            backgroundColor: AppColors.line,
            color: AppColors.green,
          ),
        ),
        const SizedBox(height: 6),
        Text('${pct.toStringAsFixed(0)}% complete · $leftStr',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.dim, fontSize: 12)),
      ],
    );
  }

  // ---- completed ----

  Widget _completedView(Challenge ch) {
    final ranked = _ranked();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Center(
          child: Icon(Icons.emoji_events, color: AppColors.gold, size: 64),
        ),
        if (ranked.isNotEmpty) ...[
          const SizedBox(height: 8),
          Center(
            child: Text(
              '${ranked.first.p.username ?? 'Winner'} takes it',
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 24),
          _sectionTitle('Final results'),
          ...ranked.asMap().entries.map(
              (e) => _rankRow(e.value, e.key, ch.denomination)),
        ],
      ],
    );
  }

  // ---- shared ----

  Widget _sectionTitle(String t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(t,
          style: const TextStyle(
              color: AppColors.dim,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6)),
    );
  }

  Widget _inviteRow(Challenge ch) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
              width: 130,
              child: Text('Invite code',
                  style: TextStyle(color: AppColors.dim))),
          Expanded(
              child: Text(ch.joinCode,
                  style: const TextStyle(fontWeight: FontWeight.w500))),
          IconButton(
            tooltip: 'Copy invite link',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.copy, size: 16, color: AppColors.green),
            onPressed: () => _copyInvite(ch),
          ),
        ],
      ),
    );
  }

  Future<void> _copyInvite(Challenge ch) async {
    final url = 'https://compete.stabletraderx.com/?c=${ch.joinCode}';
    await Clipboard.setData(ClipboardData(text: url));
    _toast('Invite link copied.');
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 130,
              child:
                  Text(k, style: const TextStyle(color: AppColors.dim))),
          Expanded(
              child: Text(v,
                  style: const TextStyle(fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }

  Color _retColor(double ret) => ret >= 0 ? AppColors.green : AppColors.red;

  String _pct(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}%';

  String _stake(Holding h) => _money(h.stakeAmount ?? 0);

  String _money(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }

  String _priceStr(double v) {
    if (v >= 1000) return v.toStringAsFixed(0);
    if (v >= 1) return v.toStringAsFixed(2);
    return v.toStringAsFixed(4);
  }

  String _marketLabel(Coin c, Map<String, Map<String, double>> markets) {
    final m = markets[c.cgId];
    final px = m?['price'] ?? 0;
    final pct = m?['pct24h'] ?? 0;
    final pxStr = px > 0 ? ' · \$${_priceStr(px)}' : '';
    final pctStr = pct != 0
        ? ' · ${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(1)}%'
        : '';
    final alt =
        altTicker.containsKey(c.cgId) ? ' (${altTicker[c.cgId]})' : '';
    return '${c.symbol}$alt — ${c.name}$pxStr$pctStr';
  }

  // ---- add-holding dialog ----

  Future<({Coin coin, double stake})?> _showAddHoldingDialog(
      Map<String, Map<String, double>> markets) async {
    Coin? coin = presetCoins.first;
    final amountCtrl = TextEditingController();
    double? stake;

    final r = await showDialog<({Coin coin, double stake})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Pick a coin'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<Coin>(
                  initialValue: presetCoins.first,
                  decoration: const InputDecoration(labelText: 'Coin'),
                  items: presetCoins
                      .map((c) => DropdownMenuItem(
                            value: c,
                            child: Text(
                              _marketLabel(c, markets),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ))
                      .toList(),
                  onChanged: (v) => setD(() => coin = v),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: amountCtrl,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Stake amount (STX\$)', hintText: 'e.g. 500'),
                  onChanged: (v) =>
                      setD(() => stake = double.tryParse(v) ?? 0),
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
                final c = coin;
                final s = stake ?? 0;
                if (c == null || s <= 0) return;
                Navigator.pop(ctx, (coin: c, stake: s));
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    amountCtrl.dispose();
    return r;
  }
}