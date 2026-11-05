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
  /// created_at.
  Future<DateTime?> pendingExpiryAt(Challenge ch) async {
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