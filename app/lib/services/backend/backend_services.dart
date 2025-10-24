// ============================================================================
// Backend Services - Barrel File
// ============================================================================
// Servicios que se comunican con el backend Go (GraphHopper + GTFS + Moovit)
// ============================================================================

// Configuración del servidor
export 'server_config.dart';

// Cliente HTTP base
export 'api_client.dart';

// Servicios de geometría y rutas
export 'geometry_service.dart';

// Servicios de transporte público
export 'bus_arrivals_service.dart';

// Validación de direcciones (OSM Nominatim)
export 'address_validation_service.dart';
