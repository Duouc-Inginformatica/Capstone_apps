/// Servicio de compresión de polilíneas usando algoritmo Douglas-Peucker
/// Reduce el número de puntos en una polilínea manteniendo la forma visual
library;

import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

/// Servicio de compresión de polilíneas para optimizar rendimiento
/// 
/// Implementa el algoritmo Douglas-Peucker para reducir la cantidad de puntos
/// en una polilínea sin perder la precisión visual significativa.
/// 
/// **Uso:**
/// ```dart
/// final compressed = PolylineCompression.compress(
///   points: originalPoints,
///   epsilon: 0.0001, // Tolerancia en grados (aprox. 11m)
/// );
/// print('Reducido de ${originalPoints.length} a ${compressed.length} puntos');
/// ```
/// 
/// **Niveles de epsilon recomendados:**
/// - `0.00001` (1.1m): Alta precisión, poca compresión
/// - `0.0001` (11m): Balance óptimo para navegación urbana
/// - `0.001` (111m): Alta compresión, ideal para overview de rutas largas
class PolylineCompression {
  PolylineCompression._();

  /// Comprime una lista de puntos usando Douglas-Peucker
  /// 
  /// **Parámetros:**
  /// - `points`: Lista de coordenadas LatLng a comprimir
  /// - `epsilon`: Tolerancia máxima de desviación (en grados)
  ///   - Valor más bajo = más puntos preservados
  ///   - Valor más alto = más compresión
  /// 
  /// **Returns:** Lista comprimida de puntos
  /// 
  /// **Ejemplo:**
  /// ```dart
  /// final route = [LatLng(-33.4372, -70.6506), ...]; // 500 puntos
  /// final compressed = PolylineCompression.compress(
  ///   points: route,
  ///   epsilon: 0.0001,
  /// );
  /// // compressed.length ≈ 120 puntos (76% reducción)
  /// ```
  static List<LatLng> compress({
    required List<LatLng> points,
    double epsilon = 0.0001, // ~11 metros de tolerancia por defecto
  }) {
    if (points.length <= 2) {
      return List.from(points); // No se puede comprimir
    }

    // Aplicar Douglas-Peucker recursivo
    final compressed = _douglasPeucker(points, epsilon);
    
    // Garantizar que el primer y último punto se preserven
    if (compressed.isEmpty) {
      return [points.first, points.last];
    }

    return compressed;
  }

  /// Implementación recursiva del algoritmo Douglas-Peucker
  static List<LatLng> _douglasPeucker(List<LatLng> points, double epsilon) {
    if (points.length <= 2) {
      return List.from(points);
    }

    // Encontrar el punto con la mayor distancia perpendicular
    double maxDistance = 0;
    int maxIndex = 0;
    final start = points.first;
    final end = points.last;

    for (int i = 1; i < points.length - 1; i++) {
      final distance = _perpendicularDistance(points[i], start, end);
      if (distance > maxDistance) {
        maxDistance = distance;
        maxIndex = i;
      }
    }

    // Si la distancia máxima es mayor que epsilon, dividir y recursar
    if (maxDistance > epsilon) {
      // Dividir la línea en dos segmentos
      final leftSegment = points.sublist(0, maxIndex + 1);
      final rightSegment = points.sublist(maxIndex);

      // Comprimir recursivamente ambos segmentos
      final leftCompressed = _douglasPeucker(leftSegment, epsilon);
      final rightCompressed = _douglasPeucker(rightSegment, epsilon);

      // Combinar resultados (evitar duplicar el punto medio)
      return [
        ...leftCompressed.sublist(0, leftCompressed.length - 1),
        ...rightCompressed,
      ];
    } else {
      // Todos los puntos intermedios están dentro de la tolerancia
      return [start, end];
    }
  }

