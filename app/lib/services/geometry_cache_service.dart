/// Servicio de caché de geometrías offline para rutas frecuentes
/// Almacena geometrías comprimidas en almacenamiento persistente
library;

import 'dart:convert';
import 'dart:developer' as dev;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'polyline_compression.dart';

/// Servicio singleton para cachear geometrías de rutas offline
/// 
/// **Características:**
/// - Almacenamiento persistente con SharedPreferences
/// - Compresión automática con Douglas-Peucker
/// - Gestión de TTL (Time To Live) para expiración
/// - Límite de tamaño de caché configurable
/// 
/// **Uso:**
/// ```dart
/// // Guardar ruta en caché
/// await GeometryCacheService.instance.saveRoute(
///   key: 'plaza_italia_to_providencia',
///   geometry: routePoints,
///   compress: true,
/// );
/// 
/// // Recuperar ruta desde caché
/// final cached = await GeometryCacheService.instance.getRoute(
///   key: 'plaza_italia_to_providencia',
/// );
/// if (cached != null) {
///   print('Ruta cargada desde caché offline');
/// }
/// ```
class GeometryCacheService {
  GeometryCacheService._();
  static final GeometryCacheService instance = GeometryCacheService._();

  static const String _prefix = 'geometry_cache_';
  static const String _metadataKey = 'geometry_cache_metadata';
  static const int _maxCacheEntries = 50; // Máximo de rutas en caché
  static const Duration _defaultTtl = Duration(days: 7); // Expiración por defecto

  SharedPreferences? _prefs;
  bool _initialized = false;

  /// Inicializa el servicio de caché
  Future<void> initialize() async {
    if (_initialized) return;
    
    try {
      _prefs = await SharedPreferences.getInstance();
      _initialized = true;
      _log('✅ GeometryCacheService inicializado');
      
      // Limpiar entradas expiradas
      await _cleanExpiredEntries();
    } catch (e, st) {
      _log('❌ Error inicializando GeometryCacheService: $e', error: e, stackTrace: st);
    }
  }

  /// Guarda una geometría en caché
  /// 
  /// **Parámetros:**
  /// - `key`: Identificador único de la ruta (ej: "origin_to_destination")
  /// - `geometry`: Lista de puntos LatLng
  /// - `compress`: Si true, aplica compresión Douglas-Peucker
  /// - `epsilon`: Tolerancia de compresión (solo si compress=true)
  /// - `ttl`: Tiempo de vida del caché
  /// - `metadata`: Datos adicionales (nombre, distancia, etc.)
  /// 
  /// **Returns:** true si se guardó exitosamente
  Future<bool> saveRoute({
    required String key,
    required List<LatLng> geometry,
    bool compress = true,
    double epsilon = 0.0001,
    Duration ttl = _defaultTtl,
    Map<String, dynamic>? metadata,
  }) async {
    await initialize();
    if (_prefs == null) return false;

    try {
      // Comprimir si es necesario
      final pointsToSave = compress 
          ? PolylineCompression.compress(points: geometry, epsilon: epsilon)
          : geometry;

      // Serializar geometría
      final serialized = _serializeGeometry(pointsToSave);
      
      // Crear entrada de caché
      final entry = {
        'geometry': serialized,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'expiresAt': DateTime.now().add(ttl).millisecondsSinceEpoch,
        'originalPoints': geometry.length,
        'cachedPoints': pointsToSave.length,
        'compressed': compress,
        'metadata': metadata ?? {},
      };

      // Guardar en SharedPreferences
      final cacheKey = '$_prefix$key';
      final success = await _prefs!.setString(cacheKey, jsonEncode(entry));

      if (success) {
        // Actualizar metadata
        await _updateMetadata(key, entry);
        
        final compression = compress 
            ? ' (${geometry.length} → ${pointsToSave.length} pts, '
              '${((1 - pointsToSave.length / geometry.length) * 100).toStringAsFixed(1)}%)'
            : '';
        _log('💾 Ruta guardada en caché: $key$compression');
        
        // Verificar límite de caché
        await _enforceMaxCacheSize();
      }

      return success;
    } catch (e, st) {
      _log('❌ Error guardando ruta en caché: $e', error: e, stackTrace: st);
      return false;
    }
  }

