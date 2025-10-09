// ============================================================================
// ADDRESS VALIDATION SERVICE - Sprint 3 CAP-23
// ============================================================================
// Valida direcciones usando geocoding inverso y OSM Nominatim
// Detecta direcciones inexistentes o mal formadas
// ============================================================================

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

enum AddressValidationStatus { valid, invalid, uncertain, networkError }

class AddressValidationResult {
  const AddressValidationResult({
    required this.status,
    required this.confidence,
    this.suggestedAddress,
    this.displayName,
    this.details,
    this.coordinates,
  });

  final AddressValidationStatus status;
  final double confidence; // 0.0 - 1.0
  final String? suggestedAddress;
  final String? displayName;
  final String? details;
  final LatLng? coordinates;

  bool get isValid => status == AddressValidationStatus.valid;
  bool get needsConfirmation => status == AddressValidationStatus.uncertain;
}

class AddressValidationService {
  static final AddressValidationService instance = AddressValidationService._();
  AddressValidationService._();

  static const String nominatimUrl = 'https://nominatim.openstreetmap.org';
  static const Duration timeout = Duration(seconds: 10);

  // Caché de validaciones recientes
  final Map<String, AddressValidationResult> _cache = {};

  /// Valida una dirección de texto
  Future<AddressValidationResult> validateAddress(
    String address, {
    String? city,
    String? country,
  }) async {
    final normalizedAddress = _normalizeAddress(address);

    // Verificar caché
    if (_cache.containsKey(normalizedAddress)) {
      return _cache[normalizedAddress]!;
    }

    try {
      // Construir query completa
      final fullAddress = _buildFullAddress(address, city, country);

      // Buscar dirección en Nominatim
      final searchResults = await _searchAddress(fullAddress);

      if (searchResults.isEmpty) {
        final result = AddressValidationResult(
          status: AddressValidationStatus.invalid,
          confidence: 0.0,
          details: 'No se encontró ninguna dirección que coincida',
        );
        _cache[normalizedAddress] = result;
        return result;
      }

      // Analizar mejor resultado
      final bestMatch = searchResults.first;
      final confidence = _calculateConfidence(bestMatch, address);

      AddressValidationStatus status;
      if (confidence >= 0.8) {
        status = AddressValidationStatus.valid;
      } else if (confidence >= 0.5) {
        status = AddressValidationStatus.uncertain;
      } else {
        status = AddressValidationStatus.invalid;
      }

      final result = AddressValidationResult(
        status: status,
        confidence: confidence,
        suggestedAddress: bestMatch['display_name'] as String?,
        displayName: bestMatch['display_name'] as String?,
        coordinates: LatLng(
          double.parse(bestMatch['lat'] as String),
          double.parse(bestMatch['lon'] as String),
        ),
        details: _getValidationDetails(status, confidence),
      );

      _cache[normalizedAddress] = result;
      return result;
    } catch (e) {
      print('Error validating address: $e');
      return AddressValidationResult(
        status: AddressValidationStatus.networkError,
        confidence: 0.0,
        details: 'Error de red al validar dirección',
      );
    }
  }

  /// Valida coordenadas GPS verificando que correspondan a una ubicación real
  Future<AddressValidationResult> validateCoordinates(
    LatLng coordinates, {
    String? expectedAddress,
  }) async {
    try {
      // Geocoding inverso
      final addressData = await _reverseGeocode(coordinates);

      if (addressData == null) {
        return AddressValidationResult(
          status: AddressValidationStatus.invalid,
          confidence: 0.0,
          details: 'No se encontró ninguna dirección en estas coordenadas',
        );
      }

      final displayName = addressData['display_name'] as String?;
      final type = addressData['type'] as String?;

      // Verificar que es una ubicación válida (no en medio del océano, etc.)
      final isValidLocation = _isValidLocationType(type);

      double confidence = 1.0;
      if (expectedAddress != null && displayName != null) {
        confidence = _calculateTextSimilarity(
          expectedAddress.toLowerCase(),
          displayName.toLowerCase(),
        );
      }

      final result = AddressValidationResult(
        status: isValidLocation
            ? AddressValidationStatus.valid
            : AddressValidationStatus.uncertain,
        confidence: confidence,
        displayName: displayName,
        coordinates: coordinates,
        details: isValidLocation
            ? 'Ubicación válida'
            : 'La ubicación puede no ser accesible',
      );

      return result;
    } catch (e) {
      print('Error validating coordinates: $e');
      return AddressValidationResult(
        status: AddressValidationStatus.networkError,
        confidence: 0.0,
        details: 'Error al verificar ubicación',
      );
    }
  }

