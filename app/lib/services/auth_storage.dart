import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthStorage {
  AuthStorage._();
  static const _tokenKey = 'auth_token';
  static const _usernameKey = 'auth_username';
  static const _passwordKey = 'auth_password';
  static final FlutterSecureStorage _storage = const FlutterSecureStorage();

  static Future<void> saveToken(String token) =>
      _storage.write(key: _tokenKey, value: token);
  static Future<String?> readToken() => _storage.read(key: _tokenKey);
  static Future<void> clearToken() => _storage.delete(key: _tokenKey);

  static Future<void> saveCredentials(String username, String password) async {
    await _storage.write(key: _usernameKey, value: username);
    await _storage.write(key: _passwordKey, value: password);
  }

  static Future<StoredCredentials?> readCredentials() async {
    final username = await _storage.read(key: _usernameKey);
    final password = await _storage.read(key: _passwordKey);
    if (username == null || password == null) return null;
    return StoredCredentials(username: username, password: password);
  }

  static Future<void> clearCredentials() async {
    await _storage.delete(key: _usernameKey);
    await _storage.delete(key: _passwordKey);
  }
}

class StoredCredentials {
  const StoredCredentials({required this.username, required this.password});

  final String username;
  final String password;
}
