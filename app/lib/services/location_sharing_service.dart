import 'dart:developer' as developer;
// ============================================================================
// LOCATION SHARING SERVICE - Sprint 7 CAP-35
// ============================================================================
// Comparte ubicación en tiempo real con contactos de confianza
// - Links temporales con expiración
// - Actualización automática cada 10 segundos
// - Control de privacidad
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocationShare {
  LocationShare({
    required this.id,
    required this.createdAt,
    required this.expiresAt,
    required this.currentLocation,
    this.recipientName,
    this.message,
  });

  final String id;
  final DateTime createdAt;
  final DateTime expiresAt;
  LatLng currentLocation;
  final String? recipientName;
  final String? message;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
  Duration get timeRemaining => expiresAt.difference(DateTime.now());

  String get shareUrl => 'https://wayfindcl.com/share/$id';

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
    'currentLocation': {
      'lat': currentLocation.latitude,
      'lon': currentLocation.longitude,
    },
    'recipientName': recipientName,
    'message': message,
  };

  factory LocationShare.fromJson(Map<String, dynamic> json) {
    final locationData = json['currentLocation'] as Map<String, dynamic>;
    return LocationShare(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      expiresAt: DateTime.parse(json['expiresAt'] as String),
      currentLocation: LatLng(
        (locationData['lat'] as num).toDouble(),
        (locationData['lon'] as num).toDouble(),
      ),
      recipientName: json['recipientName'] as String?,
      message: json['message'] as String?,
    );
  }
}

class LocationSharingService {
  static final LocationSharingService instance = LocationSharingService._();
  LocationSharingService._();

  static const String _sharesKey = 'active_location_shares';
  final List<LocationShare> _activeShares = [];

  StreamSubscription<Position>? _locationSubscription;
  Timer? _updateTimer;

  // Stream para actualizaciones de ubicación compartida
  final _shareUpdateController = StreamController<LocationShare>.broadcast();
  Stream<LocationShare> get shareUpdates => _shareUpdateController.stream;

  /// Crear nuevo compartir de ubicación
  Future<LocationShare> createShare({
    String? recipientName,
    String? message,
    Duration duration = const Duration(hours: 1),
  }) async {
    final position = await Geolocator.getCurrentPosition();
    final currentLocation = LatLng(position.latitude, position.longitude);

    final share = LocationShare(
      id: _generateShareId(),
      createdAt: DateTime.now(),
      expiresAt: DateTime.now().add(duration),
      currentLocation: currentLocation,
      recipientName: recipientName,
      message: message,
    );

    _activeShares.add(share);
    await _saveShares();

    // Iniciar actualización automática si no está activa
    if (_locationSubscription == null) {
      _startLocationUpdates();
    }

    return share;
  }

  /// Detener compartir específico
  Future<void> stopShare(String shareId) async {
    _activeShares.removeWhere((s) => s.id == shareId);
    await _saveShares();

    // Si no hay shares activos, detener actualizaciones
    if (_activeShares.isEmpty) {
      _stopLocationUpdates();
    }
  }

  /// Detener todos los shares
  Future<void> stopAllShares() async {
    _activeShares.clear();
    await _saveShares();
    _stopLocationUpdates();
  }

  /// Obtener shares activos
  List<LocationShare> getActiveShares() {
    // Remover shares expirados
    _activeShares.removeWhere((s) => s.isExpired);
    return List.unmodifiable(_activeShares);
  }

  /// Obtener share específico
  LocationShare? getShare(String shareId) {
    try {
      return _activeShares.firstWhere((s) => s.id == shareId);
    } catch (e) {
      return null;
    }
  }

  /// Extender duración de un share
  Future<void> extendShare(String shareId, Duration additionalTime) async {
    final share = getShare(shareId);
    if (share != null) {
      final newExpiry = share.expiresAt.add(additionalTime);
      final updatedShare = LocationShare(
        id: share.id,
        createdAt: share.createdAt,
        expiresAt: newExpiry,
        currentLocation: share.currentLocation,
        recipientName: share.recipientName,
        message: share.message,
      );

      final index = _activeShares.indexWhere((s) => s.id == shareId);
      if (index != -1) {
        _activeShares[index] = updatedShare;
        await _saveShares();
      }
    }
  }

  /// Cargar shares guardados
  Future<void> loadShares() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sharesJson = prefs.getString(_sharesKey);

      if (sharesJson != null) {
        final List<dynamic> sharesList = jsonDecode(sharesJson) as List;
        _activeShares.clear();

        for (var item in sharesList) {
          final share = LocationShare.fromJson(item as Map<String, dynamic>);
          if (!share.isExpired) {
            _activeShares.add(share);
          }
        }

        // Iniciar updates si hay shares activos
        if (_activeShares.isNotEmpty) {
          _startLocationUpdates();
        }
      }
    } catch (e) {
      developer.log('Error loading location shares: $e');
    }
  }

  // ============================================================================
  // MÉTODOS PRIVADOS
  // ============================================================================

  void _startLocationUpdates() {
    // Actualizar ubicación cada 10 segundos
    _locationSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10, // Actualizar cada 10 metros
          ),
        ).listen((position) {
          _updateShareLocations(LatLng(position.latitude, position.longitude));
        });

    // Timer de respaldo cada 10 segundos
    _updateTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      try {
        final position = await Geolocator.getCurrentPosition();
        _updateShareLocations(LatLng(position.latitude, position.longitude));
      } catch (e) {
        developer.log('Error updating share location: $e');
      }
    });
  }

  void _stopLocationUpdates() {
    _locationSubscription?.cancel();
    _locationSubscription = null;
    _updateTimer?.cancel();
    _updateTimer = null;
  }

  void _updateShareLocations(LatLng newLocation) {
    for (var share in _activeShares) {
      if (!share.isExpired) {
        share.currentLocation = newLocation;
        _shareUpdateController.add(share);
      }
    }
    _saveShares();
  }

  Future<void> _saveShares() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sharesJson = jsonEncode(
        _activeShares.map((s) => s.toJson()).toList(),
      );
      await prefs.setString(_sharesKey, sharesJson);
    } catch (e) {
      developer.log('Error saving location shares: $e');
    }
  }

  String _generateShareId() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    return List.generate(
      12,
      (index) => chars[random.nextInt(chars.length)],
    ).join();
  }

  void dispose() {
    _stopLocationUpdates();
    _shareUpdateController.close();
  }
}
