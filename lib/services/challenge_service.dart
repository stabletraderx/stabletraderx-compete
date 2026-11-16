import 'dart:math';

import '../api/api_client.dart';
import '../config.dart';
import '../models.dart';

/// Challenge lifecycle, mirroring the web client's exact calls and payloads.
class ChallengeService {
  ChallengeService(this.api);

  final ApiClient api;

  String get _me => api.userAddress ?? '';

  static const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  String _newCode() {
    final r = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < 8; i++) {
      sb.write(_alphabet[r.nextInt(_alphabet.length)]);
    }
    return sb.toString();
  }

  // ---- lobby ----

  Future<List<Challenge>> myCreatedChallenges() async {
    final v = await api.restGet('/challenges', query: {
      'creator_id': 'eq.$_me',
      'order': 'created_at.desc',
      'limit': '20',
    });
    return _challengeList(v);
  }

  /// Raw participant rows I'm in, each with a nested `challenges` object.
  Future<List<Map<String, dynamic>>> myParticipations() async {
    final v = await api.restGet('/challenge_participants', query: {
      'user_id': 'eq.$_me',
      'select': 'challenge_id,removed_at,dismissed_at,challenges(*)',
      'limit': '200',
    });
    if (v is List) return v.cast<Map<String, dynamic>>();
    return const [];
  }

  // ---- create / join ----

  Future<Challenge?> createChallenge({
    required String name,
    required String mode, // "48h" | "7d"
    required String denomination,
    required double startingValue,
    required int maxAssets,
    int? maxPlayers,
  }) async {
    final hours = mode == '7d' ? 168 : 48;
    final v = await api.restPost('/challenges', {
      'creator_id': _me,
      'name': name,
      'mode': mode,
      'duration_hours': hours,
      'status': 'pending',
      'join_code': _newCode(),
      'denomination': denomination,
      'starting_value': startingValue,
      'max_assets': maxAssets,
      'max_players': ?maxPlayers,
    });
    final created = _single(v);
    if (created == null) return null;
    // creator is a participant too (same flat starting balance as everyone)
    await api.restPost('/challenge_participants', {
      'challenge_id': created.id,
      'user_id': _me,
      'starting_value': startingValue,
    }, returning: false);
    return created;
  }

  Future<Challenge?> joinByCode(String code) async {
    final ch = await _challengeByCode(code);
    if (ch == null) return null;
    await _enroll(ch);
    return ch;
  }

  Future<Challenge?> joinQuickStart() async {
    final v = await api.restGet('/challenges', query: {
      'quickstart': 'eq.true',
      'status': 'eq.pending',
      'order': 'created_at.asc',
      'limit': '1',
    });
    final ch = _single(v);
    if (ch == null) return null;
    await _enroll(ch);
    return ch;
  }

  Future<Challenge?> _challengeByCode(String code) async {
    final v = await api.restGet('/challenges', query: {'join_code': 'eq.$code'});
    return _single(v);
  }

  Future<Challenge?> getChallenge(String id) async {
    final v = await api.restGet('/challenges', query: {'id': 'eq.$id'});
    return _single(v);
  }

  /// When a pending challenge auto-expires (matches expire-pending's rule):
  /// >=2 active participants -> 24h after the LAST joined_at; solo -> 24h after
  /// created_at. Friday Futures never expires — it launches on its own Friday
  /// schedule (server kicks non-submitters at 1pm ET), so it has no 24h clock.
  Future<DateTime?> pendingExpiryAt(Challenge ch) async {
    if (ch.eventType == 'friday-futures') return null;
    final v = await api.restGet('/challenge_participants', query: {
      'challenge_id': 'eq.${ch.id}',
      'removed_at': 'is.null',
      'order': 'joined_at.asc',
    });
    final parts = (v is List) ? v : const [];
    if (parts.length >= 2) {
      final last =
          DateTime.tryParse((parts.last as Map)['joined_at']?.toString() ?? '');
      if (last != null) return last.add(const Duration(hours: 24));
    }
    if (ch.createdAt != null) {
      return ch.createdAt!.add(const Duration(hours: 24));
    }
    return null;
  }

  /// Enroll (or re-enroll) me as a participant. Upsert on
  /// `challenge_id,user_id` so a fresh join and a re-entry after removal both
  /// reset `removed_at` + the joined clock.
  Future<void> _enroll(Challenge ch) async {
    await api.restUpsert(
      '/challenge_participants',
      {
        'challenge_id': ch.id,
        'user_id': _me,
        'starting_value': ch.startingValue,
        'removed_at': null,
        'joined_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'challenge_id,user_id',
    );
  }

  // ---- detail ----

  Future<List<Participant>> participants(String challengeId) async {
    final v = await api.restGet('/challenge_participants', query: {
      'challenge_id': 'eq.$challengeId',
      'removed_at': 'is.null',
      'select': '*,profiles(username,display_name)',
      'order': 'joined_at.asc',
    });
    if (v is List) {
      return v
          .map((e) => Participant.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    }
    return const [];
  }

  Future<List<Holding>> holdings(String challengeId) async {
    final v = await api.restGet('/holdings', query: {
      'challenge_id': 'eq.$challengeId',
    });
    if (v is List) {
      return v
          .map((e) => Holding.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    }
    return const [];
  }

  Future<int> activeChallengeCount() async {
    final v = await api.restGet('/challenge_participants', query: {
      'user_id': 'eq.$_me',
      'select': 'challenge_id,removed_at,challenges(status)',
    });
    if (v is! List) return 0;
    var n = 0;
    for (final e in v) {
      final m = e as Map;
      if (m['removed_at'] != null) continue;
      final ch = m['challenges'];
      final status = ch is Map ? ch['status'] : null;
      if (status != 'completed') n++;
    }
    return n;
  }

  // ---- holdings / submit / launch / lifecycle ----

  Future<void> addHolding(Challenge ch, Coin coin, double stake, double buyPrice) async {
    final qty = buyPrice > 0 ? stake / buyPrice : 0;
    await api.restPost('/holdings', {
      'user_id': _me,
      'challenge_id': ch.id,
      'asset_symbol': coin.symbol,
      'asset_name': coin.name,
      'coin_id': coin.cgId,
      'quantity': qty,
      'buy_price': buyPrice > 0 ? buyPrice : null,
      'stake_amount': stake,
      'source': 'manual',
    }, returning: false);
  }

  Future<void> deleteHolding(String holdingId) async {
    await api.restDelete('/holdings', query: {'id': 'eq.$holdingId'});
  }

  Future<void> submit(Challenge ch) async {
    await api.restPatch(
      '/challenge_participants',
      {'submitted_at': DateTime.now().toUtc().toIso8601String()},
      query: {'challenge_id': 'eq.${ch.id}', 'user_id': 'eq.$_me'},
    );
  }

  Future<void> launch(Challenge ch) async {
    await api.edgePost(AppConfig.launchUrl, body: {'challengeId': ch.id});
  }

  Future<void> runExpiry() async {
    await api.edgePost(AppConfig.expiryUrl, body: {}, auth: false);
  }

  /// Finalize an active challenge whose end_at has passed (idempotent, called
  /// lazily on detail load). Returns the (possibly updated) challenge.
  Future<Challenge?> ensureFinalized(Challenge ch) async {
    if (ch.status != 'active') return ch;
    if (ch.endAt == null || ch.endAt!.isAfter(DateTime.now())) return ch;
    try {
      await api.edgePost(AppConfig.finalizeUrl,
          body: {'challengeId': ch.id}, auth: false);
    } catch (_) {}
    return await getChallenge(ch.id) ?? ch;
  }

  Future<void> deleteChallenge(String challengeId) async {
    await api.restDelete('/challenges',
        query: {'id': 'eq.$challengeId', 'creator_id': 'eq.$_me'});
  }

  Future<void> dismiss(String challengeId) async {
    await api.restPatch(
      '/challenge_participants',
      {'dismissed_at': DateTime.now().toUtc().toIso8601String()},
      query: {'challenge_id': 'eq.$challengeId', 'user_id': 'eq.$_me'},
    );
  }

  /// Creator removes an idle player (deletes their holdings + seat).
  Future<void> removeParticipant(String challengeId, String userId) async {
    await api.restDelete('/holdings',
        query: {'challenge_id': 'eq.$challengeId', 'user_id': 'eq.$userId'});
    await api.restDelete('/challenge_participants',
        query: {'challenge_id': 'eq.$challengeId', 'user_id': 'eq.$userId'});
  }

  // ---- Friday Futures (weekly event) ----

  /// The current Friday Futures race (latest pending/active), or null if none.
  Future<Challenge?> fridayFutures() async {
    final v = await api.restGet('/challenges', query: {
      'event_type': 'eq.friday-futures',
      'status': 'in.(pending,active)',
      'order': 'created_at.desc',
      'limit': '1',
    });
    return _single(v);
  }

  /// My participant row for a challenge, or null if I never joined.
  Future<Map<String, dynamic>?> mySeat(String challengeId) async {
    return api.restGetFirst('/challenge_participants',
        query: {'challenge_id': 'eq.$challengeId', 'user_id': 'eq.$_me'});
  }

  /// Join (or re-join) Friday Futures. Returns null on success (caller opens
  /// the game) or a user-facing error string if blocked.
  Future<String?> joinFridayFutures(Challenge ch) async {
    if (ch.status != 'pending') {
      return 'Friday Futures has already kicked off — catch the next one.';
    }
    final existing = await mySeat(ch.id);
    if (existing != null && existing['removed_at'] == null) {
      return null; // already in — just open the game
    }
    if (ch.maxPlayers != null) {
      final v = await api.restGet('/challenge_participants', query: {
        'challenge_id': 'eq.${ch.id}',
        'removed_at': 'is.null',
        'select': 'id',
        'limit': '200',
      });
      final count = (v is List) ? v.length : 0;
      if (count >= ch.maxPlayers!) {
        return 'Friday Futures is full (${ch.maxPlayers} players).';
      }
    }
    if (existing != null) {
      // Re-entering after backing out: drop stale picks for a fresh start.
      await api.restDelete('/holdings',
          query: {'challenge_id': 'eq.${ch.id}', 'user_id': 'eq.$_me'});
    }
    await _enroll(ch);
    return null;
  }

  /// Soft-remove me from Friday Futures (a distinct action from dismiss).
  Future<void> leaveFridayFutures(String challengeId) async {
    await api.restPatch(
      '/challenge_participants',
      {'removed_at': DateTime.now().toUtc().toIso8601String()},
      query: {'challenge_id': 'eq.$challengeId', 'user_id': 'eq.$_me'},
    );
  }

  /// POST ff-streak {challengeId} -> new streak count (or null on error).
  Future<int?> recordFridayStreak(String challengeId) async {
    final r = await api.edgePost(AppConfig.ffStreakUrl,
        body: {'challengeId': challengeId});
    if (r is Map && r['streak'] is num) return (r['streak'] as num).toInt();
    return null;
  }

  /// POST ff-streak {challengeId, leave:true} -> revert this week's streak.
  Future<void> revertFridayStreak(String challengeId) async {
    await api.edgePost(AppConfig.ffStreakUrl,
        body: {'challengeId': challengeId, 'leave': true});
  }

  /// My current Friday Futures streak count (0 if none).
  Future<int> myStreak() async {
    final v = await api.restGetFirst('/user_streaks',
        query: {'user_id': 'eq.$_me', 'kind': 'eq.friday-futures'});
    if (v == null || v['count'] == null) return 0;
    return (v['count'] as num).toInt();
  }

  // ---- profile / gamification ----

  /// My XP row (xp, level), or null if I have no XP yet.
  Future<Map<String, dynamic>?> myXp() async {
    return api.restGetFirst('/user_xp', query: {'user_id': 'eq.$_me'});
  }

  /// Level titles ladder (level, xp_min, title), ascending.
  Future<List<Map<String, dynamic>>> levelTitles() async {
    final v = await api.restGet('/level_titles', query: {'order': 'level.asc'});
    return (v is List) ? v.cast<Map<String, dynamic>>() : const [];
  }

  /// Achievements catalog (badge, name, description, emoji, sort_order, xp).
  Future<List<Map<String, dynamic>>> achievementsCatalog() async {
    final v =
        await api.restGet('/achievements', query: {'order': 'sort_order.asc'});
    return (v is List) ? v.cast<Map<String, dynamic>>() : const [];
  }

  /// Badges I've earned (badge, earned_at).
  Future<List<Map<String, dynamic>>> myAchievements() async {
    final v = await api.restGet('/user_achievements',
        query: {'user_id': 'eq.$_me', 'select': 'badge,earned_at'});
    return (v is List) ? v.cast<Map<String, dynamic>>() : const [];
  }

  /// My email via the my-account edge fn (PII-safe — email is NOT on profiles).
  Future<String?> myEmail() async {
    final r = await api.edgeGet(AppConfig.myAccountUrl, auth: true);
    if (r is Map && r['email'] != null) return r['email'].toString();
    return null;
  }

  // ---- coin packs (level-gated coin unlocks) ----

  /// My unlocked pack ids (from user_unlocked_packs).
  Future<Set<String>> myUnlockedPackIds() async {
    final v = await api.restGet('/user_unlocked_packs',
        query: {'user_id': 'eq.$_me', 'select': 'pack_id'});
    if (v is! List) return <String>{};
    return v
        .map((e) => (e is Map ? e['pack_id']?.toString() : null) ?? '')
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  /// The pack catalog (pack_id, name, unlock_level), ascending by level.
  Future<List<CoinPack>> coinPacks() async {
    final v =
        await api.restGet('/coin_packs', query: {'order': 'unlock_level.asc'});
    if (v is List) {
      return v
          .map((e) => CoinPack.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    }
    return const [];
  }

  /// All pack coins (is_base=false), grouped by pack_id, alphabetized by ticker.
  Future<Map<String, List<Coin>>> packCoinsByPack() async {
    final v = await api.restGet('/coins',
        query: {'is_base': 'eq.false', 'select': 'coin_id,ticker,name,pack_id'});
    final m = <String, List<Coin>>{};
    if (v is List) {
      for (final e in v) {
        final j = (e as Map).cast<String, dynamic>();
        final pack = j['pack_id']?.toString();
        if (pack == null || pack.isEmpty) continue;
        (m[pack] ??= []).add(Coin(
          j['ticker']?.toString() ?? '',
          j['name']?.toString() ?? '',
          j['coin_id']?.toString() ?? '',
        ));
      }
    }
    m.forEach((_, list) => list.sort((a, b) => a.symbol.compareTo(b.symbol)));
    return m;
  }

  /// My unlocked packs with their coins, ordered by unlock level — the picker's
  /// "folders" above the base coins. Empty when I have unlocked no packs.
  Future<List<UnlockedPack>> unlockedPackCoins() async {
    final ids = await myUnlockedPackIds();
    if (ids.isEmpty) return const [];
    final packs = await coinPacks();
    final byPack = await packCoinsByPack();
    final out = <UnlockedPack>[];
    for (final p in packs) {
      if (!ids.contains(p.packId)) continue;
      final coins = byPack[p.packId];
      if (coins == null || coins.isEmpty) continue;
      out.add(UnlockedPack(p, coins));
    }
    return out;
  }

  // ---- reward inbox ----

  /// Fetch my undrained reward events, mark them drained, and return them
  /// newest-first so the caller can show them (daisy-chained). Mirrors the
  /// web's drainRewards().
  Future<List<RewardEvent>> drainRewards() async {
    final v = await api.restGet('/reward_events', query: {
      'user_id': 'eq.$_me',
      'drained_at': 'is.null',
      'order': 'created_at.asc',
    });
    final events = <RewardEvent>[];
    if (v is List) {
      for (final e in v) {
        events.add(RewardEvent.fromJson((e as Map).cast<String, dynamic>()));
      }
    }
    if (events.isEmpty) return const [];
    final ids = events.map((e) => e.id).toList();
    await api.restPatch('/reward_events', {
      'drained_at': DateTime.now().toUtc().toIso8601String(),
    }, query: {
      'id': 'in.(${ids.join(',')})',
      'user_id': 'eq.$_me',
    });
    return events.reversed.toList();
  }

  // ---- helpers ----

  List<Challenge> _challengeList(dynamic v) {
    if (v is List) {
      return v
          .map((e) => Challenge.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    }
    return const [];
  }

  Challenge? _single(dynamic v) {
    if (v is List && v.isNotEmpty) {
      return Challenge.fromJson((v.first as Map).cast<String, dynamic>());
    }
    if (v is Map) return Challenge.fromJson(v.cast<String, dynamic>());
    return null;
  }
}