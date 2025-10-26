import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:wayfindcl/services/polyline_compression.dart';

void main() {
  group('PolylineCompression', () {
    group('Douglas-Peucker Algorithm', () {
      test('should preserve endpoints', () {
        final points = [
          LatLng(-33.4372, -70.6506),
          LatLng(-33.4375, -70.6510),
          LatLng(-33.4380, -70.6515),
          LatLng(-33.4385, -70.6520),
        ];

        final compressed = PolylineCompression.compress(
          points: points,
          epsilon: 0.0001,
        );

        expect(compressed.first, equals(points.first));
        expect(compressed.last, equals(points.last));
      });

      test('should reduce points with high epsilon', () {
        final points = List.generate(
          100,
          (i) => LatLng(-33.4372 + i * 0.0001, -70.6506 + i * 0.0001),
        );

        final compressed = PolylineCompression.compress(
          points: points,
          epsilon: 0.001, // Alta compresión
        );

        expect(compressed.length, lessThan(points.length));
        expect(compressed.length, greaterThanOrEqualTo(2)); // Al menos inicio y fin
      });

      test('should preserve more points with low epsilon', () {
        final points = [
          LatLng(-33.4372, -70.6506),
          LatLng(-33.4373, -70.6507),
          LatLng(-33.4374, -70.6508),
          LatLng(-33.4375, -70.6509),
          LatLng(-33.4376, -70.6510),
        ];

        final highCompression = PolylineCompression.compress(
          points: points,
          epsilon: 0.001,
        );

        final lowCompression = PolylineCompression.compress(
          points: points,
          epsilon: 0.00001,
        );

        expect(
          lowCompression.length,
          greaterThanOrEqualTo(highCompression.length),
        );
      });

      test('should handle straight line efficiently', () {
        // Línea recta perfecta
        final points = List.generate(
          50,
          (i) => LatLng(-33.4372 + i * 0.001, -70.6506 + i * 0.001),
        );

        final compressed = PolylineCompression.compress(
          points: points,
          epsilon: 0.0001,
        );

        // Una línea recta debería comprimirse a solo 2 puntos
        expect(compressed.length, equals(2));
      });

      test('should handle zigzag pattern', () {
        // Patrón zigzag
        final points = <LatLng>[];
        for (int i = 0; i < 20; i++) {
          final lat = -33.4372 + i * 0.001;
          final lon = -70.6506 + (i % 2 == 0 ? 0.001 : -0.001);
          points.add(LatLng(lat, lon));
        }

        final compressed = PolylineCompression.compress(
          points: points,
          epsilon: 0.0001,
        );

        // Zigzag debería preservar más puntos
        expect(compressed.length, greaterThan(5));
      });

      test('should not compress very short polylines', () {
        final points = [
          LatLng(-33.4372, -70.6506),
          LatLng(-33.4375, -70.6510),
        ];

        final compressed = PolylineCompression.compress(
          points: points,
          epsilon: 0.0001,
        );

        expect(compressed.length, equals(points.length));
      });
    });

    group('Compression Ratio', () {
      test('should calculate correct compression ratio', () {
        final original = List.generate(
          100,
          (i) => LatLng(-33.4372, -70.6506),
        );
        final compressed = original.sublist(0, 25);

        final ratio = PolylineCompression.compressionRatio(
          original: original,
          compressed: compressed,
        );

        expect(ratio, equals(0.75)); // 75% reducción
      });

      test('should return 0 for empty original', () {
        final ratio = PolylineCompression.compressionRatio(
          original: [],
          compressed: [],
        );

        expect(ratio, equals(0.0));
      });

      test('should return 0 for same length', () {
        final points = [
          LatLng(-33.4372, -70.6506),
          LatLng(-33.4375, -70.6510),
        ];

        final ratio = PolylineCompression.compressionRatio(
          original: points,
          compressed: points,
        );

        expect(ratio, equals(0.0));
      });
    });

    group('Estimated Size', () {
      test('should calculate correct size in bytes', () {
        final points = List.generate(
          10,
          (i) => LatLng(-33.4372, -70.6506),
        );

        final size = PolylineCompression.estimatedSizeBytes(points);

        expect(size, equals(160)); // 10 * 16 bytes
      });

      test('should return 0 for empty list', () {
        final size = PolylineCompression.estimatedSizeBytes([]);
        expect(size, equals(0));
      });
    });

    group('Adaptive Compression', () {
      test('should compress to target points', () {
        final points = List.generate(
          500,
          (i) => LatLng(-33.4372 + i * 0.0001, -70.6506 + i * 0.0001),
        );

        final compressed = PolylineCompression.compressAdaptive(
          points: points,
          targetPoints: 100,
        );

        expect(compressed.length, lessThanOrEqualTo(100));
      });

      test('should not compress if already below target', () {
        final points = List.generate(
          50,
          (i) => LatLng(-33.4372 + i * 0.0001, -70.6506 + i * 0.0001),
        );

        final compressed = PolylineCompression.compressAdaptive(
          points: points,
          targetPoints: 100,
        );

        expect(compressed.length, equals(points.length));
      });
    });

    group('Multiple Polylines', () {
      test('should compress multiple polylines', () {
        final polylines = [
          List.generate(100, (i) => LatLng(-33.4372 + i * 0.0001, -70.6506)),
          List.generate(100, (i) => LatLng(-33.4372, -70.6506 + i * 0.0001)),
          List.generate(100, (i) => LatLng(-33.4372 + i * 0.0001, -70.6506 + i * 0.0001)),
        ];

        final compressed = PolylineCompression.compressMultiple(
          polylines: polylines,
          epsilon: 0.001,
        );

        expect(compressed.length, equals(3));
        for (final poly in compressed) {
          expect(poly.length, lessThan(100));
        }
      });
    });

    group('Extension Methods', () {
      test('should compress using extension method', () {
        final points = List.generate(
          100,
          (i) => LatLng(-33.4372 + i * 0.0001, -70.6506 + i * 0.0001),
        );

        final compressed = points.compressed(epsilon: 0.001);

        expect(compressed.length, lessThan(points.length));
      });

      test('should calculate estimated bytes using extension', () {
        final points = List.generate(
          10,
          (i) => LatLng(-33.4372, -70.6506),
        );

        expect(points.estimatedBytes, equals(160));
      });

      test('should use adaptive compression via extension', () {
        final points = List.generate(
          500,
          (i) => LatLng(-33.4372 + i * 0.0001, -70.6506 + i * 0.0001),
        );

        final compressed = points.compressedAdaptive(targetPoints: 100);

        expect(compressed.length, lessThanOrEqualTo(100));
      });
    });

    group('Real World Scenarios', () {
      test('should compress typical walking route efficiently', () {
        // Simular ruta de caminata típica (500 puntos)
        final route = List.generate(
          500,
          (i) => LatLng(
            -33.4372 + i * 0.0001 + (i % 3) * 0.00001, // Pequeña variación
            -70.6506 + i * 0.00015 + (i % 2) * 0.00002,
          ),
        );

        final compressed = PolylineCompression.compress(
          points: route,
          epsilon: 0.0001, // ~11 metros
        );

        final ratio = PolylineCompression.compressionRatio(
          original: route,
          compressed: compressed,
        );

        // Esperamos al menos 50% de reducción
        expect(ratio, greaterThan(0.5));
        expect(compressed.length, lessThan(250));
      });

      test('should compress bus route with many stops', () {
        // Simular ruta de bus con muchas paradas (850 puntos)
        final route = List.generate(
          850,
          (i) => LatLng(
            -33.4372 + i * 0.0002,
            -70.6506 + i * 0.0003,
          ),
        );

        final compressed = PolylineCompression.compress(
          points: route,
          epsilon: 0.00015, // ~17 metros para rutas largas
        );

        final ratio = PolylineCompression.compressionRatio(
          original: route,
          compressed: compressed,
        );

        // Esperamos al menos 70% de reducción en rutas largas
        expect(ratio, greaterThan(0.7));
        expect(compressed.length, lessThan(255));
      });
    });
  });
}
