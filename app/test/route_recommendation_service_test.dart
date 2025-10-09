import 'package:flutter_test/flutter_test.dart';
import 'package:wayfindcl/services/combined_routes_service.dart';
import 'package:wayfindcl/services/route_recommendation_service.dart';
import 'package:latlong2/latlong.dart';

void main() {
  test('RouteRecommendationService ranks faster route higher', () {
    final seg1 = RouteSegment(
      mode: TransportMode.walk,
      startPoint: LatLng(-33.45, -70.66),
      endPoint: LatLng(-33.451, -70.661),
      distanceMeters: 200,
      durationSeconds: 180,
      instructions: 'Camina hacia el bus',
    );

    final seg2 = RouteSegment(
      mode: TransportMode.bus,
      startPoint: LatLng(-33.451, -70.661),
      endPoint: LatLng(-33.46, -70.67),
      distanceMeters: 5000,
      durationSeconds: 600,
      routeName: '506',
    );

    final routeSlow = CombinedRoute(
      segments: [seg1, seg2],
      totalDistanceMeters: seg1.distanceMeters + seg2.distanceMeters,
      totalDurationSeconds: seg1.durationSeconds + seg2.durationSeconds,
      transferCount: 1,
    );

    // Faster route (less duration)
    final seg3 = RouteSegment(
      mode: TransportMode.walk,
      startPoint: LatLng(-33.45, -70.66),
      endPoint: LatLng(-33.455, -70.665),
      distanceMeters: 150,
      durationSeconds: 120,
    );

    final seg4 = RouteSegment(
      mode: TransportMode.bus,
      startPoint: LatLng(-33.455, -70.665),
      endPoint: LatLng(-33.46, -70.67),
      distanceMeters: 4800,
      durationSeconds: 480,
      routeName: '506',
    );

    final routeFast = CombinedRoute(
      segments: [seg3, seg4],
      totalDistanceMeters: seg3.distanceMeters + seg4.distanceMeters,
      totalDurationSeconds: seg3.durationSeconds + seg4.durationSeconds,
      transferCount: 1,
    );

    final recommendations = RouteRecommendationService.instance
        .recommendRoutes(routes: [routeSlow, routeFast], criteria: RecommendationCriteria.fastest);

    expect(recommendations, isNotEmpty);
    expect(recommendations.first.route.totalDurationSeconds <= recommendations.last.route.totalDurationSeconds, isTrue);
  });
}
