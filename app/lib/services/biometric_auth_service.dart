import 'dart:io';
import 'dart:developer' as developer;
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// Servicio de autenticación biométrica para usuarios no videntes
/// Funcionalidades:
/// - Login con huella/FaceID
/// - Registro de nueva cuenta con biometría
/// - Asociación biometría ↔ credenciales de usuario
class BiometricAuthService {
  static final BiometricAuthService instance = BiometricAuthService._internal();
  factory BiometricAuthService() => instance;
  BiometricAuthService._internal();

  final LocalAuthentication _localAuth = LocalAuthentication();
  static const String _prefixBiometricUser = 'biometric_user_';
  static const String _currentUserKey = 'current_biometric_user';

  /// Verifica si el dispositivo tiene capacidad biométrica
  Future<bool> canCheckBiometrics() async {
    try {
      return await _localAuth.canCheckBiometrics;
    } on PlatformException {
      return false;
    }
  }

  /// Obtiene los tipos de biometría disponibles
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } on PlatformException {
      return <BiometricType>[];
    }
  }

  /// Genera un ID único basado en la biometría del dispositivo
  Future<String> _generateBiometricId() async {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final deviceInfo = await _getDeviceIdentifier();
    final combined = '$timestamp-$deviceInfo';

    final bytes = utf8.encode(combined);
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 16);
  }

  /// Genera un token único del dispositivo para verificar en backend
  /// Este token NO cambia y se usa para verificar si la huella ya está registrada
  Future<String> getBiometricDeviceToken() async {
    final deviceInfo = await _getDeviceIdentifier();
    final bytes = utf8.encode(deviceInfo);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Obtiene un identificador único del dispositivo usando device_info_plus
  Future<String> _getDeviceIdentifier() async {
    try {
      final deviceInfoPlugin = DeviceInfoPlugin();

      if (Platform.isAndroid) {
        final androidInfo = await deviceInfoPlugin.androidInfo;
        return 'android-${androidInfo.id}';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfoPlugin.iosInfo;
        return 'ios-${iosInfo.identifierForVendor}';
      }

      return 'unknown-${DateTime.now().millisecondsSinceEpoch}';
    } catch (e) {
      developer.log('⚠️ [DEVICE] Error obteniendo ID del dispositivo: $e');
      return 'fallback-${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  /// Autentica con biometría
  /// Retorna el usuario asociado si existe, null si no hay usuario registrado
  Future<Map<String, dynamic>?> authenticateWithBiometrics({
    required String localizedReason,
  }) async {
    try {
      developer.log('🔐 [BIOMETRIC] Iniciando autenticación biométrica...');

      final authenticated = await _localAuth.authenticate(
        localizedReason: localizedReason,
        options: const AuthenticationOptions(
          stickyAuth: true, // Mantener autenticación activa
          biometricOnly: true, // Solo biometría, no PIN/patrón
        ),
      );

      if (!authenticated) {
        developer.log('❌ [BIOMETRIC] Autenticación cancelada o fallida');
        return null;
      }

      developer.log('✅ [BIOMETRIC] Autenticación exitosa');

      // Obtener usuario asociado a esta biometría
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString(_currentUserKey);

      if (userId == null) {
        developer.log('ℹ️ [BIOMETRIC] No hay usuario registrado con esta biometría');
        return null;
      }

      final userDataJson = prefs.getString('$_prefixBiometricUser$userId');
      if (userDataJson == null) {
        developer.log('⚠️ [BIOMETRIC] Usuario registrado pero sin datos');
        return null;
      }

      final userData = json.decode(userDataJson) as Map<String, dynamic>;
      developer.log('👤 [BIOMETRIC] Usuario encontrado: ${userData['username']}');

      return userData;
    } on PlatformException catch (e) {
      developer.log('❌ [BIOMETRIC] Error: $e');
      return null;
    }
  }

  /// Registra un nuevo usuario con biometría
  Future<bool> registerUserWithBiometrics({
    required String username,
    String? email,
    required String localizedReason,
  }) async {
    try {
      developer.log('📝 [BIOMETRIC] Registrando nuevo usuario: $username');

      // Primero autenticar con biometría
      final authenticated = await _localAuth.authenticate(
        localizedReason: localizedReason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );

      if (!authenticated) {
        developer.log('❌ [BIOMETRIC] Registro cancelado - no se autenticó');
        return false;
      }

      // Generar ID único para este usuario
      final userId = await _generateBiometricId();

      // Guardar datos del usuario
      final userData = {
        'userId': userId,
        'username': username,
        'email': email ?? '',
        'registeredAt': DateTime.now().toIso8601String(),
        'lastLogin': DateTime.now().toIso8601String(),
      };

      final prefs = await SharedPreferences.getInstance();

      // Guardar datos del usuario
      await prefs.setString(
        '$_prefixBiometricUser$userId',
        json.encode(userData),
      );

      // Marcar este usuario como el actual
      await prefs.setString(_currentUserKey, userId);

      developer.log('✅ [BIOMETRIC] Usuario registrado exitosamente');
      developer.log('   UserID: $userId');
      developer.log('   Username: $username');
      developer.log('   Email: ${email ?? "no proporcionado"}');

      return true;
    } on PlatformException catch (e) {
      developer.log('❌ [BIOMETRIC] Error en registro: $e');
      return false;
    }
  }

  /// Verifica si existe un usuario registrado con biometría en este dispositivo
  Future<bool> hasRegisteredUser() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_currentUserKey);
    return userId != null;
  }

  /// Obtiene el usuario actual sin autenticar (solo para verificación)
  Future<Map<String, dynamic>?> getCurrentUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_currentUserKey);

    if (userId == null) return null;

    final userDataJson = prefs.getString('$_prefixBiometricUser$userId');
    if (userDataJson == null) return null;

    return json.decode(userDataJson) as Map<String, dynamic>;
  }

  /// Actualiza el timestamp del último login
  Future<void> updateLastLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_currentUserKey);

    if (userId == null) return;

    final userDataJson = prefs.getString('$_prefixBiometricUser$userId');
    if (userDataJson == null) return;

    final userData = json.decode(userDataJson) as Map<String, dynamic>;
    userData['lastLogin'] = DateTime.now().toIso8601String();

    await prefs.setString(
      '$_prefixBiometricUser$userId',
      json.encode(userData),
    );
  }

  /// Elimina el usuario actual (cerrar sesión)
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_currentUserKey);
    developer.log('👋 [BIOMETRIC] Sesión cerrada');
  }

  /// Elimina completamente un usuario (borrar cuenta)
  Future<void> deleteUser() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_currentUserKey);

    if (userId == null) return;

    await prefs.remove('$_prefixBiometricUser$userId');
    await prefs.remove(_currentUserKey);
    developer.log('🗑️ [BIOMETRIC] Usuario eliminado');
  }

  /// Verifica si el dispositivo tiene biometría disponible
  Future<bool> isAvailable() async {
    try {
      final canCheck = await canCheckBiometrics();
      if (!canCheck) return false;

      final types = await getAvailableBiometrics();
      return types.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Verifica si ya existe un usuario registrado en este dispositivo
  Future<bool> checkUserExists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString(_currentUserKey);
      return userId != null;
    } catch (e) {
      return false;
    }
  }

  /// Login biométrico simplificado
  /// Autentica con huella y retorna true si el usuario existe
  Future<bool> login() async {
    try {
      final user = await authenticateWithBiometrics(
        localizedReason: 'Autenticación requerida para acceder',
      );

      if (user != null) {
        await updateLastLogin();
        return true;
      }

      return false;
    } catch (e) {
      developer.log('❌ [BIOMETRIC-LOGIN] Error: $e');
      return false;
    }
  }

  /// Obtiene una descripción legible de los tipos de biometría disponibles
  String getBiometricTypeDescription(List<BiometricType> types) {
    if (types.isEmpty) return 'Sin biometría disponible';

    final descriptions = <String>[];
    for (final type in types) {
      switch (type) {
        case BiometricType.face:
          descriptions.add('reconocimiento facial');
          break;
        case BiometricType.fingerprint:
          descriptions.add('huella dactilar');
          break;
        case BiometricType.iris:
          descriptions.add('reconocimiento de iris');
          break;
        case BiometricType.strong:
          descriptions.add('biometría fuerte');
          break;
        case BiometricType.weak:
          descriptions.add('biometría débil');
          break;
      }
    }

    return descriptions.join(' o ');
  }
}
