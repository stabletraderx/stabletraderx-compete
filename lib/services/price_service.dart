import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';

/// Live + historical price data, mirroring the shipped web frontend's price
/// discipline exactly:
///   1. CoinPaprika `/v1/tickers` = PRIMARY non-Binance source (free, keyless,
///      no rate-limit wall): price + 24h + 7d + market cap, keyed by SYMBOL.
///   2. Binance `/ticker/24hr` = PRIMARY price + 24h change for coins Binance
///      lists (keyless, CORS-open, cached). `/ticker/24hr` gives the 24h % the
///      old `/ticker/price` feed lacked.
///   3. CoinGecko = FINAL backstop only (kept keyless as a fallback).
///   4. >15% Binance/CoinPaprika divergence auto-detects ticker collisions;
///      LIT/BTT/XMR are hard-guarded against Binance (their Binance ticker is a
///      DIFFERENT token).
/// Never fabricate a price to hide a rate limit: keep the last-known value so a
/// partial source failure never blanks coins to 0.
class PriceService {
  PriceService();

  // ---- CoinPaprika (primary non-Binance source), keyed by ticker SYMBOL ----
  Map<String, Map<String, dynamic>>? _cpMap;
  DateTime? _cpAt;
  static const Duration _cpTtl = Duration(minutes: 15);