  /// Recupera una geometría desde caché
  /// 
  /// **Returns:** Lista de puntos LatLng o null si no existe/expiró
  Future<List<LatLng>?> getRoute(String key) async {
    await initialize();
    if (_prefs == null) return null;

    try {
      final cacheKey = '$_prefix$key';
      final data = _prefs!.getString(cacheKey);
      
      if (data == null) {
        _log('📭 No hay caché para: $key');
        return null;
      }

      final entry = jsonDecode(data) as Map<String, dynamic>;
      
      // Verificar expiración
      final expiresAt = entry['expiresAt'] as int;
      if (DateTime.now().millisecondsSinceEpoch > expiresAt) {
        _log('⏰ Caché expirado para: $key');
        await deleteRoute(key);
        return null;
      }

      // Deserializar geometría
      final geometry = _deserializeGeometry(entry['geometry'] as String);
      
      final compressed = entry['compressed'] as bool? ?? false;
      final info = compressed 
          ? ' (comprimido: ${entry['cachedPoints']} pts)'
          : ' (${geometry.length} pts)';
      _log('📦 Ruta cargada desde caché: $key$info');

      return geometry;
    } catch (e, st) {
      _log('❌ Error recuperando ruta desde caché: $e', error: e, stackTrace: st);
      return null;
    }
  }

  /// Elimina una ruta del caché
  Future<bool> deleteRoute(String key) async {
    await initialize();
    if (_prefs == null) return false;

    try {
      final cacheKey = '$_prefix$key';
      final success = await _prefs!.remove(cacheKey);
      
      if (success) {
        await _removeFromMetadata(key);
        _log('🗑️ Ruta eliminada del caché: $key');
      }
      
      return success;
    } catch (e, st) {
      _log('❌ Error eliminando ruta del caché: $e', error: e, stackTrace: st);
      return false;
    }
  }

  /// Limpia todo el caché
  Future<void> clearAll() async {
    await initialize();
    if (_prefs == null) return;

    try {
      final keys = _prefs!.getKeys();
      final cacheKeys = keys.where((k) => k.startsWith(_prefix));
      
      for (final key in cacheKeys) {
        await _prefs!.remove(key);
      }
      
      await _prefs!.remove(_metadataKey);
      _log('🧹 Caché de geometrías limpiado completamente');
    } catch (e, st) {
      _log('❌ Error limpiando caché: $e', error: e, stackTrace: st);
    }
  }

  /// Obtiene estadísticas del caché
  Future<Map<String, dynamic>> getStats() async {
    await initialize();
    if (_prefs == null) {
      return {'error': 'Not initialized'};
    }

    try {
      final metadata = await _getMetadata();
      final keys = metadata.keys.toList();
      
      int totalOriginalPoints = 0;
      int totalCachedPoints = 0;
      int totalSize = 0;
      
      for (final key in keys) {
        final entry = metadata[key] as Map<String, dynamic>;
        totalOriginalPoints += entry['originalPoints'] as int? ?? 0;
        totalCachedPoints += entry['cachedPoints'] as int? ?? 0;
      }

      // Calcular tamaño estimado
      totalSize = totalCachedPoints * 16; // 16 bytes por LatLng

      return {
        'totalRoutes': keys.length,
        'maxRoutes': _maxCacheEntries,
        'totalOriginalPoints': totalOriginalPoints,
        'totalCachedPoints': totalCachedPoints,
        'compressionRatio': totalOriginalPoints > 0
            ? (1 - totalCachedPoints / totalOriginalPoints)
            : 0.0,
        'estimatedSizeKB': (totalSize / 1024).toStringAsFixed(2),
        'routes': keys,
      };
    } catch (e, st) {
      _log('❌ Error obteniendo stats: $e', error: e, stackTrace: st);
      return {'error': e.toString()};
    }
  }

