import 'package:latlong2/latlong.dart';

/// Modelo completo de ruta de transporte público para personas no videntes
/// Basado en GraphHopper GTFS + Moovit
class TransitRoute {
  final List<RouteLeg> legs;
  final double totalDistanceMeters;
  final int totalDurationSeconds;
  final int transfers;
  final DateTime? departureTime;
  final DateTime? arrivalTime;

  TransitRoute({
    required this.legs,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required this.transfers,
    this.departureTime,
    this.arrivalTime,
  });

  factory TransitRoute.fromJson(Map<String, dynamic> json) {
    final legsData = json['legs'] as List;
    final legs = legsData.map((l) => RouteLeg.fromJson(l)).toList();

    return TransitRoute(
      legs: legs,
      totalDistanceMeters: (json['distance_meters'] as num?)?.toDouble() ??
          (json['total_distance_meters'] as num?)?.toDouble() ??
          0.0,
      totalDurationSeconds: (json['time_seconds'] as num?)?.toInt() ??
          (json['total_duration_seconds'] as num?)?.toInt() ??
          0,
      transfers: (json['transfers'] as num?)?.toInt() ?? 0,
      departureTime: json['departure_time'] != null
          ? DateTime.tryParse(json['departure_time'] as String)
          : null,
      arrivalTime: json['arrival_time'] != null
          ? DateTime.tryParse(json['arrival_time'] as String)
          : null,
    );
  }

  /// Convierte duración total en texto accesible para TTS
  String get durationText {
    final minutes = (totalDurationSeconds / 60).round();
    if (minutes < 60) {
      return '$minutes minutos';
    }
    final hours = minutes ~/ 60;
    final remainingMinutes = minutes % 60;
    return remainingMinutes > 0
        ? '$hours hora${hours > 1 ? 's' : ''} y $remainingMinutes minutos'
        : '$hours hora${hours > 1 ? 's' : ''}';
  }

  /// Convierte distancia total en texto accesible para TTS
  String get distanceText {
    if (totalDistanceMeters < 1000) {
      return '${totalDistanceMeters.round()} metros';
    }
    final km = (totalDistanceMeters / 1000);
    return '${km.toStringAsFixed(1)} kilómetros';
  }

  /// Resumen vocal completo para personas no videntes
  String get accessibleSummary {
    final parts = <String>[];
    
    parts.add('Ruta de $durationText');
    parts.add('Distancia total: $distanceText');
    
    if (transfers > 0) {
      parts.add('${transfers} trasbordo${transfers > 1 ? 's' : ''}');
    } else {
      parts.add('Sin trasbordos');
    }

    // Resumir tipos de transporte
    final busLegs = legs.where((l) => l.type == LegType.bus).length;
    final metroLegs = legs.where((l) => l.type == LegType.metro).length;
    final walkLegs = legs.where((l) => l.type == LegType.walk).length;

    final transportParts = <String>[];
    if (busLegs > 0) transportParts.add('$busLegs bus${busLegs > 1 ? 'es' : ''}');
    if (metroLegs > 0) transportParts.add('$metroLegs metro${metroLegs > 1 ? 's' : ''}');
    if (walkLegs > 0) transportParts.add('$walkLegs tramo${walkLegs > 1 ? 's' : ''} a pie');

    if (transportParts.isNotEmpty) {
      parts.add('Usarás: ${transportParts.join(', ')}');
    }

    return parts.join('. ');
  }
}

/// Tipo de segmento de ruta
enum LegType {
  walk,   // Caminar
  bus,    // Bus RED
  metro,  // Metro
  wait,   // Espera en paradero
}

/// Segmento de ruta (caminar, esperar, bus, metro)
class RouteLeg {
  final LegType type;
  final List<LatLng> geometry;
  final double distanceMeters;
  final int durationSeconds;
  
  // Para transporte público (bus/metro)
  final String? routeNumber;        // "506", "L1"
  final String? routeName;          // "Maipú - Las Condes"
  final String? headsign;           // Dirección del bus
  final int? numStops;              // Número de paradas
  final BusStopInfo? departStop;    // Paradero de subida
  final BusStopInfo? arriveStop;    // Paradero de bajada
  
