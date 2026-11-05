import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';

/// Live + historical price data. Primary source = Binance's public, keyless
/// feed (`data-api.binance.vision`, sends CORS *, not geo-blocked — unlike
/// `api.binance.com` which 451s). CoinGecko's free API is the fallback for coins
/// Binance lacks. Mirrors the web app's price discipline: cache last-known
/// prices and never fabricate a number to hide a rate limit.
class PriceService {
  PriceService();

  // ---- CoinGecko preset markets (ticker feed): cached ~60s in-memory ----
  Map<String, Map<String, dynamic>>? _markets;
  DateTime? _marketsAt;
  static const Duration _marketsTtl = Duration(seconds: 60);

  /// Live price + 24h change for the given `[symbol, cgId]` coins via CoinGecko
  /// `/coins/markets` (chunked + parallel). Returns `cgId -> {price, pct24h}`.
  /// Starts from the last-known spread so a partial/failed refresh never blanks
  /// coins to 0.
  Future<Map<String, Map<String, double>>> presetMarkets(List<Coin> coins) async {
    final now = DateTime.now();
    if (_markets != null &&
        _marketsAt != null &&
        now.difference(_marketsAt!) < _marketsTtl) {
      return (_markets!['data'] as Map).cast<String, Map<String, double>>();
    }
    final out = <String, Map<String, double>>{
      if (_markets != null && _markets!['data'] is Map)
        for (final e in (_markets!['data'] as Map).entries)
          e.key: Map<String, double>.from(e.value as Map),
    };
    final ids = coins.map((c) => c.cgId).toList();
    try {
      final futures = <Future<http.Response>>[];
      for (var i = 0; i < ids.length; i += 40) {
        final chunk = ids.sublist(i, (i + 40).clamp(0, ids.length));
        futures.add(http.get(Uri.parse(
            'https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=${chunk.join(',')}&price_change_percentage=24h')));
      }
      final results = await Future.wait(futures);
      for (final r in results) {
        if (r.statusCode != 200) continue;
        final list = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
        for (final e in list) {
          final cg = e['id'] as String;
          out[cg] = {
            'price': (e['current_price'] as num?)?.toDouble() ?? 0,
            'pct24h':
                (e['price_change_percentage_24h'] as num?)?.toDouble() ?? 0,
          };
        }
      }
      _markets = {'data': out};
      _marketsAt = now;
    } catch (_) {}
    return out;
  }

  // ---- Binance ticker (cached ~5s) ----
  Map<String, double>? _ticker;
  DateTime? _tickerAt;
  static const Duration _ttl = Duration(seconds: 5);

  Future<Map<String, double>> _binanceTicker() async {
    final now = DateTime.now();
    if (_ticker != null &&
        _tickerAt != null &&
        now.difference(_tickerAt!) < _ttl) {
      return _ticker!;
    }
    try {
      final r = await http.get(
          Uri.parse('https://data-api.binance.vision/api/v3/ticker/price'));
      if (r.statusCode == 200) {
        final list = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
        final m = <String, double>{};
        for (final e in list) {
          m[e['symbol'] as String] = double.parse(e['price'] as String);
        }
        _ticker = m;
        _tickerAt = now;
        return m;
      }
    } catch (_) {
      // fall through to cache / empty
    }
    return _ticker ?? {};
  }

  /// Current USD price per coin, keyed by CoinGecko id. Binance ticker primary;
  /// CoinGecko `simple/price` fallback for the symbols Binance doesn't carry.
  // Coins whose Binance symbol is a DIFFERENT token than their CoinGecko id
  // (delisted/rebranded/ticker-taken — Litentry's "LIT" was delisted and the
  // ticker reused). Always price these from CoinGecko so the entry (locked from
  // CoinGecko) and the live quote agree. Expand as the web app's list grows.
  static const Set<String> _binanceAmbiguous = {'LIT'};

  Future<Map<String, double>> currentPrices(
      List<Map<String, String>> coins) async {
    final ticker = await _binanceTicker();
    final result = <String, double>{};
    final missing = <String, String>{}; // cgId -> symbol for CoinGecko fallback

    for (final c in coins) {
      final sym = c['symbol'] ?? '';
      final cgId = c['cgId'] ?? '';
      final binancePrice = ticker['${sym}USDT'];
      if (binancePrice != null && !_binanceAmbiguous.contains(sym)) {
        result[cgId] = binancePrice;
      } else {
        missing[cgId] = sym;
      }
    }

    if (missing.isNotEmpty) {
      final ids = missing.keys.join(',');
      try {
        final r = await http.get(Uri.parse(
            'https://api.coingecko.com/api/v3/simple/price?ids=$ids&vs_currencies=usd'));
        if (r.statusCode == 200) {
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          for (final cgId in missing.keys) {
            final p = body[cgId];
            if (p is Map && p['usd'] is num) {
              result[cgId] = (p['usd'] as num).toDouble();
            }
          }
        }
      } catch (_) {}
    }
    return result;
  }

  /// Hourly price history for a coin over [start]..[end]. Binance `klines`
  /// primary; CoinGecko `market_chart` fallback. Returns `(time, price)` points.
  Future<List<(DateTime, double)>> history(
      {required String symbol,
      required String cgId,
      required DateTime start,
      required DateTime end}) async {
    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    if (_binanceAmbiguous.contains(symbol)) {
      // skip Binance — its ticker is a different token
    } else {
      try {
        final r = await http.get(Uri.parse(
            'https://data-api.binance.vision/api/v3/klines?symbol=${symbol}USDT&interval=1h&startTime=$startMs&endTime=$endMs&limit=1000'));
        if (r.statusCode == 200) {
          final rows = (jsonDecode(r.body) as List).cast<List<dynamic>>();
          return rows
              .map((k) => (
                    DateTime.fromMillisecondsSinceEpoch((k[0] as num).toInt()),
                    double.parse(k[4] as String),
                  ))
              .toList();
        }
      } catch (_) {}
    }

    // CoinGecko fallback
    try {
      final days = ((end.difference(start).inHours / 24).ceil()).clamp(1, 90);
      final r = await http.get(Uri.parse(
          'https://api.coingecko.com/api/v3/coins/$cgId/market_chart?vs_currency=usd&days=$days'));
      if (r.statusCode == 200) {
        final prices =
            (jsonDecode(r.body) as Map<String, dynamic>)['prices'] as List;
        return prices
            .map((p) => (
                  DateTime.fromMillisecondsSinceEpoch((p[0] as num).toInt()),
                  (p[1] as num).toDouble(),
                ))
            .toList();
      }
    } catch (_) {}

    return const [];
  }
}