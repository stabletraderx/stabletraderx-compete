import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// A parsed deep-link intent: either a Quick Start join or a join-by-code.
/// Mirrors compete.html's `enterApp()` handling of `?quickstart=1` / `?c=CODE`.
class DeepLinkIntent {
  const DeepLinkIntent.quickstart() : quickstart = true, inviteCode = null;
  const DeepLinkIntent.invite(String code)
      : quickstart = false,
        inviteCode = code;

  final bool quickstart;
  final String? inviteCode;
}

/// Parse `https://compete.stabletraderx.com/?quickstart=1` and `.../?c=CODE`.
DeepLinkIntent? parseDeepLink(Uri uri) {
  try {
    final qs = uri.queryParameters;
    if (qs['quickstart'] == '1' || uri.path.contains('quickstart')) {
      return const DeepLinkIntent.quickstart();
    }
    final code = qs['c'];
    if (code != null && code.trim().isNotEmpty) {
      return DeepLinkIntent.invite(code.trim().toUpperCase());
    }
  } catch (_) {}
  return null;
}

/// Thin wrapper over app_links. No-ops on web (the plugin has no web backend);
/// cold-start links via [initial], warm links via [listen].
class DeepLinkService {
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;

  /// The link that launched the app (cold start), if it was a deep link.
  Future<DeepLinkIntent?> initial() async {
    if (kIsWeb) return null;
    try {
      final uri = await _appLinks.getInitialLink();
      return uri == null ? null : parseDeepLink(uri);
    } catch (_) {
      return null;
    }
  }

  /// Links arriving while the app is already running.
  void listen(void Function(DeepLinkIntent intent) onIntent) {
    if (kIsWeb) return;
    _sub ??= _appLinks.uriLinkStream.listen((uri) {
      final i = parseDeepLink(uri);
      if (i != null) onIntent(i);
    }, onError: (_) {});
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}