  /// Calcula la distancia perpendicular de un punto a una línea
  /// 
  /// Usa la fórmula de distancia punto-línea en coordenadas cartesianas.
  /// Para coordenadas geográficas pequeñas (<100km), la aproximación es válida.
  static double _perpendicularDistance(
    LatLng point,
    LatLng lineStart,
    LatLng lineEnd,
  ) {
    final x0 = point.latitude;
    final y0 = point.longitude;
    final x1 = lineStart.latitude;
    final y1 = lineStart.longitude;
    final x2 = lineEnd.latitude;
    final y2 = lineEnd.longitude;

    // Fórmula: |ax + by + c| / sqrt(a² + b²)
    // donde la línea es: (y2-y1)x - (x2-x1)y + x2*y1 - y2*x1 = 0
    final numerator = ((y2 - y1) * x0 - (x2 - x1) * y0 + x2 * y1 - y2 * x1).abs();
    final denominator = math.sqrt(
      math.pow(y2 - y1, 2) + math.pow(x2 - x1, 2),
    );

    if (denominator == 0) {
      // La línea es un punto, retornar distancia euclidiana
      return math.sqrt(
        math.pow(x0 - x1, 2) + math.pow(y0 - y1, 2),
      );
    }

    return numerator / denominator;
  }

  /// Calcula el ratio de compresión entre dos listas de puntos
  /// 
  /// **Returns:** Porcentaje de reducción (0.0 - 1.0)
  /// 
  /// **Ejemplo:**
  /// ```dart
  /// final ratio = PolylineCompression.compressionRatio(
  ///   original: originalPoints,  // 500 puntos
  ///   compressed: compressed,     // 120 puntos
  /// );
  /// print('Compresión: ${(ratio * 100).toStringAsFixed(1)}%'); // 76.0%
  /// ```
  static double compressionRatio({
    required List<LatLng> original,
    required List<LatLng> compressed,
  }) {
    if (original.isEmpty) return 0.0;
    return 1.0 - (compressed.length / original.length);
  }

  /// Calcula el tamaño estimado en bytes de una lista de puntos
  /// 
  /// Asume 16 bytes por LatLng (2 doubles de 8 bytes)
  static int estimatedSizeBytes(List<LatLng> points) {
    return points.length * 16; // 8 bytes (lat) + 8 bytes (lon)
  }

  /// Comprime múltiples polilíneas en paralelo (útil para rutas multi-segmento)
  /// 
  /// **Ejemplo:**
  /// ```dart
  /// final routes = [walkRoute, busRoute, walkRoute2];
  /// final compressed = PolylineCompression.compressMultiple(
  ///   polylines: routes,
  ///   epsilon: 0.0001,
  /// );
  /// ```
  static List<List<LatLng>> compressMultiple({
    required List<List<LatLng>> polylines,
    double epsilon = 0.0001,
  }) {
    return polylines.map((points) {
      return compress(points: points, epsilon: epsilon);
    }).toList();
  }

  /// Compresión adaptativa: ajusta epsilon según la longitud de la ruta
  /// 
  /// - Rutas cortas (<1km): epsilon bajo (más detalle)
  /// - Rutas largas (>10km): epsilon alto (más compresión)
  /// 
  /// **Ejemplo:**
  /// ```dart
  /// final compressed = PolylineCompression.compressAdaptive(
  ///   points: longRoute,
  ///   targetPoints: 100, // Intentar reducir a ~100 puntos
  /// );
  /// ```
  static List<LatLng> compressAdaptive({
    required List<LatLng> points,
    int targetPoints = 100,
  }) {
    if (points.length <= targetPoints) {
      return List.from(points);
    }

    // Calcular epsilon adaptativo
    // Más puntos originales = epsilon más alto
    final ratio = points.length / targetPoints;
    final epsilon = 0.00001 * math.log(ratio + 1) * 10;

    return compress(points: points, epsilon: epsilon);
  }
}

/// Extensión para facilitar el uso de compresión en listas de LatLng
extension PolylineCompressionExt on List<LatLng> {
  /// Comprime esta lista de puntos
  List<LatLng> compressed({double epsilon = 0.0001}) {
    return PolylineCompression.compress(points: this, epsilon: epsilon);
  }

  /// Compresión adaptativa basada en cantidad de puntos objetivo
  List<LatLng> compressedAdaptive({int targetPoints = 100}) {
    return PolylineCompression.compressAdaptive(
      points: this,
      targetPoints: targetPoints,
    );
  }

  /// Tamaño estimado en bytes
  int get estimatedBytes => PolylineCompression.estimatedSizeBytes(this);
}