  // Para caminar
  final List<WalkInstruction>? walkInstructions;
  
  // Para espera
  final int? waitTimeSeconds;

  RouteLeg({
    required this.type,
    required this.geometry,
    required this.distanceMeters,
    required this.durationSeconds,
    this.routeNumber,
    this.routeName,
    this.headsign,
    this.numStops,
    this.departStop,
    this.arriveStop,
    this.walkInstructions,
    this.waitTimeSeconds,
  });

  factory RouteLeg.fromJson(Map<String, dynamic> json) {
    // Determinar tipo
    LegType type;
    final typeStr = (json['type'] as String?)?.toLowerCase() ?? 'walk';
    
    if (typeStr.contains('walk')) {
      type = LegType.walk;
    } else if (typeStr.contains('pt') || typeStr.contains('bus')) {
      // Verificar si es metro o bus
      final mode = (json['mode'] as String?)?.toLowerCase() ?? '';
      if (mode.contains('metro') || mode.contains('subway')) {
        type = LegType.metro;
      } else {
        type = LegType.bus;
      }
    } else if (typeStr.contains('wait')) {
      type = LegType.wait;
    } else {
      type = LegType.walk;
    }

    // Parsear geometría
    List<LatLng> geometry = [];
    if (json['geometry'] != null) {
      final geomData = json['geometry'] as List;
      geometry = geomData
          .map((coord) => LatLng(
                coord[1] as double? ?? 0.0,
                coord[0] as double? ?? 0.0,
              ))
          .toList();
    }

    // Parsear instrucciones de caminata
    List<WalkInstruction>? walkInstructions;
    if (json['instructions'] != null) {
      final instData = json['instructions'] as List;
      walkInstructions =
          instData.map((i) => WalkInstruction.fromJson(i)).toList();
    } else if (json['street_instructions'] != null) {
      // Formato alternativo de Moovit
      final instData = json['street_instructions'] as List;
      walkInstructions = instData
          .map((text) => WalkInstruction(
                text: text as String,
                distanceMeters: 0,
                durationSeconds: 0,
              ))
          .toList();
    }

    // Parsear paradas
    BusStopInfo? departStop;
    if (json['depart_stop'] != null) {
      departStop = BusStopInfo.fromJson(json['depart_stop']);
    } else if (json['from_stop'] != null) {
      departStop = BusStopInfo.fromJson(json['from_stop']);
    }

    BusStopInfo? arriveStop;
    if (json['arrive_stop'] != null) {
      arriveStop = BusStopInfo.fromJson(json['arrive_stop']);
    } else if (json['to_stop'] != null) {
      arriveStop = BusStopInfo.fromJson(json['to_stop']);
    }

    return RouteLeg(
      type: type,
      geometry: geometry,
      distanceMeters: (json['distance'] as num?)?.toDouble() ??
          (json['distance_meters'] as num?)?.toDouble() ??
          0.0,
      durationSeconds: (json['time'] as num?)?.toInt() ??
          (json['time_seconds'] as num?)?.toInt() ??
          (json['duration_seconds'] as num?)?.toInt() ??
          0,
      routeNumber: json['route_short_name'] as String? ??
          json['route_number'] as String?,
      routeName: json['route_long_name'] as String? ?? json['route_name'] as String?,
      headsign: json['headsign'] as String?,
      numStops: (json['num_stops'] as num?)?.toInt() ??
          (json['stop_count'] as num?)?.toInt(),
      departStop: departStop,
      arriveStop: arriveStop,
      walkInstructions: walkInstructions,
      waitTimeSeconds: (json['wait_time'] as num?)?.toInt(),
    );
  }

