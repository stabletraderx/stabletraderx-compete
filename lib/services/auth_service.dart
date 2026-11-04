import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../config.dart';

/// Sign-up / login / sign-out against the `username-auth` edge function.
///
/// The session JWT is persisted in secure storage (Android Keystore / iOS
/// Keychain) on mobile. On web (preview only) there is no secure store, so we
/// mirror the shipped web app's plain `localStorage` via shared_preferences —
/// same key, same trust level as the existing product.
class AuthService {
  AuthService();

  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  static const String _tokenKey = 'stx_token';
  static const String _userKey = 'stx_user';

  Future<String?> _read(String key) async {
    if (kIsWeb) {
      return (await SharedPreferences.getInstance()).getString(key);
    }
    return _secure.read(key: key);
  }

  Future<void> _write(String key, String value) async {
    if (kIsWeb) {
      await (await SharedPreferences.getInstance()).setString(key, value);
      return;
    }
    await _secure.write(key: key, value: value);
  }

  Future<void> _delete(String key) async {
    if (kIsWeb) {
      await (await SharedPreferences.getInstance()).remove(key);
      return;
    }
    await _secure.delete(key: key);
  }

  Future<String?> get storedToken => _read(_tokenKey);
  Future<String?> get storedUsername => _read(_userKey);

  Future<Map<String, dynamic>> login(
      ApiClient api, String username, String password) async {
    final res = await api.edgePost(
      AppConfig.usernameAuthUrl,
      body: {'mode': 'login', 'username': username, 'password': password},
      auth: false,
    );
    return _apply(api, res);
  }

  Future<Map<String, dynamic>> signup(
      ApiClient api, String username, String password, String email) async {
    final res = await api.edgePost(
      AppConfig.usernameAuthUrl,
      body: {
        'mode': 'signup',
        'username': username,
        'password': password,
        'email': email,
      },
      auth: false,
    );
    return _apply(api, res);
  }

  Future<Map<String, dynamic>> _apply(ApiClient api, dynamic res) async {
    final map = (res as Map).cast<String, dynamic>();
    final token = map['token'] as String?;
    final username = map['username'] as String?;
    if (token != null) {
      api.token = token;
      await _write(_tokenKey, token);
    }
    if (username != null) {
      await _write(_userKey, username);
    }
    return map;
  }

  Future<String?> restore(ApiClient api) async {
    final token = await _read(_tokenKey);
    if (token == null || token.isEmpty) return null;
    api.token = token;
    return _read(_userKey);
  }

  Future<void> logout() async {
    await _delete(_tokenKey);
    await _delete(_userKey);
  }
}