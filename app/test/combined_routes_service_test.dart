import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:wayfindcl/services/combined_routes_service.dart';

void main() {
  test('generateAlternativeRoutes returns empty list when no data', () async {
    final origin = LatLng(-33.45, -70.66);
    final dest = LatLng(-33.46, -70.67);

    final result = await CombinedRoutesService.instance.generateAlternativeRoutes(
      origin: origin,
      destination: dest,
      transitDataList: [],
    );

    expect(result, isA<List<CombinedRoute>>());
    expect(result, isEmpty);
  });
}