  /// Fetches CoinPaprika `/v1/tickers` (all coins, one call) and indexes by
  /// uppercase symbol (first-wins). Cached 15 min in-memory. 6s bound.
  Future<Map<String, Map<String, dynamic>>> _coinpaprikaTickerMap(
      {bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _cpMap != null &&
        _cpAt != null &&
        now.difference(_cpAt!) < _cpTtl) {
      return _cpMap!;
    }
    try {
      final r = await http
          .get(Uri.parse('https://api.coinpaprika.com/v1/tickers'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return _cpMap ?? {};
      final arr = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
      final bySymbol = <String, Map<String, dynamic>>{};
      double? toD(dynamic v) => (v is num) ? v.toDouble() : null;
      for (final x in arr) {
        final s = (x['symbol'] ?? '').toString().toUpperCase();
        if (s.isEmpty || bySymbol.containsKey(s)) continue;
        final q = (x['quotes'] is Map &&
                ((x['quotes'] as Map)['USD'] is Map))
            ? (x['quotes'] as Map)['USD'] as Map
            : const <String, dynamic>{};
        bySymbol[s] = {
          'id': x['id'],
          'price': toD(q['price']),
          'chg24h': toD(q['percent_change_24h']),
          'chg7d': toD(q['percent_change_7d']),
          'marketCap': (q['market_cap'] is num)
              ? (q['market_cap'] as num).toDouble()
              : 0.0,
        };
      }
      _cpMap = bySymbol;
      _cpAt = now;
      return bySymbol;
    } catch (_) {
      return _cpMap ?? {};
    }
  }

  // ---- Binance `/ticker/24hr` (price + 24h %), cached ~60s ----
  Map<String, double>? _binPrice;
  Map<String, double>? _binChg;
  DateTime? _binAt;
  static const Duration _binTtl = Duration(seconds: 60);

  Future<Map<String, double>> _binanceTicker24h({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _binPrice != null &&
        _binAt != null &&
        now.difference(_binAt!) < _binTtl) {
      return _binPrice!;
    }
    try {
      final r = await http
          .get(Uri.parse('https://data-api.binance.vision/api/v3/ticker/24hr'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return _binPrice ?? {};
      final arr = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
      final m = <String, double>{};
      final chg = <String, double>{};
      for (final x in arr) {
        final sym = x['symbol'] as String;
        final lp = double.tryParse((x['lastPrice'] ?? '').toString());
        if (lp != null) m[sym] = lp;
        final p = double.tryParse((x['priceChangePercent'] ?? '').toString());
        if (p != null) chg[sym] = p;
      }
      _binPrice = m;
      _binChg = chg;
      _binAt = now;
      return m;
    } catch (_) {
      return _binPrice ?? {};
    }
  }

  // Coins whose Binance symbol is NOT their token (delisted / rebranded /
  // ticker reused by another asset). Never trust Binance for these.
  //   LIT = Lighter (was Litentry), BTT = BitTorrent, XMR = Monero.
  static const Set<String> _binAmbiguous = {'LIT', 'BTT', 'XMR'};

  // ---- Preset markets (ticker tape + coin picker) ----
  // cgId -> {price, pct24h, chg7d}. CoinPaprika OVERWRITES with fresh values
  // (never fill-only, so prices don't freeze at first-seen); Binance fills
  // price+24h where CoinPaprika lacked it; CoinGecko backstops the rest.
  Map<String, Map<String, double>>? _markets;
  DateTime? _marketsAt;
  static const Duration _marketsTtl = Duration(seconds: 60);

  Future<Map<String, Map<String, double>>> presetMarkets(List<Coin> coins,
      {bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _markets != null &&
        _marketsAt != null &&
        now.difference(_marketsAt!) < _marketsTtl) {
      return _markets!;
    }
    // Last-known warm start so a partial failure never blanks to 0.
    final out = <String, Map<String, double>>{
      if (_markets != null)
        for (final e in _markets!.entries)
          e.key: Map<String, double>.from(e.value),
    };

    // 1) CoinPaprika primary: overwrite fresh price + 24h + 7d.
    final cp = await _coinpaprikaTickerMap();
    for (final c in coins) {
      final e = cp[c.symbol.toUpperCase()];
      if (e == null) continue;
      final price = (e['price'] is num && (e['price'] as num) > 0)
          ? (e['price'] as num).toDouble()
          : null;
      final chg24h =
          e['chg24h'] is num ? (e['chg24h'] as num).toDouble() : null;
      final chg7d = e['chg7d'] is num ? (e['chg7d'] as num).toDouble() : null;
      out[c.cgId] = {
        'price': price ?? 0,
        'pct24h': chg24h ?? 0,
        'chg7d': chg7d ?? 0,
      };
    }

    // 2) Binance fallback (non-ambiguous): fill price + 24h where CoinPaprika
    //    lacked it.
    final bin = await _binanceTicker24h();
    final binChg = _binChg ?? {};
    for (final c in coins) {
      if (_binAmbiguous.contains(c.symbol.toUpperCase())) continue;
      final bp = bin['${c.symbol}USDT'] ?? bin['${c.symbol}USD'];
      if (bp != null &&
          bp > 0 &&
          !(out[c.cgId] != null && (out[c.cgId]!['price'] ?? 0) > 0)) {
        out[c.cgId] = {
          'price': bp,
          'pct24h':
              binChg['${c.symbol}USDT'] ?? binChg['${c.symbol}USD'] ?? 0,
          'chg7d': out[c.cgId]?['chg7d'] ?? 0,
        };
      }
    }

    // 3) CoinGecko final backstop for coins still missing.
    final missing = coins
        .where((c) =>
            !(out[c.cgId] != null && (out[c.cgId]!['price'] ?? 0) > 0))
        .map((c) => c.cgId)
        .toList();
    if (missing.isNotEmpty) {
      try {
        final futures = <Future<http.Response>>[];
        for (var i = 0; i < missing.length; i += 40) {
          final chunk =
              missing.sublist(i, (i + 40).clamp(0, missing.length));
          futures.add(http
              .get(Uri.parse(
                  'https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=${chunk.join(',')}&price_change_percentage=7d,24h'))
              .timeout(const Duration(seconds: 4)));
        }
        final results = await Future.wait(futures);
        double? f(dynamic v) => (v is num) ? v.toDouble() : null;
        for (final r in results) {
          if (r.statusCode != 200) continue;
          final list =
              (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
          for (final e in list) {
            out[e['id'] as String] = {
              'price': (e['current_price'] is num)
                  ? (e['current_price'] as num).toDouble()
                  : 0,
              'pct24h': f(e['price_change_percentage_24h_in_currency']) ?? 0,
              'chg7d': f(e['price_change_percentage_7d_in_currency']) ?? 0,
            };
          }
        }
      } catch (_) {}
    }

    _markets = out;
    _marketsAt = now;
    return out;
  }

  // ---- Current USD prices (live valuation): cgId -> price ----
  // Binance primary when it agrees with CoinPaprika; CoinPaprika for coins
  // Binance lacks or where the tickers collide (>15%); CoinGecko backstop for
  // ambiguous/legacy coins (LIT/BTT/XMR + any symbol Binance doesn't trust).
  Future<Map<String, double>> currentPrices(
      List<Map<String, String>> coins) async {
    final bin = await _binanceTicker24h();
    final cp = await _coinpaprikaTickerMap();
    final out = <String, double>{};
    final needCg = <String>[];

    for (final c in coins) {
      final symbol = (c['symbol'] ?? '').toUpperCase();
      final cgId = c['cgId'] ?? '';
      if (cgId.isEmpty) continue;
      final bp = bin['${symbol}USDT'];
      final cpEntry = cp[symbol];
      final cpv = (cpEntry != null && cpEntry['price'] is num)
          ? (cpEntry['price'] as num).toDouble()
          : null;

      if (_binAmbiguous.contains(symbol)) {
        // Never trust Binance for these; CoinGecko (by cgId) is authoritative
        // for the actual token the holding references.
        needCg.add(cgId);
        continue;
      }
      if ((bp != null && bp > 0) && (cpv != null && cpv > 0)) {
        if ((bp / cpv - 1).abs() > 0.15) {
          out[cgId] = cpv; // ticker collision -> CoinPaprika
        } else {
          out[cgId] = bp; // agree -> Binance (fast + fresh)
        }
      } else if (bp != null && bp > 0) {
        out[cgId] = bp;
      } else if (cpv != null && cpv > 0) {
        out[cgId] = cpv; // no Binance pair -> CoinPaprika
      } else {
        needCg.add(cgId); // neither -> CoinGecko backstop
      }
    }

    if (needCg.isNotEmpty) {
      final cg = await _coingeckoSimple(needCg);
      for (final id in needCg) {
        final p = cg[id];
        if (p != null && p > 0) out[id] = p;
      }
    }
    return out;
  }

  // CoinGecko simple/price (backstop), cached ~30s.
  Map<String, double>? _cgCache;
  DateTime? _cgAt;
  static const Duration _cgTtl = Duration(seconds: 30);

  Future<Map<String, double>> _coingeckoSimple(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final now = DateTime.now();
    if (_cgCache != null && _cgAt != null && now.difference(_cgAt!) < _cgTtl) {
      return _cgCache!;
    }
    final map = <String, double>{};
    try {
      final r = await http
          .get(Uri.parse(
              'https://api.coingecko.com/api/v3/simple/price?ids=${ids.join(',')}&vs_currencies=usd'))
          .timeout(const Duration(seconds: 4));
      if (r.statusCode == 200) {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        body.forEach((id, v) {
          if (v is Map && v['usd'] is num) {
            map[id] = (v['usd'] as num).toDouble();
          }
        });
      }
    } catch (_) {}
    _cgCache = map;
    _cgAt = now;
    return map;
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
    if (_binAmbiguous.contains(symbol)) {
      // skip Binance — its ticker is a different token
    } else {
      try {
        final r = await http
            .get(Uri.parse(
                'https://data-api.binance.vision/api/v3/klines?symbol=${symbol}USDT&interval=1h&startTime=$startMs&endTime=$endMs&limit=1000'))
            .timeout(const Duration(seconds: 3));
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
      final r = await http
          .get(Uri.parse(
              'https://api.coingecko.com/api/v3/coins/$cgId/market_chart?vs_currency=usd&days=$days'))
          .timeout(const Duration(seconds: 3));
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