  /// Verifica si existe una ruta en caché (sin cargarla)
  Future<bool> hasRoute(String key) async {
    await initialize();
    if (_prefs == null) return false;

    final cacheKey = '$_prefix$key';
    return _prefs!.containsKey(cacheKey);
  }

  /// Serializa geometría a JSON compacto
  String _serializeGeometry(List<LatLng> geometry) {
    final coordinates = geometry.map((point) {
      return [point.latitude, point.longitude];
    }).toList();
    
    return jsonEncode(coordinates);
  }

  /// Deserializa geometría desde JSON
  List<LatLng> _deserializeGeometry(String serialized) {
    final coordinates = jsonDecode(serialized) as List<dynamic>;
    
    return coordinates.map((coords) {
      final pair = coords as List<dynamic>;
      return LatLng(pair[0] as double, pair[1] as double);
    }).toList();
  }

  /// Actualiza metadata de caché
  Future<void> _updateMetadata(String key, Map<String, dynamic> entry) async {
    try {
      final metadata = await _getMetadata();
      metadata[key] = {
        'timestamp': entry['timestamp'],
        'expiresAt': entry['expiresAt'],
        'originalPoints': entry['originalPoints'],
        'cachedPoints': entry['cachedPoints'],
        'compressed': entry['compressed'],
        'metadata': entry['metadata'],
      };
      
      await _prefs!.setString(_metadataKey, jsonEncode(metadata));
    } catch (e) {
      _log('⚠️ Error actualizando metadata: $e');
    }
  }

  /// Remueve entrada de metadata
  Future<void> _removeFromMetadata(String key) async {
    try {
      final metadata = await _getMetadata();
      metadata.remove(key);
      await _prefs!.setString(_metadataKey, jsonEncode(metadata));
    } catch (e) {
      _log('⚠️ Error removiendo metadata: $e');
    }
  }

  /// Obtiene metadata completa
  Future<Map<String, dynamic>> _getMetadata() async {
    try {
      final data = _prefs!.getString(_metadataKey);
      if (data == null) return {};
      return jsonDecode(data) as Map<String, dynamic>;
    } catch (e) {
      return {};
    }
  }

  /// Limpia entradas expiradas
  Future<void> _cleanExpiredEntries() async {
    try {
      final metadata = await _getMetadata();
      final now = DateTime.now().millisecondsSinceEpoch;
      final expiredKeys = <String>[];

      for (final entry in metadata.entries) {
        final data = entry.value as Map<String, dynamic>;
        final expiresAt = data['expiresAt'] as int;
        
        if (now > expiresAt) {
          expiredKeys.add(entry.key);
        }
      }

      for (final key in expiredKeys) {
        await deleteRoute(key);
      }

      if (expiredKeys.isNotEmpty) {
        _log('🧹 Limpiadas ${expiredKeys.length} entradas expiradas');
      }
    } catch (e) {
      _log('⚠️ Error limpiando entradas expiradas: $e');
    }
  }

  /// Fuerza el límite máximo de entradas en caché
  Future<void> _enforceMaxCacheSize() async {
    try {
      final metadata = await _getMetadata();
      
      if (metadata.length <= _maxCacheEntries) return;

      // Ordenar por timestamp (más antiguos primero)
      final entries = metadata.entries.toList()
        ..sort((a, b) {
          final aTime = (a.value as Map<String, dynamic>)['timestamp'] as int;
          final bTime = (b.value as Map<String, dynamic>)['timestamp'] as int;
          return aTime.compareTo(bTime);
        });

      // Eliminar las más antiguas
      final toDelete = entries.length - _maxCacheEntries;
      for (int i = 0; i < toDelete; i++) {
        await deleteRoute(entries[i].key);
      }

      _log('🗑️ Eliminadas $toDelete rutas antiguas (límite: $_maxCacheEntries)');
    } catch (e) {
      _log('⚠️ Error aplicando límite de caché: $e');
    }
  }

  void _log(String message, {Object? error, StackTrace? stackTrace}) {
    dev.log(
      message,
      name: 'GeometryCacheService',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
