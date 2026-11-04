import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';

/// Thrown for any non-2xx API response. [status] is the HTTP status, [message]
/// a human-readable reason (surfaced from the backend's `error`/`message` field
/// when present).
class ApiException implements Exception {
  ApiException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => message;
}

/// Thin Supabase client mirroring the web app's "fresh client + Authorization
/// header" pattern (never `setSession`, which rejects our non-UUID `u:<name>` sub).
///
/// - [token] is the HS256 session JWT minted by username-auth. When null, calls
///   go out anonymous (for login/signup and public reads).
/// - PostgREST `/rest/v1/*` is used for table access; edge functions are plain
///   POST/GET to `/functions/v1/*`.
class ApiClient {
  ApiClient();

  String? token;

  /// Identity key `u:<lowercase-username>` once authenticated (the `sub` of the
  /// session JWT); used to scope all table writes/reads to "me".
  String? userAddress;

  Map<String, String> _headers({bool auth = true}) {
    final h = <String, String>{'apikey': AppConfig.supabaseAnonKey};
    if (auth && token != null) h['Authorization'] = 'Bearer $token';
    return h;
  }

  Uri _rest(String path, [Map<String, String>? query]) {
    final base = Uri.parse('${AppConfig.restUrl}$path');
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: query);
  }

  // ---- PostgREST table access ----

  Future<dynamic> restGet(String path,
      {Map<String, String>? query, bool auth = true}) async {
    final r = await http.get(_rest(path, query), headers: _headers(auth: auth));
    return _decode(r);
  }

  /// First row of a filtered select, or null if none.
  Future<Map<String, dynamic>?> restGetFirst(String path,
      {Map<String, String>? query, bool auth = true}) async {
    final v = await restGet(path, query: query, auth: auth);
    if (v is List && v.isNotEmpty) return (v.first as Map).cast<String, dynamic>();
    return null;
  }

  Future<dynamic> restPost(String path, Map<String, dynamic> body,
      {bool auth = true, bool returning = true}) async {
    final headers = _headers(auth: auth);
    if (returning) headers['Prefer'] = 'return=representation';
    final r = await http.post(_rest(path),
        headers: headers, body: jsonEncode(body));
    return _decode(r);
  }

  /// Upsert by POST with `Prefer: resolution=merge-duplicates`. Use for
  /// `challenge_participants` (unique on `challenge_id,user_id`), mirroring the
  /// web's `.upsert(..., {onConflict})`.
  Future<dynamic> restUpsert(String path, Map<String, dynamic> body,
      {String? onConflict, bool auth = true}) async {
    final headers = _headers(auth: auth)
      ..['Prefer'] = 'resolution=merge-duplicates';
    final q = onConflict == null
        ? null
        : <String, String>{'on_conflict': onConflict};
    final r = await http.post(_rest(path, q), headers: headers, body: jsonEncode(body));
    return _decode(r);
  }

  Future<dynamic> restPatch(String path, Map<String, dynamic> body,
      {Map<String, String>? query, bool auth = true}) async {
    final r = await http.patch(_rest(path, query),
        headers: _headers(auth: auth), body: jsonEncode(body));
    return _decode(r);
  }

  Future<dynamic> restDelete(String path,
      {Map<String, String>? query, bool auth = true}) async {
    final r = await http.delete(_rest(path, query), headers: _headers(auth: auth));
    return _decode(r);
  }

  // ---- Edge functions ----

  Future<dynamic> edgePost(String url, {Map<String, dynamic>? body, bool auth = true}) async {
    final r = await http.post(Uri.parse(url),
        headers: _headers(auth: auth),
        body: body == null ? null : jsonEncode(body));
    return _decode(r);
  }

  Future<dynamic> edgeGet(String url, {bool auth = false}) async {
    final r = await http.get(Uri.parse(url), headers: _headers(auth: auth));
    return _decode(r);
  }

  dynamic _decode(http.Response r) {
    dynamic body;
    if (r.body.isNotEmpty) {
      try {
        body = jsonDecode(r.body);
      } catch (_) {
        body = null;
      }
    }
    if (r.statusCode >= 200 && r.statusCode < 300) return body;
    String msg = 'HTTP ${r.statusCode}';
    if (body is Map) {
      msg = (body['message'] ?? body['error'] ?? msg).toString();
    }
    throw ApiException(r.statusCode, msg);
  }
}