  /// Sugiere direcciones basándose en texto parcial
  Future<List<Map<String, dynamic>>> suggestAddresses(
    String partialAddress, {
    String? city,
    String? country,
    int limit = 5,
  }) async {
    try {
      final fullAddress = _buildFullAddress(partialAddress, city, country);
      final results = await _searchAddress(fullAddress, limit: limit);

      return results.map((result) {
        return {
          'display_name': result['display_name'],
          'lat': double.parse(result['lat'] as String),
          'lon': double.parse(result['lon'] as String),
          'type': result['type'],
          'importance': result['importance'],
        };
      }).toList();
    } catch (e) {
      print('Error suggesting addresses: $e');
      return [];
    }
  }

  // ============================================================================
  // MÉTODOS PRIVADOS
  // ============================================================================

  Future<List<dynamic>> _searchAddress(String address, {int limit = 5}) async {
    final uri = Uri.parse('$nominatimUrl/search').replace(
      queryParameters: {
        'q': address,
        'format': 'json',
        'addressdetails': '1',
        'limit': limit.toString(),
      },
    );

    final response = await http
        .get(uri, headers: {'User-Agent': 'WayFindCL/1.0'})
        .timeout(timeout);

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as List<dynamic>;
    }

    throw Exception('Nominatim search failed: ${response.statusCode}');
  }

  Future<Map<String, dynamic>?> _reverseGeocode(LatLng coordinates) async {
    final uri = Uri.parse('$nominatimUrl/reverse').replace(
      queryParameters: {
        'lat': coordinates.latitude.toString(),
        'lon': coordinates.longitude.toString(),
        'format': 'json',
        'addressdetails': '1',
      },
    );

    final response = await http
        .get(uri, headers: {'User-Agent': 'WayFindCL/1.0'})
        .timeout(timeout);

    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    return null;
  }

  String _normalizeAddress(String address) {
    return address
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[^\w\sáéíóúñ]'), '');
  }

  String _buildFullAddress(String address, String? city, String? country) {
    final parts = <String>[address];

    if (city != null && city.isNotEmpty) {
      parts.add(city);
    } else {
      parts.add('Santiago'); // Ciudad por defecto
    }

    if (country != null && country.isNotEmpty) {
      parts.add(country);
    } else {
      parts.add('Chile'); // País por defecto
    }

    return parts.join(', ');
  }

  double _calculateConfidence(Map<String, dynamic> result, String query) {
    // Factores de confianza
    double confidence = 0.0;

    // 1. Importancia de OSM (0-1)
    final importance = (result['importance'] as num?)?.toDouble() ?? 0.0;
    confidence += importance * 0.3;

    // 2. Tipo de ubicación
    final type = result['type'] as String?;
    if (_isValidLocationType(type)) {
      confidence += 0.3;
    }

    // 3. Similitud de texto
    final displayName = (result['display_name'] as String?) ?? '';
    final similarity = _calculateTextSimilarity(
      query.toLowerCase(),
      displayName.toLowerCase(),
    );
    confidence += similarity * 0.4;

    return confidence.clamp(0.0, 1.0);
  }

  double _calculateTextSimilarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;

    // Verificar si 'a' está contenido en 'b'
    if (b.contains(a)) {
      return 0.7 + (a.length / b.length) * 0.3;
    }

    // Contar palabras coincidentes
    final wordsA = a.split(' ');
    final wordsB = b.split(' ');
    var matches = 0;

    for (var word in wordsA) {
      if (wordsB.any((w) => w.contains(word) || word.contains(w))) {
        matches++;
      }
    }

    return matches / wordsA.length;
  }

  bool _isValidLocationType(String? type) {
    if (type == null) return false;

    const validTypes = [
      'house',
      'building',
      'residential',
      'commercial',
      'amenity',
      'shop',
      'office',
      'school',
      'hospital',
      'restaurant',
      'cafe',
      'mall',
      'station',
      'stop',
      'park',
      'square',
      'street',
      'road',
      'avenue',
    ];

    return validTypes.any((valid) => type.toLowerCase().contains(valid));
  }

  String _getValidationDetails(
    AddressValidationStatus status,
    double confidence,
  ) {
    switch (status) {
      case AddressValidationStatus.valid:
        return 'Dirección válida (${(confidence * 100).toInt()}% confianza)';
      case AddressValidationStatus.uncertain:
        return 'Dirección encontrada pero con baja confianza. ¿Es correcta?';
      case AddressValidationStatus.invalid:
        return 'No se encontró esta dirección. Verifica la ortografía.';
      case AddressValidationStatus.networkError:
        return 'Error de conexión al validar dirección';
    }
  }

  void clearCache() {
    _cache.clear();
  }
}
