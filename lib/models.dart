/// Data models + helpers for the Compete backend (mirrors the web client's
/// shapes exactly — wrong column names here surface as silent RLS failures).
library;

DateTime? _dt(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  return DateTime.tryParse(v.toString());
}

double _d(dynamic v) =>
    (v is num) ? v.toDouble() : (double.tryParse(v?.toString() ?? '') ?? 0.0);

int? _i(dynamic v) => (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '');

String _s(dynamic v) => v?.toString() ?? '';

class Challenge {
  final String id;
  final String? creatorId;
  final String name;
  final String mode; // "48h" | "7d"
  final String status; // pending | active | completed | expired
  final String joinCode;
  final String denomination;
  final double startingValue;
  final int maxAssets;
  final int? maxPlayers;
  final bool quickstart;
  final int? durationHours;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? finalizedAt;
  final DateTime? expiredAt;
  final DateTime? createdAt;

  const Challenge({
    required this.id,
    this.creatorId,
    required this.name,
    required this.mode,
    required this.status,
    required this.joinCode,
    required this.denomination,
    required this.startingValue,
    required this.maxAssets,
    this.maxPlayers,
    this.quickstart = false,
    this.durationHours,
    this.startAt,
    this.endAt,
    this.finalizedAt,
    this.expiredAt,
    this.createdAt,
  });

  factory Challenge.fromJson(Map<String, dynamic> j) => Challenge(
        id: _s(j['id']),
        creatorId: j['creator_id']?.toString(),
        name: _s(j['name']),
        mode: _s(j['mode']),
        status: _s(j['status']),
        joinCode: _s(j['join_code']),
        denomination: _s(j['denomination']),
        startingValue: _d(j['starting_value']),
        maxAssets: _i(j['max_assets']) ?? 3,
        maxPlayers: _i(j['max_players']),
        quickstart: j['quickstart'] == true,
        durationHours: _i(j['duration_hours']),
        startAt: _dt(j['start_at']),
        endAt: _dt(j['end_at']),
        finalizedAt: _dt(j['finalized_at']),
        expiredAt: _dt(j['expired_at']),
        createdAt: _dt(j['created_at']),
      );
}

class Participant {
  final String id;
  final String challengeId;
  final String userId;
  final DateTime? joinedAt;
  final double startingValue;
  final DateTime? submittedAt;
  final double? finalReturnPct;
  final double? finalValue;
  final DateTime? removedAt;
  final DateTime? dismissedAt;
  final String? username;

  const Participant({
    required this.id,
    required this.challengeId,
    required this.userId,
    this.joinedAt,
    this.startingValue = 0,
    this.submittedAt,
    this.finalReturnPct,
    this.finalValue,
    this.removedAt,
    this.dismissedAt,
    this.username,
  });

  factory Participant.fromJson(Map<String, dynamic> j) => Participant(
        id: _s(j['id']),
        challengeId: _s(j['challenge_id']),
        userId: _s(j['user_id']),
        joinedAt: _dt(j['joined_at']),
        startingValue: _d(j['starting_value']),
        submittedAt: _dt(j['submitted_at']),
        finalReturnPct:
            j['final_return_pct'] == null ? null : _d(j['final_return_pct']),
        finalValue: j['final_value'] == null ? null : _d(j['final_value']),
        removedAt: _dt(j['removed_at']),
        dismissedAt: _dt(j['dismissed_at']),
        username: j['profiles'] is Map
            ? (j['profiles'] as Map)['username']?.toString()
            : null,
      );
}

class Holding {
  final String id;
  final String userId;
  final String? challengeId;
  final String assetSymbol;
  final String? assetName;
  final String? coinId;
  final double quantity;
  final double? buyPrice;
  final double? stakeAmount;
  final double? finalPrice;
  final String source;

  const Holding({
    required this.id,
    required this.userId,
    this.challengeId,
    required this.assetSymbol,
    this.assetName,
    this.coinId,
    this.quantity = 0,
    this.buyPrice,
    this.stakeAmount,
    this.finalPrice,
    this.source = 'manual',
  });

  factory Holding.fromJson(Map<String, dynamic> j) => Holding(
        id: _s(j['id']),
        userId: _s(j['user_id']),
        challengeId: j['challenge_id']?.toString(),
        assetSymbol: _s(j['asset_symbol']),
        assetName: j['asset_name']?.toString(),
        coinId: j['coin_id']?.toString(),
        quantity: _d(j['quantity']),
        buyPrice: j['buy_price'] == null ? null : _d(j['buy_price']),
        stakeAmount:
            j['stake_amount'] == null ? null : _d(j['stake_amount']),
        finalPrice: j['final_price'] == null ? null : _d(j['final_price']),
        source: _s(j['source']),
      );
}

/// A coin in the curated preset list (ticker, display name, CoinGecko id).
class Coin {
  final String symbol;
  final String name;
  final String cgId;
  const Coin(this.symbol, this.name, this.cgId);
}

/// Valuation used for leaderboards (live) and trophies (frozen):
/// spent = Σ stake, portfolio = Σ stake × (price/entry). A holding with no entry
/// price counts flat (stake) rather than fabricating a return. Return % =
/// (portfolio − spent) / starting_value × 100.
({double spent, double portfolio}) playMoneyValue(
    List<Holding> holdings, Map<String, double> prices) {
  double spent = 0;
  double portfolio = 0;
  for (final h in holdings) {
    final stake = h.stakeAmount ?? 0;
    spent += stake;
    final entry = h.buyPrice ?? 0;
    if (entry > 0) {
      final key = h.coinId ?? h.assetSymbol.toLowerCase();
      final cur = prices[key] ?? entry;
      portfolio += stake * (cur / entry);
    } else {
      portfolio += stake;
    }
  }
  return (spent: spent, portfolio: portfolio);
}