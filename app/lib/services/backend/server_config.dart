import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ServerConfig {
  ServerConfig._();

  static final ServerConfig instance = ServerConfig._();

  static const String _prefsKey = 'server_base_url';
  static const int _defaultPort = 8080;
  static const String _defaultScheme = 'http';
  static const String _fallbackHost = '127.0.0.1';
  static const String _fallbackBaseUrl = 'http://127.0.0.1:8080';

  final ValueNotifier<String> _baseUrlNotifier = ValueNotifier<String>('');
  SharedPreferences? _prefs;
  String? _cachedDefaultBaseUrl;

  ValueListenable<String> get baseUrlListenable => _baseUrlNotifier;

  String get baseUrl => _baseUrlNotifier.value;

  String get defaultBaseUrl => _cachedDefaultBaseUrl ?? _fallbackBaseUrl;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _ensureDefaultBaseUrl();

    // Cargar URL del servidor backend
    final stored = _prefs?.getString(_prefsKey);
    if (stored != null && stored.trim().isNotEmpty) {
      final normalized = _normalizeBaseUrl(stored);
      _baseUrlNotifier.value = normalized;
    } else {
      _baseUrlNotifier.value = defaultBaseUrl;
    }
  }

  Future<void> updateBaseUrl(String input) async {
    final normalized = _normalizeBaseUrl(input);
    _baseUrlNotifier.value = normalized;
    if (_prefs != null) {
      await _prefs!.setString(_prefsKey, normalized);
    }
  }

  Future<void> resetToDefault() async {
    await _ensureDefaultBaseUrl(forceRefresh: true);
    final base = defaultBaseUrl;
    _baseUrlNotifier.value = base;
    if (_prefs != null) {
      await _prefs!.remove(_prefsKey);
    }
  }

  String normalizeOrFallback(String? input) {
    if (input == null || input.trim().isEmpty) {
      return baseUrl;
    }
    return _normalizeBaseUrl(input);
  }

  String _normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw FormatException('Debes ingresar una URL válida.');
    }

    final prefixed = trimmed.contains('://')
        ? trimmed
        : '$_defaultScheme://$trimmed';

    final parsed = Uri.parse(prefixed);
    final scheme = parsed.scheme.isNotEmpty ? parsed.scheme : _defaultScheme;
    var host = parsed.host.isNotEmpty ? parsed.host : parsed.path;

    // Si el usuario indicó localhost o 127.0.0.1 y estamos en Android,
    // usar la IP especial del emulador para acceder al host (10.0.2.2).
    try {
      if (Platform.isAndroid && (host == 'localhost' || host == '127.0.0.1')) {
        host = '10.0.2.2';
      }
    } catch (_) {
      // Si Platform lanza (p. ej. en web) ignorar
    }

    if (host.isEmpty) {
      throw FormatException('La dirección del servidor no es válida.');
    }

    final port = parsed.hasPort ? parsed.port : _defaultPort;

    final normalized = Uri(scheme: scheme, host: host, port: port);

    return normalized.toString();
  }

  Future<void> _ensureDefaultBaseUrl({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedDefaultBaseUrl != null) {
      return;
    }

    final detected = await _detectBestBaseUrl();
    _cachedDefaultBaseUrl = detected;

    if (_baseUrlNotifier.value.isEmpty) {
      _baseUrlNotifier.value = detected;
    }
  }

  Future<String> _detectBestBaseUrl() async {
    final host = await _suggestHostIp();
    final uri = Uri(scheme: _defaultScheme, host: host, port: _defaultPort);
    return uri.toString();
  }

  Future<String> _suggestHostIp() async {
    if (kIsWeb) {
      return _fallbackHost;
    }

    try {
      if (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isWindows ||
          Platform.isLinux ||
          Platform.isMacOS) {
        final detected = await _detectLanAddress();
        if (detected != null) {
          return detected;
        }

        if (Platform.isAndroid) {
          return '10.0.2.2';
        }
      }
    } catch (_) {
      // Si algo falla volvemos al host por defecto
    }

    return _fallbackHost;
  }

  Future<String?> _detectLanAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            return addr.address;
          }
        }
      }
    } catch (_) {
      // Ignoramos fallos y devolvemos null
    }

    return null;
  }
}