  /// Descripción accesible para TTS
  String get accessibleDescription {
    switch (type) {
      case LegType.walk:
        final meters = distanceMeters.round();
        final minutes = (durationSeconds / 60).ceil();
        return 'Camina $meters metros, aproximadamente $minutes minuto${minutes > 1 ? 's' : ''}';

      case LegType.bus:
        final stopText = numStops != null
            ? 'durante ${numStops! - 1} parada${numStops! > 2 ? 's' : ''}'
            : '';
        final fromText = departStop != null ? 'desde ${departStop!.name}' : '';
        final toText = arriveStop != null ? 'hasta ${arriveStop!.name}' : '';
        return 'Toma el bus $routeNumber $fromText $stopText $toText';

      case LegType.metro:
        final stopText = numStops != null
            ? 'durante ${numStops! - 1} estación${numStops! > 2 ? 'es' : ''}'
            : '';
        final line = routeNumber?.replaceAll('L', 'Línea ') ?? '';
        final fromText = departStop != null ? 'desde ${departStop!.name}' : '';
        final toText = arriveStop != null ? 'hasta ${arriveStop!.name}' : '';
        return 'Toma el metro $line $fromText $stopText $toText';

      case LegType.wait:
        final minutes = ((waitTimeSeconds ?? durationSeconds) / 60).ceil();
        return 'Espera en el paradero, aproximadamente $minutes minuto${minutes > 1 ? 's' : ''}';
    }
  }

  /// Instrucción corta para notificación durante navegación
  String get shortInstruction {
    switch (type) {
      case LegType.walk:
        return 'Camina ${distanceMeters.round()} metros';
      case LegType.bus:
        return 'Bus $routeNumber hacia ${headsign ?? arriveStop?.name ?? 'destino'}';
      case LegType.metro:
        return 'Metro ${routeNumber ?? ''} hacia ${headsign ?? arriveStop?.name ?? 'destino'}';
      case LegType.wait:
        return 'Espera el bus';
    }
  }
}

/// Información de parada (bus o metro)
class BusStopInfo {
  final String name;
  final String? code;
  final LatLng? location;
  final DateTime? arrivalTime;
  final DateTime? departureTime;

  BusStopInfo({
    required this.name,
    this.code,
    this.location,
    this.arrivalTime,
    this.departureTime,
  });

  factory BusStopInfo.fromJson(Map<String, dynamic> json) {
    LatLng? location;
    if (json['lat'] != null && json['lon'] != null) {
      location = LatLng(
        (json['lat'] as num).toDouble(),
        (json['lon'] as num).toDouble(),
      );
    } else if (json['latitude'] != null && json['longitude'] != null) {
      location = LatLng(
        (json['latitude'] as num).toDouble(),
        (json['longitude'] as num).toDouble(),
      );
    }

    return BusStopInfo(
      name: json['name'] as String? ?? json['stop_name'] as String? ?? 'Paradero',
      code: json['code'] as String? ?? json['stop_code'] as String?,
      location: location,
      arrivalTime: json['arrival_time'] != null
          ? DateTime.tryParse(json['arrival_time'] as String)
          : null,
      departureTime: json['departure_time'] != null
          ? DateTime.tryParse(json['departure_time'] as String)
          : null,
    );
  }

  String get accessibleName {
    if (code != null && code!.isNotEmpty) {
      return '$name, código $code';
    }
    return name;
  }
}

/// Instrucción de navegación peatonal
class WalkInstruction {
  final String text;
  final double distanceMeters;
  final int durationSeconds;
  final String? streetName;

  WalkInstruction({
    required this.text,
    required this.distanceMeters,
    required this.durationSeconds,
    this.streetName,
  });

  factory WalkInstruction.fromJson(Map<String, dynamic> json) {
    return WalkInstruction(
      text: json['text'] as String? ?? json['instruction'] as String? ?? '',
      distanceMeters: (json['distance_meters'] as num?)?.toDouble() ??
          (json['distance'] as num?)?.toDouble() ??
          0.0,
      durationSeconds: (json['duration_seconds'] as num?)?.toInt() ??
          (json['time'] as num?)?.toInt() ??
          0,
      streetName: json['street_name'] as String?,
    );
  }

  String get accessibleText {
    if (distanceMeters > 0) {
      final meters = distanceMeters.round();
      return '$text, $meters metros';
    }
    return text;
  }
}
