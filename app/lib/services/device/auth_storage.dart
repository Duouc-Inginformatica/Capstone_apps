import 'package:encrypted_shared_preferences/encrypted_shared_preferences.dart';

/// Almacenamiento seguro de credenciales usando EncryptedSharedPreferences
/// Solo para Android - usa Android Keystore para encriptación
class AuthStorage {
  AuthStorage._();
  static const _tokenKey = 'auth_token';
  static const _usernameKey = 'auth_username';
  static const _passwordKey = 'auth_password';

  // Instancia singleton de EncryptedSharedPreferences
  static final EncryptedSharedPreferences _storage =
      EncryptedSharedPreferences();

  static Future<void> saveToken(String token) =>
      _storage.setString(_tokenKey, token);

  static Future<String?> readToken() async {
    final token = await _storage.getString(_tokenKey);
    // EncryptedSharedPreferences retorna string vacío si no existe
    return token.isEmpty ? null : token;
  }

  static Future<void> clearToken() => _storage.remove(_tokenKey);

  static Future<void> saveCredentials(String username, String password) async {
    await _storage.setString(_usernameKey, username);
    await _storage.setString(_passwordKey, password);
  }

  static Future<StoredCredentials?> readCredentials() async {
    final username = await _storage.getString(_usernameKey);
    final password = await _storage.getString(_passwordKey);

    // EncryptedSharedPreferences retorna string vacío en lugar de null
    if (username.isEmpty || password.isEmpty) return null;

    return StoredCredentials(username: username, password: password);
  }

  static Future<void> clearCredentials() async {
    await _storage.remove(_usernameKey);
    await _storage.remove(_passwordKey);
  }
}

class StoredCredentials {
  const StoredCredentials({required this.username, required this.password});

  final String username;
  final String password;
}
