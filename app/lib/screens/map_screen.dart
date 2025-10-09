import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:speech_to_text/speech_to_text.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:vibration/vibration.dart';
import '../services/tts_service.dart';
import '../services/api_client.dart';
import '../services/combined_routes_service.dart';
import '../services/route_recommendation_service.dart';
import '../services/address_validation_service.dart';
import '../services/route_tracking_service.dart';
import '../services/transit_boarding_service.dart';
import 'settings_screen.dart';
import '../widgets/bottom_nav.dart';
import 'contribute_screen.dart';

enum NotificationType { success, error, warning, info, navigation, orientation }

class NotificationData {
  final String message;
  final NotificationType type;
  final IconData? icon;
  final Duration duration;
  final bool withSound;
  final bool withVibration;

  NotificationData({
    required this.message,
    required this.type,
    this.icon,
    this.duration = const Duration(seconds: 3),
    this.withSound = true,
    this.withVibration = false,
  });
}

class AccessibleNotification extends StatefulWidget {
  final NotificationData notification;
  final VoidCallback onDismiss;

  const AccessibleNotification({
    super.key,
    required this.notification,
    required this.onDismiss,
  });

  @override
  State<AccessibleNotification> createState() => _AccessibleNotificationState();
}

class _AccessibleNotificationState extends State<AccessibleNotification>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _controller.forward();

    // Auto-dismiss después de la duración especificada
    Timer(widget.notification.duration, () {
      if (mounted) _dismiss();
    });

    // Reproducir sonido y vibración si están habilitados
    if (widget.notification.withSound) {
      TtsService.instance.speak(widget.notification.message);
    }
    if (widget.notification.withVibration) {
      Vibration.vibrate(duration: 100);
    }
  }

  void _dismiss() async {
    await _controller.reverse();
    widget.onDismiss();
  }

  Color _getBackgroundColor() {
    switch (widget.notification.type) {
      case NotificationType.success:
        return Colors.green.shade700;
      case NotificationType.error:
        return Colors.red.shade700;
      case NotificationType.warning:
        return Colors.orange.shade700;
      case NotificationType.info:
        return Colors.blue.shade700;
      case NotificationType.navigation:
        return Colors.purple.shade700;
      case NotificationType.orientation:
        return Colors.teal.shade700;
    }
  }

  IconData _getIcon() {
    if (widget.notification.icon != null) {
      return widget.notification.icon!;
    }

    switch (widget.notification.type) {
      case NotificationType.success:
        return Icons.check_circle;
      case NotificationType.error:
        return Icons.error;
      case NotificationType.warning:
        return Icons.warning;
      case NotificationType.info:
        return Icons.info;
      case NotificationType.navigation:
        return Icons.navigation;
      case NotificationType.orientation:
        return Icons.explore;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _getBackgroundColor(),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(
                _getIcon(),
                color: Colors.white,
                size: 24,
                semanticLabel: widget.notification.type.name,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.notification.message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                  semanticsLabel: widget.notification.message,
                ),
              ),
              GestureDetector(
                onTap: _dismiss,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  child: const Icon(
                    Icons.close,
                    color: Colors.white70,
                    size: 20,
                    semanticLabel: 'Cerrar notificación',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  static const routeName = '/map';

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  bool _isListening = false;
  String _lastWords = '';
  final SpeechToText _speech = SpeechToText();
  bool _speechEnabled = false;
  Timer? _resultDebounce;
  String _pendingWords = '';
  String? _pendingDestination;

  // Mejoras de reconocimiento de voz
  double _speechConfidence = 0.0;
  String _currentRecognizedText = '';
  bool _isProcessingCommand = false;
  Timer? _speechTimeoutTimer;
  final List<String> _recognitionHistory = [];
  static const Duration _speechTimeout = Duration(seconds: 5);

  // Trip state - solo mostrar paradas cuando hay un viaje activo
  bool _hasActiveTrip = false;
  bool _showStops = false;

  // CAP-9: Confirmación de destino
  String? _pendingConfirmationDestination;
  Timer? _confirmationTimer;

  // CAP-12: Instrucciones de ruta
  List<String> _currentInstructions = [];
  int _currentInstructionStep = 0;

  // CAP-29: Confirmación de micro abordada
  bool _waitingBoardingConfirmation = false;

  // CAP-20 & CAP-30: Seguimiento en tiempo real
  bool _isTrackingRoute = false;

  // Ruta seleccionada recientemente (para tarjeta persistente)
  CombinedRoute? _selectedCombinedRoute;
  List<LatLng> _selectedPlannedRoute = [];
  String? _selectedDestinationName;

  // Compass and orientation
  StreamSubscription<CompassEvent>? _compassSubscription;
  double _heading = 0.0;
  String _currentDirection = 'Norte';
  Timer? _orientationTimer;

  // Accessibility features
  final bool _isAccessibilityMode = true;
  Timer? _feedbackTimer;

  // Notification system
  final List<NotificationData> _activeNotifications = [];
  final int _maxNotifications = 3;

  // Map and location services
  final MapController _mapController = MapController();
  bool _isMapReady = false;
  double? _pendingRotation;
  LatLng? _pendingCenter;
  double? _pendingZoom;
  Position? _currentPosition;
  List<Marker> _markers = [];
  List<Polyline> _polylines = [];
  List<dynamic> _nearbyStops = [];
  bool _isLoadingLocation = true;
  bool _isLoadingStops = false;

  // Default location (Santiago, Chile)
  static const LatLng _initialPosition = LatLng(-33.4489, -70.6693);

  @override
  void initState() {
    super.initState();
    // Usar post-frame callback para evitar bloquear la construcción del widget
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initServices();
      _setupTrackingCallbacks();
      _setupBoardingCallbacks();
    });
  }

  /// CAP-30 & CAP-20: Configurar callbacks de seguimiento
  void _setupTrackingCallbacks() {
    RouteTrackingService.instance.onPositionUpdate = (position) {
      if (!mounted) return;
      setState(() {
        _currentPosition = position;
      });
      _updateCurrentLocationMarker();
    };

    RouteTrackingService
        .instance
        .onDeviationDetected = (distance, needsRecalc) {
      if (!mounted || !needsRecalc) return;
      // CAP-20: Recalcular ruta automáticamente
      _showWarningNotification('Desviación detectada. Recalculando ruta...');
      _recalculateRoute();
    };

    RouteTrackingService.instance.onDestinationReached = () {
      if (!mounted) return;
      setState(() {
        _hasActiveTrip = false;
        _isTrackingRoute = false;
      });
      _showSuccessNotification('¡Destino alcanzado!', withVibration: true);
    };
  }

  /// CAP-29: Configurar callbacks de abordaje
  void _setupBoardingCallbacks() {
    TransitBoardingService.instance.onBoardingConfirmed = (busRoute) {
      if (!mounted) return;
      setState(() {
        _waitingBoardingConfirmation = false;
      });
      _showSuccessNotification(
        'Abordaje confirmado en bus $busRoute',
        withVibration: true,
      );

      // Iniciar seguimiento si no está activo
      if (!_isTrackingRoute &&
          RouteTrackingService.instance.destination != null) {
        _startRouteTracking();
      }
    };

    TransitBoardingService.instance.onBoardingCancelled = () {
      if (!mounted) return;
      setState(() {
        _waitingBoardingConfirmation = false;
      });
      _showWarningNotification('Confirmación de abordaje cancelada');
    };
  }

  /// Inicia servicios de forma no bloqueante y escalonada para evitar ANR
  void _initServices() {
    // Iniciar reconocimiento de voz inmediatamente, pero no await para no bloquear UI
    _initSpeech().catchError((e, st) {
      print('Error inicializando Speech: $e');
    });

    // Iniciar ubicación con pequeño retraso para dar tiempo al UI a estabilizarse
    Future.delayed(const Duration(milliseconds: 250), () {
      _initLocation().catchError((e, st) {
        print('Error inicializando Location: $e');
      });
    });

    // Iniciar brújula un poco después
    Future.delayed(const Duration(milliseconds: 500), () {
      _initCompass().catchError((e, st) {
        print('Error inicializando Compass: $e');
      });
    });
  }

  Future<void> _initSpeech() async {
    _speechEnabled = await _speech.initialize(
      onError: (errorNotification) {
        if (!mounted) return;
        setState(() {
          _isListening = false;
          _isProcessingCommand = false;
        });
        _speechTimeoutTimer?.cancel();

        String errorMessage = 'Error en reconocimiento de voz';
        if (errorNotification.errorMsg.contains('network')) {
          errorMessage = 'Error de conexión en reconocimiento de voz';
        } else if (errorNotification.errorMsg.contains('permission')) {
          errorMessage = 'Permiso de micrófono requerido';
        }

        _showErrorNotification(errorMessage);
        _triggerVibration();
      },
      onStatus: (status) {
        if (!mounted) return;

        if (status == 'notListening') {
          setState(() {
            _isListening = false;
            _currentRecognizedText = '';
          });
          _speechTimeoutTimer?.cancel();

          if (!_isProcessingCommand) {
            TtsService.instance.speak('Micrófono detenido');
          }
        } else if (status == 'listening') {
          setState(() {
            _isListening = true;
          });
        }
      },
    );
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _initCompass() async {
    try {
      // Verificar si el compass está disponible
      if (FlutterCompass.events == null) {
        TtsService.instance.speak('Brújula no disponible en este dispositivo');
        return;
      }

      // Suscribirse a los eventos del compass
      _compassSubscription = FlutterCompass.events?.listen((
        CompassEvent event,
      ) {
        if (!mounted) return;

        final newHeading = event.heading;
        if (newHeading != null) {
          setState(() {
            _heading = newHeading;
            _currentDirection = _getDirection(newHeading);
          });

          // Rotar el mapa con la orientación del usuario
          final rotation = -_heading;
          if (_isMapReady) {
            _mapController.rotate(rotation);
          } else {
            _pendingRotation = rotation;
          }

          // Proporcionar feedback de orientación cada 3 segundos
          _provideOrientationFeedback();
        }
      });

      if (_isAccessibilityMode) {
        TtsService.instance.speak(
          'Brújula activada. Te informaré sobre tu orientación mientras navegas.',
        );
      }
    } catch (e) {
      TtsService.instance.speak('Error activando brújula');
    }
  }

  String _getDirection(double heading) {
    if (heading >= 337.5 || heading < 22.5) return 'Norte';
    if (heading >= 22.5 && heading < 67.5) return 'Noreste';
    if (heading >= 67.5 && heading < 112.5) return 'Este';
    if (heading >= 112.5 && heading < 157.5) return 'Sureste';
    if (heading >= 157.5 && heading < 202.5) return 'Sur';
    if (heading >= 202.5 && heading < 247.5) return 'Suroeste';
    if (heading >= 247.5 && heading < 292.5) return 'Oeste';
    if (heading >= 292.5 && heading < 337.5) return 'Noroeste';
    return 'Norte';
  }

  void _provideOrientationFeedback() {
    if (!_isAccessibilityMode || !_hasActiveTrip) return;

    // Cancelar timer anterior
    _orientationTimer?.cancel();

    // Proporcionar feedback cada 3 segundos
    _orientationTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _isAccessibilityMode) {
        _showOrientationNotification('Mirando hacia el $_currentDirection');
        _describeNearbyElements();
      }
    });
  }

  void _describeNearbyElements() {
    if (!_showStops || _nearbyStops.isEmpty || _currentPosition == null) return;

    // Encontrar la parada más cercana en la dirección actual
    final userLat = _currentPosition!.latitude;
    final userLon = _currentPosition!.longitude;

    List<Map<String, dynamic>> stopsWithBearing = [];

    for (var stop in _nearbyStops) {
      final stopLat = stop['latitude'] as double?;
      final stopLon = stop['longitude'] as double?;

      if (stopLat != null && stopLon != null) {
        final bearing = _calculateBearing(userLat, userLon, stopLat, stopLon);
        final distance = Geolocator.distanceBetween(
          userLat,
          userLon,
          stopLat,
          stopLon,
        );

        stopsWithBearing.add({
          'stop': stop,
          'bearing': bearing,
          'distance': distance,
        });
      }
    }

    // Filtrar paradas en un cono de 45 grados hacia donde mira el usuario
    final userHeading = _heading;
    final nearbyInDirection = stopsWithBearing.where((item) {
      final bearing = item['bearing'] as double;
      final angleDiff = _angleDifference(userHeading, bearing);
      return angleDiff <= 45; // 45 grados de tolerancia
    }).toList();

    if (nearbyInDirection.isNotEmpty) {
      // Ordenar por distancia
      nearbyInDirection.sort(
        (a, b) => (a['distance'] as double).compareTo(b['distance'] as double),
      );

      final closest = nearbyInDirection.first;
      final stop = closest['stop'];
      final distance = (closest['distance'] as double).round();

      TtsService.instance.speak(
        'Parada ${stop['name']} a $distance metros en tu dirección',
      );
    }
  }

  double _calculateBearing(
    double startLat,
    double startLon,
    double endLat,
    double endLon,
  ) {
    final dLon = (endLon - startLon) * (math.pi / 180);
    final startLatRad = startLat * (math.pi / 180);
    final endLatRad = endLat * (math.pi / 180);

    final y = math.sin(dLon) * math.cos(endLatRad);
    final x =
        math.cos(startLatRad) * math.sin(endLatRad) -
        math.sin(startLatRad) * math.cos(endLatRad) * math.cos(dLon);

    final bearing = math.atan2(y, x) * (180 / math.pi);
    return (bearing + 360) % 360;
  }

  double _angleDifference(double angle1, double angle2) {
    final diff = (angle2 - angle1).abs();
    return diff > 180 ? 360 - diff : diff;
  }

  void _announceCurrentLocation() {
    if (_currentPosition == null) {
      TtsService.instance.speak('Ubicación no disponible');
      return;
    }

    final lat = _currentPosition!.latitude;
    final lon = _currentPosition!.longitude;

    TtsService.instance.speak(
      'Te encuentras en latitud ${lat.toStringAsFixed(4)}, '
      'longitud ${lon.toStringAsFixed(4)}. '
      'Mirando hacia el $_currentDirection.',
    );

    if (_nearbyStops.isNotEmpty && _showStops) {
      TtsService.instance.speak('Hay ${_nearbyStops.length} paradas cercanas');
    }
  }

  void _announceAvailableCommands() {
    final commands = [
      'Comandos disponibles:',
      'Para navegación puedes decir de forma natural:',
      'Quiero ir a mall vivo los trapenses',
      'Llévame al hospital clínico',
      'Necesito ir a la universidad católica',
      'Como llego al aeropuerto',
      'Para confirmación: Sí, No, Confirmar, Cancelar',
      'Para instrucciones: Leer instrucciones, Siguiente paso, Repetir paso',
      'Para monitoreo: Monitorear abordaje, Iniciar seguimiento, Detener seguimiento',
      'Buscar paradas - para transporte público',
      'Orientación - saber hacia dónde miras',
      'Donde estoy - obtener ubicación actual',
      'Actualizar - refrescar ubicación',
      'Vibrar - activar vibración',
      'Configuración - abrir ajustes',
    ];

    TtsService.instance.speak(commands.join('. '));
  }

  String _statusMessage() {
    if (_isListening) {
      if (_currentRecognizedText.isNotEmpty) {
        return '"$_currentRecognizedText"';
      }
      return 'Escuchando... Di tu comando';
    }

    // CAP-9: Mostrar pendiente de confirmación
    if (_pendingConfirmationDestination != null) {
      return '¿Ir a $_pendingConfirmationDestination? (Sí/No)';
    }

    // CAP-29: Mostrar estado de monitoreo de abordaje
    if (_waitingBoardingConfirmation) {
      return 'Monitoreando abordaje...';
    }

    // CAP-30: Mostrar seguimiento activo
    if (_isTrackingRoute) {
      return 'Seguimiento en tiempo real activo';
    }

    if (_isLoadingStops) {
      return 'Cargando paradas...';
    }
    if (_pendingDestination != null) {
      return 'Destino pendiente: $_pendingDestination';
    }
    if (_hasActiveTrip && _nearbyStops.isNotEmpty) {
      return '${_nearbyStops.length} paradas cercanas';
    }
    if (_lastWords.isNotEmpty) {
      return 'Último: $_lastWords';
    }
    return 'Pulsa para hablar';
  }

  void _announceCurrentOrientation() {
    final message =
        'Estás mirando hacia $_currentDirection, ${_heading.toInt()} grados. Toca para activar comando de voz.';
    TtsService.instance.speak(message);
    _announce(message);
  }

  void _centerOnUserLocation() {
    if (_currentPosition == null) {
      return;
    }

    final target = LatLng(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
    );

    _moveMap(target, 14.0);
    _showNavigationNotification('Centrando mapa en tu ubicación');
  }

  void _moveMap(LatLng target, double zoom) {
    if (_isMapReady) {
      _mapController.move(target, zoom);
    } else {
      _pendingCenter = target;
      _pendingZoom = zoom;
    }
  }

  void _triggerVibration() async {
    try {
      bool? hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        Vibration.vibrate(duration: 200);
      }
    } catch (e) {
      // Vibración no soportada
    }
  }

  String _lastAnnouncement = '';

  void _repeatLastAnnouncement() {
    if (_lastAnnouncement.isNotEmpty) {
      TtsService.instance.speak(_lastAnnouncement);
    } else {
      TtsService.instance.speak('No hay anuncios anteriores para repetir');
    }
  }

  // Sobrescribir método para guardar último anuncio
  Future<void> _initLocation() async {
    try {
      // Check location permissions
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        _showLocationPermissionDialog();
        return;
      }

      if (permission == LocationPermission.denied) {
        setState(() => _isLoadingLocation = false);
        return;
      }

      // Get current location
      _currentPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;

      setState(() {
        _isLoadingLocation = false;
      });

      // Solo mostrar ubicación actual inicialmente (no cargar paradas automáticamente)
      _updateCurrentLocationMarker();

      // Move camera to current location if map is ready
      if (_currentPosition != null) {
        _moveMap(
          LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
          14.0,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingLocation = false);
      TtsService.instance.speak('Error obteniendo ubicación');
    }
  }

  void _updateCurrentLocationMarker() {
    if (_currentPosition == null || !mounted) return;

    final currentMarker = Marker(
      point: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
      child: const Icon(Icons.my_location, color: Colors.blue, size: 30),
    );

    setState(() {
      _markers = [currentMarker]; // Solo mostrar ubicación actual
    });
  }

  void _loadNearbyStops() async {
    if (_currentPosition == null || !_showStops) return;

    setState(() => _isLoadingStops = true);

    try {
      final apiClient = ApiClient();
      final stops = await apiClient.getNearbyStops(
        lat: _currentPosition!.latitude,
        lon: _currentPosition!.longitude,
        radius: 600, // Reducido a 600 metros para mejor rendimiento
        limit: 20, // Reducido a 20 paradas máximo
      );

      if (!mounted) return;

      setState(() {
        _nearbyStops = stops;
        _isLoadingStops = false;
      });

      _updateStopMarkers();

      _showSuccessNotification('${stops.length} paradas encontradas cerca');
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingStops = false);
      TtsService.instance.speak('Error cargando paradas de transporte');
    }
  }

  void _updateStopMarkers() {
    // Usar post-frame callback para evitar bloquear el UI durante la construcción
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final newMarkers = <Marker>[];

      // Siempre mostrar ubicación actual
      if (_currentPosition != null) {
        newMarkers.add(
          Marker(
            point: LatLng(
              _currentPosition!.latitude,
              _currentPosition!.longitude,
            ),
            child: const Icon(Icons.my_location, color: Colors.blue, size: 30),
          ),
        );
      }

      // Solo mostrar paradas si están activas (_showStops = true)
      if (_showStops && _nearbyStops.isNotEmpty) {
        // Limitar a máximo 15 paradas para mejor rendimiento
        final stopsToShow = _nearbyStops.take(15);
        for (int i = 0; i < stopsToShow.length; i++) {
          final stop = stopsToShow.elementAt(i);
          final lat = stop['latitude'] as double?;
          final lon = stop['longitude'] as double?;
          final name = stop['name'] as String?;

          if (lat != null && lon != null && name != null) {
            newMarkers.add(
              Marker(
                point: LatLng(lat, lon),
                child: const Icon(
                  Icons.directions_bus,
                  color: Colors.red,
                  size: 25,
                ),
              ),
            );
          }
        }
      }

      if (mounted) {
        setState(() {
          _markers = newMarkers;
        });
      }
    });
  }

  void _showLocationPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permisos de ubicación'),
        content: const Text(
          'La aplicación necesita acceso a tu ubicación para mostrar paradas de transporte cercanas.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Geolocator.openAppSettings();
            },
            child: const Text('Configuración'),
          ),
        ],
      ),
    );
  }

  void _startListening() async {
    // Verificar permisos de micrófono
    var status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      _showPermissionDialog();
      TtsService.instance.speak('Permiso de micrófono denegado');
      return;
    }

    // Configurar timeout personalizado
    _speechTimeoutTimer?.cancel();
    _speechTimeoutTimer = Timer(_speechTimeout, () {
      if (_isListening) {
        _speech.stop();
        _showWarningNotification('Tiempo de escucha agotado');
      }
    });

    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;

        // Actualizar texto y confianza en tiempo real
        setState(() {
          _currentRecognizedText = result.recognizedWords;
          _speechConfidence = result.confidence;
        });

        // Procesar solo si hay alta confianza y texto final
        if (result.finalResult) {
          _speechTimeoutTimer?.cancel();
          _processRecognizedText(result.recognizedWords, result.confidence);
        } else {
          // Debounce para resultados parciales
          _pendingWords = result.recognizedWords;
          if (_resultDebounce?.isActive ?? false) _resultDebounce?.cancel();
          _resultDebounce = Timer(const Duration(milliseconds: 300), () {
            if (!mounted) return;
            setState(() {
              _lastWords = _pendingWords;
            });
          });
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 2), // Reducido para mayor responsividad
      localeId: 'es_ES', // Español de España (mejor reconocimiento)
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.confirmation,
        sampleRate: 16000, // Frecuencia optimizada para voz
        enableHapticFeedback: true, // Vibración al reconocer
      ),
    );
    if (!mounted) return;
    setState(() {
      _isListening = true;
    });
    TtsService.instance.speak('Escuchando');
  }

  void _stopListening() async {
    await _speech.stop();
    if (!mounted) return;
    setState(() {
      _isListening = false;
    });

    // Procesar el comando de voz
    if (_lastWords.isNotEmpty) {
      _processVoiceCommand(_lastWords);
    }
  }

  void _processVoiceCommand(String command) {
    if (!mounted) return;
    final normalized = command.toLowerCase().trim();
    if (normalized.isEmpty) return;

    if (_handleNavigationCommand(normalized)) {
      setState(() {
        _lastWords = command;
        _pendingDestination = null;
      });
      return;
    }

    final destination = _extractDestination(normalized);
    if (destination != null) {
      final pretty = _toTitleCase(destination);
      setState(() {
        _pendingDestination = pretty;
        _lastWords = command;
      });

      // CAP-9: Solicitar confirmación antes de buscar ruta
      _requestDestinationConfirmation(destination);
      return;
    }

    setState(() {
      _pendingDestination = null;
      _lastWords = command;
    });
    _announce('Comando "$command" aún no está soportado');
    TtsService.instance.speak('Por ahora no puedo ejecutar ese comando.');
  }

  bool _handleNavigationCommand(String command) {
    // CAP-9: Confirmación de destino
    if (command.contains('sí') ||
        command.contains('si') ||
        command.contains('confirmar') ||
        command.contains('correcto')) {
      if (_pendingConfirmationDestination != null) {
        _confirmDestination();
        return true;
      }
    }

    if (command.contains('no') ||
        command.contains('cancelar') ||
        command.contains('incorrecto')) {
      if (_pendingConfirmationDestination != null) {
        _cancelDestinationConfirmation();
        return true;
      }
    }

    // CAP-29: Confirmación de abordaje de micro
    if (_waitingBoardingConfirmation) {
      TransitBoardingService.instance.confirmBoardingManually(command);
      return true;
    }

    // CAP-12: Leer instrucciones de ruta
    if (command.contains('leer instrucciones') ||
        command.contains('instrucciones') ||
        command.contains('pasos')) {
      _readCurrentInstructions();
      return true;
    }

    if (command.contains('siguiente paso') ||
        command.contains('próximo paso') ||
        command.contains('próxima instrucción')) {
      _readNextInstruction();
      return true;
    }

    if (command.contains('repetir paso') ||
        command.contains('repetir instrucción')) {
      _repeatCurrentInstruction();
      return true;
    }

    // CAP-30: Control de seguimiento
    if (command.contains('detener seguimiento') ||
        command.contains('parar seguimiento')) {
      _stopRouteTracking();
      return true;
    }

    if (command.contains('iniciar seguimiento') ||
        command.contains('empezar seguimiento')) {
      if (RouteTrackingService.instance.destination != null) {
        _startRouteTracking();
        return true;
      }
    }

    // CAP-29: Monitoreo de abordaje
    if (command.contains('monitorear abordaje') ||
        command.contains('activar monitoreo') ||
        (command.contains('sí') &&
            !_waitingBoardingConfirmation &&
            _hasActiveTrip)) {
      // Extraer número de bus si está disponible
      final busMatch = RegExp(
        r'bus\s*(\w+)',
        caseSensitive: false,
      ).firstMatch(command);
      final busRoute = busMatch?.group(1) ?? '506'; // Default para demo
      _startBoardingMonitoring(busRoute);
      return true;
    }

    if (command.contains('configuración') ||
        command.contains('configuracion')) {
      TtsService.instance.speak('Abriendo configuración');
      Navigator.of(context).pushNamed(SettingsScreen.routeName);
      return true;
    }
    if (command.contains('abrir ajustes') ||
        command.contains('abrir configuración')) {
      TtsService.instance.speak('Mostrando ajustes');
      Navigator.of(context).pushNamed(SettingsScreen.routeName);
      return true;
    }
    if (command.contains('paradas') || command.contains('transporte')) {
      setState(() => _showStops = true);
      TtsService.instance.speak('Buscando paradas de transporte cercanas');
      _loadNearbyStops();
      return true;
    }
    if (command.contains('actualizar') || command.contains('refrescar')) {
      TtsService.instance.speak('Actualizando ubicación');
      _initLocation(); // Solo actualiza ubicación, no paradas automáticamente
      return true;
    }
    if (command.contains('mostrar paradas') ||
        command.contains('ver paradas')) {
      setState(() => _showStops = true);
      if (_nearbyStops.isNotEmpty) {
        TtsService.instance.speak(
          '${_nearbyStops.length} paradas de transporte cerca de tu ubicación',
        );
        _updateStopMarkers(); // Actualizar marcadores existentes
      } else {
        TtsService.instance.speak('Buscando paradas cercanas');
        _loadNearbyStops();
      }
      return true;
    }
    if (command.contains('ocultar paradas') ||
        command.contains('limpiar mapa')) {
      setState(() {
        _showStops = false;
        _nearbyStops.clear();
      });
      _updateCurrentLocationMarker(); // Solo mostrar ubicación actual
      TtsService.instance.speak('Paradas ocultadas');
      return true;
    }
    if (command.contains('orientación') || command.contains('dirección')) {
      _announceCurrentOrientation();
      _describeNearbyElements();
      return true;
    }
    if (command.contains('donde estoy') || command.contains('ubicación')) {
      _announceCurrentLocation();
      return true;
    }
    if (command.contains('ayuda') || command.contains('comandos')) {
      _announceAvailableCommands();
      return true;
    }
    if (command.contains('vibrar') || command.contains('vibración')) {
      _triggerVibration();
      TtsService.instance.speak('Vibración activada');
      return true;
    }
    if (command.contains('repetir') || command.contains('otra vez')) {
      _repeatLastAnnouncement();
      return true;
    }
    return false;
  }

  String? _extractDestination(String command) {
    // Patrones más naturales y flexibles para extraer destinos
    final patterns = [
      // Patrones explícitos con "ir a"
      r'(?:quiero\s+)?(?:ir|dirigirme|llevarme|navegar|viajar)\s+a(?:l)?\s+(.+)',
      r'(?:me\s+)?(?:lleva|dirije|guia|navega)\s+a(?:l)?\s+(.+)',
      r'(?:como\s+)?(?:llego|voy)\s+a(?:l)?\s+(.+)',

      // Patrones con "hacia"
      r'(?:ir|dirigirme|navegar)\s+hacia\s+(?:el|la)?\s*(.+)',

      // Patrones con "buscar"
      r'busca(?:r|me)?\s+(?:el\s+)?(?:camino|ruta)\s+a(?:l)?\s+(.+)',
      r'encontrar\s+(?:el\s+)?(?:camino|ruta)\s+a(?:l)?\s+(.+)',

      // Patrones casuales y naturales
      r'quiero\s+(?:ir\s+)?a(?:l)?\s+(.+)',
      r'necesito\s+(?:ir\s+)?a(?:l)?\s+(.+)',
      r'voy\s+(?:para|al?)\s+(.+)',
      r'tengo\s+que\s+ir\s+a(?:l)?\s+(.+)',

      // Patrones específicos para lugares comunes
      r'(?:al\s+)?mall\s+(.+)',
      r'(?:al\s+)?centro\s+comercial\s+(.+)',
      r'(?:a\s+la\s+)?universidad\s+(.+)',
      r'(?:al\s+)?hospital\s+(.+)',
      r'(?:al\s+)?aeropuerto\s+(.+)',
      r'(?:a\s+la\s+)?estacion\s+(.+)',

      // Fallback: cualquier cosa después de preposiciones
      r'(?:para|hacia|en|al?|del?)\s+(.+)',
    ];

    for (final pattern in patterns) {
      final match = RegExp(pattern, caseSensitive: false).firstMatch(command);
      if (match != null) {
        final destination = match.group(1)?.trim();
        if (destination != null && destination.isNotEmpty) {
          // Limpiar palabras innecesarias al final
          String cleaned = destination
              .replaceAll(
                RegExp(
                  r'\s+(por\s+favor|porfavor|gracias)$',
                  caseSensitive: false,
                ),
                '',
              )
              .replaceAll(RegExp(r'\s+ahora$', caseSensitive: false), '')
              .trim();

          if (cleaned.isNotEmpty) {
            return cleaned;
          }
        }
      }
    }

    return null;
  }

  /// CAP-9: Solicitar confirmación del destino reconocido
  void _requestDestinationConfirmation(String destination) {
    setState(() {
      _pendingConfirmationDestination = destination;
    });

    _confirmationTimer?.cancel();
    _confirmationTimer = Timer(const Duration(seconds: 15), () {
      if (_pendingConfirmationDestination != null) {
        _cancelDestinationConfirmation();
      }
    });

    final pretty = _toTitleCase(destination);
    TtsService.instance.speak(
      'Entendí que quieres ir a $pretty. ¿Es correcto? '
      'Di sí para confirmar o no para cancelar.',
    );

    _showNotification(
      NotificationData(
        message: 'Confirma destino: $pretty',
        type: NotificationType.warning,
        duration: const Duration(seconds: 15),
      ),
    );
  }

  /// CAP-9: Confirmar destino y buscar ruta
  void _confirmDestination() {
    if (_pendingConfirmationDestination == null) return;

    final destination = _pendingConfirmationDestination!;
    _confirmationTimer?.cancel();

    setState(() {
      _pendingDestination = null;
      _pendingConfirmationDestination = null;
    });

    _showSuccessNotification('Destino confirmado', withVibration: true);
    TtsService.instance.speak('Perfecto, buscando ruta a $destination');

    _searchRouteToDestination(destination);
  }

  /// CAP-9: Cancelar confirmación de destino
  void _cancelDestinationConfirmation() {
    _confirmationTimer?.cancel();

    setState(() {
      _pendingConfirmationDestination = null;
      _pendingDestination = null;
    });

    TtsService.instance.speak(
      'Destino cancelado. Puedes decir un nuevo destino cuando quieras.',
    );

    _showWarningNotification('Confirmación cancelada');
  }

  /// CAP-12: Leer todas las instrucciones actuales
  void _readCurrentInstructions() {
    if (_currentInstructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones disponibles aún');
      return;
    }

    RouteTrackingService.instance.readAllInstructions(_currentInstructions);
  }

  /// CAP-12: Leer siguiente instrucción
  void _readNextInstruction() {
    if (_currentInstructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones disponibles');
      return;
    }

    if (_currentInstructionStep >= _currentInstructions.length) {
      TtsService.instance.speak('Has completado todas las instrucciones');
      return;
    }

    final instruction = _currentInstructions[_currentInstructionStep];
    TtsService.instance.speak(
      'Paso ${_currentInstructionStep + 1}: $instruction',
    );

    setState(() {
      _currentInstructionStep++;
    });
  }

  /// CAP-12: Repetir instrucción actual
  void _repeatCurrentInstruction() {
    if (_currentInstructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones disponibles');
      return;
    }

    final step = _currentInstructionStep > 0 ? _currentInstructionStep - 1 : 0;

    if (step < _currentInstructions.length) {
      final instruction = _currentInstructions[step];
      TtsService.instance.speak('Repitiendo paso ${step + 1}: $instruction');
    }
  }

  /// CAP-30: Iniciar seguimiento en tiempo real
  void _startRouteTracking() {
    if (_polylines.isEmpty ||
        RouteTrackingService.instance.destination == null) {
      TtsService.instance.speak('No hay una ruta activa para seguir');
      return;
    }

    setState(() {
      _isTrackingRoute = true;
    });

    final destination = RouteTrackingService.instance.destination!;
    final destinationName =
        RouteTrackingService.instance.destinationName ?? 'destino';

    // Extraer puntos de la ruta
    final routePoints = _polylines.isNotEmpty
        ? _polylines.first.points
        : <LatLng>[];

    RouteTrackingService.instance.startTracking(
      plannedRoute: routePoints,
      destination: destination,
      destinationName: destinationName,
    );

    _showSuccessNotification(
      'Seguimiento en tiempo real activado',
      withVibration: true,
    );
  }

  /// CAP-30: Detener seguimiento
  void _stopRouteTracking() {
    setState(() {
      _isTrackingRoute = false;
    });

    RouteTrackingService.instance.stopTracking();
    _showWarningNotification('Seguimiento detenido');
  }

  /// CAP-20: Recalcular ruta desde posición actual
  Future<void> _recalculateRoute() async {
    if (_currentPosition == null ||
        RouteTrackingService.instance.destination == null) {
      return;
    }

    final dest = RouteTrackingService.instance.destination!;
    final destName = RouteTrackingService.instance.destinationName ?? 'destino';

    TtsService.instance.speak('Recalculando ruta a $destName');

    try {
      await _calculateRoute(
        destLat: dest.latitude,
        destLon: dest.longitude,
        destName: destName,
      );

      _showSuccessNotification('Ruta recalculada exitosamente');

      // Reiniciar seguimiento con nueva ruta
      if (_isTrackingRoute) {
        _startRouteTracking();
      }
    } catch (e) {
      _showErrorNotification('Error recalculando ruta');
    }
  }

  String _toTitleCase(String input) {
    return input
        .split(' ')
        .map((word) {
          if (word.isEmpty) return word;
          final lower = word.toLowerCase();
          return lower[0].toUpperCase() + lower.substring(1);
        })
        .join(' ');
  }

  void _announce(String message) {
    _lastAnnouncement = message;
    _showNotification(
      NotificationData(message: message, type: NotificationType.info),
    );
  }

  void _showNotification(NotificationData notification) {
    setState(() {
      // Limitar número de notificaciones activas
      if (_activeNotifications.length >= _maxNotifications) {
        _activeNotifications.removeAt(0);
      }
      _activeNotifications.add(notification);
    });
  }

  void _showSuccessNotification(String message, {bool withVibration = false}) {
    _showNotification(
      NotificationData(
        message: message,
        type: NotificationType.success,
        withVibration: withVibration,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showErrorNotification(String message, {bool withVibration = true}) {
    _showNotification(
      NotificationData(
        message: message,
        type: NotificationType.error,
        withVibration: withVibration,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _showNavigationNotification(String message) {
    _showNotification(
      NotificationData(
        message: message,
        type: NotificationType.navigation,
        icon: Icons.navigation,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showOrientationNotification(String message) {
    _showNotification(
      NotificationData(
        message: message,
        type: NotificationType.orientation,
        icon: Icons.explore,
        duration: const Duration(seconds: 2),
        withSound: false, // No sound for frequent orientation updates
      ),
    );
  }

  void _showWarningNotification(String message) {
    _showNotification(
      NotificationData(
        message: message,
        type: NotificationType.warning,
        withVibration: true,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _dismissNotification(NotificationData notification) {
    setState(() {
      _activeNotifications.remove(notification);
    });
  }

  // Método para procesar texto reconocido con filtros mejorados
  void _processRecognizedText(String recognizedText, double confidence) {
    if (!mounted || _isProcessingCommand) return;

    // Filtrar confianza mínima
    if (confidence < 0.7) {
      _showWarningNotification(
        'Comando no reconocido con suficiente claridad (${(confidence * 100).toInt()}%)',
      );
      return;
    }

    setState(() {
      _isProcessingCommand = true;
    });

    // Agregar a historial
    _recognitionHistory.add(recognizedText);
    if (_recognitionHistory.length > 10) {
      _recognitionHistory.removeAt(0);
    }

    // Procesar tanto el texto original como normalizado para máxima flexibilidad
    bool commandProcessed = _processVoiceCommandEnhanced(recognizedText);

    // Si no se procesó, intentar con texto normalizado como fallback
    if (!commandProcessed) {
      String normalizedText = _normalizeText(recognizedText);
      commandProcessed = _processVoiceCommandEnhanced(normalizedText);
    }

    if (commandProcessed) {
      _showSuccessNotification(
        'Comando ejecutado: "$recognizedText" (${(confidence * 100).toInt()}%)',
        withVibration: true,
      );
    } else {
      _showWarningNotification(
        'Comando no reconocido: "$recognizedText". Di "ayuda" para ver ejemplos.',
      );
    }

    setState(() {
      _isProcessingCommand = false;
      _lastWords = recognizedText;
    });
  }

  // Método para normalizar texto de entrada
  String _normalizeText(String text) {
    String normalized = text.toLowerCase().trim();

    // Remover acentos y caracteres especiales
    normalized = normalized
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('ñ', 'n');

    // Normalizar variaciones de frases comunes
    final phraseNormalizations = {
      // Variaciones de "querer ir"
      r'quiero\s+ir\s+a(?:l)?\s+': 'ir a ',
      r'necesito\s+ir\s+a(?:l)?\s+': 'ir a ',
      r'tengo\s+que\s+ir\s+a(?:l)?\s+': 'ir a ',
      r'voy\s+a(?:l)?\s+': 'ir a ',
      r'voy\s+para\s+': 'ir a ',

      // Variaciones de lugares
      r'centro\s+comercial\s+': 'mall ',
      r'shopping\s+': 'mall ',
      r'plaza\s+': 'mall ',

      // Normalizar artículos
      r'\s+el\s+': ' ',
      r'\s+la\s+': ' ',
      r'\s+los\s+': ' ',
      r'\s+las\s+': ' ',
    };

    // Aplicar normalizaciones de frases
    for (var entry in phraseNormalizations.entries) {
      normalized = normalized.replaceAll(RegExp(entry.key), entry.value);
    }

    // Sinónimos y variaciones comunes para mejorar reconocimiento
    final synonyms = {
      'bus': ['autobus', 'micro', 'colectivo', 'omnibus'],
      'paradas': ['parada', 'paradero', 'estacion', 'terminal'],
      'orientacion': ['direccion', 'rumbo', 'hacia donde'],
      'ubicacion': ['posicion', 'lugar', 'donde estoy'],
      'ir a': [
        've a',
        'vamos a',
        'dirigete a',
        'navegar a',
        'llevarme a',
        'dirigirme a',
      ],
      'ayuda': ['auxilio', 'comandos', 'que puedo decir'],
      'repetir': ['repite', 'otra vez', 'de nuevo'],
      'actualizar': ['refrescar', 'recargar', 'renovar'],

      // Lugares comunes con sinónimos
      'mall': ['centro comercial', 'shopping', 'plaza'],
      'universidad': ['u', 'uni', 'universidad'],
      'hospital': ['clinica', 'centro medico'],
      'aeropuerto': ['terminal aereo'],
      'estacion': ['paradero', 'terminal', 'estacion de metro'],
    };

    // Aplicar sinónimos
    for (var entry in synonyms.entries) {
      for (var synonym in entry.value) {
        if (normalized.contains(synonym)) {
          normalized = normalized.replaceAll(synonym, entry.key);
        }
      }
    }

    // Limpiar espacios múltiples y palabras de relleno
    normalized = normalized
        .replaceAll(RegExp(r'\s+(por favor|porfavor|gracias|ahora|ya)\s*'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return normalized;
  }

  // Versión mejorada del procesador de comandos que retorna bool
  bool _processVoiceCommandEnhanced(String command) {
    if (!mounted) return false;
    final normalized = command.toLowerCase().trim();
    if (normalized.isEmpty) return false;

    // Primero probar comandos de navegación específicos (ayuda, orientación, etc.)
    if (_handleNavigationCommand(normalized)) {
      setState(() {
        _lastWords = command;
        _pendingDestination = null;
      });
      return true;
    }

    // Intentar extraer destino del comando original (sin normalizar demasiado)
    final destination = _extractDestination(command);
    if (destination != null && destination.isNotEmpty) {
      final pretty = _toTitleCase(destination);
      setState(() {
        _pendingDestination = pretty;
        _lastWords = command;
      });

      // Feedback más natural
      _showSuccessNotification('Buscando ruta a: $pretty');
      TtsService.instance.speak('Perfecto, buscando la ruta a $pretty');
      _searchRouteToDestination(destination);
      return true;
    }

    // Si contiene palabras clave de navegación pero no se pudo extraer destino
    if (_containsNavigationIntent(normalized)) {
      _showWarningNotification(
        'No pude entender el destino. Intenta decir: "ir a [nombre del lugar]"',
      );
      TtsService.instance.speak(
        'No pude entender el destino. Puedes decir por ejemplo: ir a mall vivo los trapenses',
      );
      return true; // Se reconoció la intención aunque no el destino
    }

    // Si no se reconoce ningún comando específico
    setState(() {
      _pendingDestination = null;
      _lastWords = command;
    });

    return false; // Comando no reconocido
  }

  // Método para detectar si hay intención de navegación
  bool _containsNavigationIntent(String command) {
    final navigationKeywords = [
      'ir',
      'voy',
      'quiero',
      'necesito',
      'tengo que',
      'llevar',
      'dirigir',
      'navegar',
      'buscar',
      'como llego',
      'ruta',
      'camino',
      'mall',
      'centro',
      'universidad',
      'hospital',
      'aeropuerto',
      'estacion',
      'metro',
    ];

    return navigationKeywords.any((keyword) => command.contains(keyword));
  }

  void _searchRouteToDestination(String destination) async {
    if (_currentPosition == null) {
      _showErrorNotification('No se puede calcular ruta sin ubicación actual');
      return;
    }

    // Activar viaje y mostrar paradas
    setState(() {
      _hasActiveTrip = true;
      _showStops = true;
    });

    // Si no hay paradas cargadas, cargarlas primero
    if (_nearbyStops.isEmpty) {
      TtsService.instance.speak('Cargando paradas para calcular ruta');
      try {
        await _loadNearbyStopsSync();
      } catch (e) {
        TtsService.instance.speak('Error cargando paradas');
        return;
      }
    }

    try {
      // Search for a nearby stop that matches the destination
      final matchingStop = _nearbyStops.where((stop) {
        final name = (stop['name'] as String?)?.toLowerCase() ?? '';
        return name.contains(destination.toLowerCase());
      }).toList();

      if (matchingStop.isNotEmpty) {
        final bestStop = matchingStop.first;

        // Fetch alternative routes (server + cache) and convert to CombinedRoute
        final apiClient = ApiClient();
        final originLat = _currentPosition!.latitude;
        final originLon = _currentPosition!.longitude;
        final destLat = bestStop['latitude'] as double;
        final destLon = bestStop['longitude'] as double;

        List<Map<String, dynamic>> transitRoutes = [];
        try {
          transitRoutes = await apiClient.getAlternativeRoutes(
            originLat: originLat,
            originLon: originLon,
            destLat: destLat,
            destLon: destLon,
          );
        } catch (e) {
          // If retrieving alternatives fails, fallback to single route call
          try {
            final single = await apiClient.getTransitRoute(
              originLat: originLat,
              originLon: originLon,
              destLat: destLat,
              destLon: destLon,
            );
            transitRoutes = [single];
          } catch (e2) {
            _showErrorNotification('Error obteniendo rutas: ${e.toString()}');
            return;
          }
        }

        // Convert transit data into CombinedRoute objects
        final origin = LatLng(originLat, originLon);
        final destinationPoint = LatLng(destLat, destLon);

        final combinedRoutes = await CombinedRoutesService.instance
            .generateAlternativeRoutes(
          origin: origin,
          destination: destinationPoint,
          transitDataList: transitRoutes,
        );

        if (combinedRoutes.isEmpty) {
          // Fallback to original single-route display
          await _calculateRoute(
            destLat: destLat,
            destLon: destLon,
            destName: bestStop['name'] as String,
          );
          return;
        }

        // Show options to the user so they can choose (fastest first)
        await _showRouteOptions(combinedRoutes, bestStop['name'] as String);
      } else {
        _showWarningNotification(
          'No se encontró una parada con ese nombre cerca, buscando direcciones similares...',
        );

        // Intentar sugerir direcciones usando AddressValidationService
        try {
          final suggestions = await AddressValidationService.instance
              .suggestAddresses(destination, limit: 5);

          if (suggestions.isEmpty) {
            _showWarningNotification('No se encontraron direcciones similares');
            return;
          }

          // Mostrar modal de sugerencias y permitir seleccionar una
          final selectedIndex = await showModalBottomSheet<int?>(
            context: context,
            builder: (context) {
              return SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(12.0),
                      child: Text('Sugerencias encontradas', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: suggestions.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (context, i) {
                          final s = suggestions[i];
                          final display = s['display_name'] as String? ?? 'Sugerencia ${i + 1}';
                          final dist = s['importance']?.toString() ?? '';
                          return ListTile(
                            title: Text(display),
                            subtitle: dist.isNotEmpty ? Text('Importancia: $dist') : null,
                            onTap: () => Navigator.of(context).pop(i),
                          );
                        },
                      ),
                    ),
                    TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('Cancelar'))
                  ],
                ),
              );
            },
          );

          if (selectedIndex == null) return;

          final selected = suggestions[selectedIndex];
          final destLat = (selected['lat'] as num).toDouble();
          final destLon = (selected['lon'] as num).toDouble();

          // Reuse the same alternative-routes flow
          final originLat = _currentPosition!.latitude;
          final originLon = _currentPosition!.longitude;

          final apiClient = ApiClient();
          List<Map<String, dynamic>> transitRoutes = [];
          try {
            transitRoutes = await apiClient.getAlternativeRoutes(
              originLat: originLat,
              originLon: originLon,
              destLat: destLat,
              destLon: destLon,
            );
          } catch (e) {
            final single = await apiClient.getTransitRoute(
              originLat: originLat,
              originLon: originLon,
              destLat: destLat,
              destLon: destLon,
            );
            transitRoutes = [single];
          }

          final origin = LatLng(originLat, originLon);
          final destinationPoint = LatLng(destLat, destLon);

          final combinedRoutes = await CombinedRoutesService.instance
              .generateAlternativeRoutes(
            origin: origin,
            destination: destinationPoint,
            transitDataList: transitRoutes,
          );

          if (combinedRoutes.isEmpty) {
            _showWarningNotification('No se pudieron generar rutas alternativas');
            return;
          }

          await _showRouteOptions(combinedRoutes, selected['display_name'] as String);
        } catch (e) {
          _showErrorNotification('Error buscando direcciones: ${e.toString()}');
        }
      }
    } catch (e) {
      _showErrorNotification('Error buscando parada: ${e.toString()}');
    }
  }

  // Versión síncrona para usar con await
  Future<void> _loadNearbyStopsSync() async {
    if (_currentPosition == null) return;

    setState(() => _isLoadingStops = true);

    try {
      final apiClient = ApiClient();
      final stops = await apiClient.getNearbyStops(
        lat: _currentPosition!.latitude,
        lon: _currentPosition!.longitude,
        radius: 600,
        limit: 20,
      );

      if (!mounted) return;

      setState(() {
        _nearbyStops = stops;
        _isLoadingStops = false;
      });

      _updateStopMarkers();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingStops = false);
      rethrow; // Re-throw para que el método llamador pueda manejar el error
    }
  }

  Future<void> _calculateRoute({
    required double destLat,
    required double destLon,
    required String destName,
  }) async {
    if (_currentPosition == null) return;

    try {
      final apiClient = ApiClient();
      final route = await apiClient.getTransitRoute(
        originLat: _currentPosition!.latitude,
        originLon: _currentPosition!.longitude,
        destLat: destLat,
        destLon: destLon,
        departureTime: DateTime.now(),
        includeGeometry: true,
      );

      _displayRoute(route);

      // CAP-12: Guardar instrucciones para lectura posterior
      final instructions =
          (route['instructions'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [];

      setState(() {
        _currentInstructions = instructions;
        _currentInstructionStep = 0;
        _hasActiveTrip = true;
      });

      final durationMinutes = ((route['duration_seconds'] as num?) ?? 0) / 60;
      final distanceMeters = (route['distance_meters'] as num?) ?? 0;

      // CAP-12: Leer primera instrucción automáticamente
      String message =
          'Ruta a $destName encontrada. '
          'Duración: ${durationMinutes.round()} minutos, '
          'distancia: ${(distanceMeters / 1000).toStringAsFixed(1)} kilómetros. ';

      if (instructions.isNotEmpty) {
        message += 'Primera instrucción: ${instructions[0]}';
        _currentInstructionStep = 1;
      }

      TtsService.instance.speak(message);
      _announce('Ruta calculada exitosamente');

      // CAP-29 & CAP-30: Preguntar si quiere monitoreo de abordaje
      Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        _askForBoardingMonitoring();
      });
    } catch (e) {
      if (e is ApiException && e.isNetworkError) {
        _showWarningNotification(
          'Servidor no disponible, usando ruta de demostración',
        );
        _displayFallbackRoute(
          destLat: destLat,
          destLon: destLon,
          destName: destName,
        );
        return;
      }

      TtsService.instance.speak(
        'Error calculando ruta. Verifique la conexión con el servidor',
      );
      _showErrorNotification('No se pudo calcular la ruta: ${e.toString()}');
    }
  }

  /// CAP-29: Preguntar si quiere monitoreo de abordaje
  void _askForBoardingMonitoring() {
    TtsService.instance.speak(
      '¿Quieres que monitoree cuando abordes el bus? '
      'Di "monitorear abordaje" o "sí" para activarlo.',
    );
  }

  /// CAP-29: Iniciar monitoreo de abordaje (activado por voz)
  void _startBoardingMonitoring(String busRoute) {
    setState(() {
      _waitingBoardingConfirmation = true;
    });

    TransitBoardingService.instance.startMonitoring(expectedBusRoute: busRoute);

    _showNotification(
      NotificationData(
        message: 'Monitoreando abordaje del bus $busRoute',
        type: NotificationType.info,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  void _displayFallbackRoute({
    required double destLat,
    required double destLon,
    required String destName,
  }) {
    if (_currentPosition == null) {
      return;
    }

    final origin = LatLng(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
    );
    final destination = LatLng(destLat, destLon);

    setState(() {
      _polylines = [
        Polyline(
          points: [origin, destination],
          color: Colors.blueGrey,
          strokeWidth: 4,
        ),
      ];
      _markers = [
        Marker(
          point: origin,
          child: const Icon(Icons.my_location, color: Colors.blue, size: 30),
        ),
        Marker(
          point: destination,
          child: const Icon(Icons.location_on, color: Colors.orange, size: 30),
        ),
      ];
    });

    final distanceMeters = Geolocator.distanceBetween(
      origin.latitude,
      origin.longitude,
      destination.latitude,
      destination.longitude,
    );

    TtsService.instance.speak(
      'Ruta de demostración hacia $destName. Distancia aproximada ${(distanceMeters / 1000).toStringAsFixed(1)} kilómetros. '
      'Conéctate al servidor para obtener instrucciones detalladas.',
    );
  }

  /// Muestra un diálogo con rutas alternativas y permite seleccionar una
  Future<void> _showRouteOptions(
    List<CombinedRoute> routes,
    String destName,
  ) async {
    if (!mounted || routes.isEmpty) return;

    // Generar recomendaciones simples (ranked)
    final recommendations = RouteRecommendationService.instance
        .recommendRoutes(routes: routes, criteria: RecommendationCriteria.fastest);

    // State inside modal: index focused
    int focusedIndex = 0;

    // Function to speak focused option
    void speakFocused(int idx) {
      if (idx < 0 || idx >= recommendations.length) return;
      final rec = recommendations[idx];
      final txt = 'Opción ${rec.ranking}. ${rec.route.summary}. Duración ${rec.route.totalDuration.inMinutes} minutos.';
      TtsService.instance.speak(txt);
      _showNotification(
        NotificationData(message: 'Opción ${rec.ranking}: ${rec.route.summary}', type: NotificationType.info, duration: const Duration(seconds: 3)),
      );
    }

    // Mostrar modal con lista de opciones y controles de navegación
    final choice = await showModalBottomSheet<int?>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: StatefulBuilder(builder: (context, setModalState) {
            // Read the first option when opened
            WidgetsBinding.instance.addPostFrameCallback((_) {
              speakFocused(focusedIndex);
            });

            return Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Rutas hacia $destName',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                      TextButton.icon(
                        onPressed: () {
                          // Choose fastest automatically (first in recommendations)
                          Navigator.of(context).pop(0);
                        },
                        icon: const Icon(Icons.flash_on, color: Colors.orange),
                        label: const Text('Elegir más rápida'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('Elige la opción que prefieras',
                      style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: recommendations.length,
                      separatorBuilder: (_, __) => const Divider(),
                      itemBuilder: (context, index) {
                        final rec = recommendations[index];
                        final route = rec.route;
                        final minutes = (route.totalDuration.inMinutes);
                        final distance = route.totalDistanceText;

                        final selected = index == focusedIndex;

                        return ListTile(
                          selected: selected,
                          selectedTileColor: Colors.blue.withOpacity(0.08),
                          leading: CircleAvatar(
                            child: Text('${rec.ranking}'),
                          ),
                          title: Text(rec.route.summary),
                          subtitle: Text('Duración: ${minutes} min · $distance'),
                          trailing: index == 0
                              ? const Icon(Icons.speed, color: Colors.green)
                              : null,
                          onTap: () {
                            Navigator.of(context).pop(index);
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () {
                          if (focusedIndex > 0) {
                            setModalState(() {
                              focusedIndex--;
                            });
                            speakFocused(focusedIndex);
                          }
                        },
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Anterior'),
                      ),
                      ElevatedButton.icon(
                        onPressed: () {
                          if (focusedIndex < recommendations.length - 1) {
                            setModalState(() {
                              focusedIndex++;
                            });
                            speakFocused(focusedIndex);
                          }
                        },
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('Siguiente'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(null),
                        child: const Text('Cancelar'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }),
        );
      },
    );

    if (choice == null) {
      TtsService.instance.speak('Selección cancelada');
      return;
    }

    final selected = recommendations[choice].route;
    TtsService.instance.speak('Has seleccionado la opción ${recommendations[choice].ranking}');

    // Mostrar la ruta seleccionada en el mapa
    _displayCombinedRoute(selected);
  }

  /// Dibuja una CombinedRoute en el mapa (polylines y marcadores)
  void _displayCombinedRoute(CombinedRoute combined) {
    final newPolylines = <Polyline>[];
    final newMarkers = <Marker>[];

    for (var segment in combined.segments) {
      if (segment.geometry != null && segment.geometry!.isNotEmpty) {
        newPolylines.add(
          Polyline(
            points: segment.geometry!,
            color: segment.mode == TransportMode.walk ? Colors.grey : Colors.blue,
            strokeWidth: segment.mode == TransportMode.walk ? 3.0 : 5.0,
          ),
        );
      }

      // Add markers for stops/transfer points
      if (segment.stopName != null) {
        newMarkers.add(
          Marker(
            point: segment.startPoint,
            child: Icon(Icons.location_on, color: Colors.orange, size: 26),
          ),
        );
      }
    }

    // Ensure we keep user's location marker
    if (_currentPosition != null) {
      newMarkers.insert(
        0,
        Marker(
          point: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
          child: const Icon(Icons.my_location, color: Colors.blue, size: 30),
        ),
      );
    }

    setState(() {
      _polylines = newPolylines;
      _markers = newMarkers;
      _currentInstructions = combined.getVoiceInstructions();
      _currentInstructionStep = 0;
    });

    _showSuccessNotification('Ruta mostrada: ${combined.summary}');

    // Guardar la ruta seleccionada en el estado para la tarjeta persistente
    if (combined.segments.isNotEmpty) {
      final allPoints = combined.segments
          .expand((s) => s.geometry ?? <LatLng>[])
          .toList(growable: false);

      if (allPoints.isNotEmpty) {
        setState(() {
          _selectedCombinedRoute = combined;
          _selectedPlannedRoute = allPoints;
          _selectedDestinationName = combined.summary;
        });
      }
    }
  }

  void _displayRoute(Map<String, dynamic> route) {
    _polylines.clear();

    final geometry = route['geometry'] as List<dynamic>?;
    if (geometry != null && geometry.isNotEmpty) {
      final points = geometry.map((point) {
        final coords = point as List<dynamic>;
        // GraphHopper geometry is [lon, lat], convert to LatLng(lat, lon)
        return LatLng(coords[1] as double, coords[0] as double);
      }).toList();

      _polylines.add(
        Polyline(points: points, color: Colors.blue, strokeWidth: 4.0),
      );

      // Add destination marker
      final lastPoint = points.last;
      _markers.add(
        Marker(
          point: lastPoint,
          child: const Icon(Icons.location_on, color: Colors.green, size: 30),
        ),
      );
    }

    if (mounted) setState(() {});
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permiso Requerido'),
        content: const Text(
          'Esta aplicación necesita acceso al micrófono para el reconocimiento de voz.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: const Text('Configuración'),
          ),
        ],
      ),
    );
  }

  void _toggleMicrophone() {
    if (!_speechEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Reconocimiento de voz no disponible'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_isListening) {
      _stopListening();
    } else {
      _startListening();
    }
  }

  void _startMicrophoneCalibration() async {
    if (_isListening) {
      _showWarningNotification('Detén la grabación antes de calibrar');
      return;
    }

    _showNotification(
      NotificationData(
        message: 'Iniciando calibración del micrófono...',
        type: NotificationType.info,
        duration: const Duration(seconds: 2),
      ),
    );

    TtsService.instance.speak(
      'Calibración iniciada. Di "Hola, mi nombre es" seguido de tu nombre. '
      'Esto ayudará a mejorar el reconocimiento de tu voz.',
    );

    // Esperar un momento para que el TTS termine
    await Future.delayed(const Duration(seconds: 4));

    // Iniciar una sesión de calibración
    try {
      setState(() {
        _isListening = true;
        _currentRecognizedText = '';
        _speechConfidence = 0.0;
      });

      await _speech.listen(
        onResult: (result) {
          if (!mounted) return;

          setState(() {
            _currentRecognizedText = result.recognizedWords;
            _speechConfidence = result.confidence;
          });

          if (result.finalResult) {
            _finishCalibration(result.recognizedWords, result.confidence);
          }
        },
        listenFor: const Duration(seconds: 10),
        pauseFor: const Duration(seconds: 2),
        localeId: 'es_ES',
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.confirmation,
          sampleRate: 16000,
          enableHapticFeedback: true,
        ),
      );
    } catch (e) {
      setState(() {
        _isListening = false;
      });
      _showErrorNotification('Error durante la calibración: ${e.toString()}');
    }
  }

  void _finishCalibration(String recognizedText, double confidence) {
    setState(() {
      _isListening = false;
      _currentRecognizedText = '';
      _speechConfidence = 0.0;
    });

    if (confidence > 0.8) {
      _showSuccessNotification(
        'Calibración exitosa! Reconocimiento mejorado (${(confidence * 100).toInt()}%)',
        withVibration: true,
      );
      TtsService.instance.speak('Calibración completada con éxito');
    } else if (confidence > 0.6) {
      _showWarningNotification(
        'Calibración parcial. Intenta hablar más claro (${(confidence * 100).toInt()}%)',
      );
      TtsService.instance.speak(
        'Calibración parcial. Puedes intentar de nuevo',
      );
    } else {
      _showErrorNotification(
        'Calibración fallida. Verifica el micrófono (${(confidence * 100).toInt()}%)',
      );
      TtsService.instance.speak(
        'Calibración fallida. Verifica el micrófono y vuelve a intentar',
      );
    }

    // Guardar en historial para análisis futuro
    _recognitionHistory.add(
      'Calibración: "$recognizedText" - ${(confidence * 100).toInt()}%',
    );
  }

  @override
  void dispose() {
    _resultDebounce?.cancel();
    _orientationTimer?.cancel();
    _feedbackTimer?.cancel();
    _compassSubscription?.cancel();
    _confirmationTimer?.cancel();

    // Liberar servicios de tracking
    RouteTrackingService.instance.dispose();
    TransitBoardingService.instance.dispose();

    // Garantiza liberar el reconocimiento si la vista se destruye
    if (_isListening) {
      _speech.stop();
    }
    // Intenta cancelar cualquier operación pendiente
    _speech.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[300],
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const SizedBox(),
        title: const Text(
          'WayFindCL',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          // Área del mapa
          Positioned.fill(
            child: _isLoadingLocation
                ? Container(
                    color: Colors.grey[300],
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Obteniendo ubicación...'),
                        ],
                      ),
                    ),
                  )
                : FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _currentPosition != null
                          ? LatLng(
                              _currentPosition!.latitude,
                              _currentPosition!.longitude,
                            )
                          : _initialPosition,
                      initialZoom: 14.0,
                      minZoom: 10.0,
                      maxZoom: 18.0,
                      initialRotation:
                          -_heading, // Rota el mapa según orientación
                      onMapReady: () {
                        _isMapReady = true;

                        if (_pendingCenter != null) {
                          final zoom =
                              _pendingZoom ?? _mapController.camera.zoom;
                          _mapController.move(_pendingCenter!, zoom);
                          _pendingCenter = null;
                          _pendingZoom = null;
                        }

                        if (_pendingRotation != null) {
                          _mapController.rotate(_pendingRotation!);
                          _pendingRotation = null;
                        }
                      },
                      // Optimizaciones de rendimiento
                      keepAlive: true,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.wayfindcl',
                        maxZoom: 18,
                        // Optimizaciones de red
                        maxNativeZoom: 18,
                        retinaMode: false,
                      ),
                      if (_polylines.isNotEmpty)
                        PolylineLayer(polylines: _polylines),
                      if (_markers.isNotEmpty) MarkerLayer(markers: _markers),
                    ],
                  ),
          ),

          // Indicador de brújula con orientación actual
          Positioned(
            left: 20,
            bottom: 400, // Movido más arriba desde 280 a 430
            child: GestureDetector(
              onTap: _announceCurrentOrientation,
              child: Container(
                width: 60,
                height: 80,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.all(Radius.circular(10)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Transform.rotate(
                      angle: _heading * (3.14159 / 180), // Convertir a radianes
                      child: const Icon(
                        Icons.navigation,
                        color: Colors.red,
                        size: 28,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _currentDirection,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '${_heading.toInt()}°',
                      style: const TextStyle(fontSize: 8, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Tarjeta persistente para la ruta seleccionada
          if (_selectedCombinedRoute != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 20,
              child: Card(
                elevation: 8,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_selectedDestinationName ?? 'Ruta seleccionada',
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            Text(_selectedCombinedRoute!.summary),
                          ],
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          // Iniciar seguimiento con la ruta seleccionada
                          if (_selectedPlannedRoute.isNotEmpty) {
                            final dest = _selectedPlannedRoute.last;
                            RouteTrackingService.instance.startTracking(
                              plannedRoute: _selectedPlannedRoute,
                              destination: dest,
                              destinationName: _selectedDestinationName ?? 'destino',
                            );
                            setState(() {
                              _isTrackingRoute = true;
                            });
                          }
                        },
                        child: const Text('Iniciar seguimiento'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _selectedCombinedRoute = null;
                            _selectedPlannedRoute = [];
                            _selectedDestinationName = null;
                            _polylines = [];
                            _markers = [];
                          });
                        },
                        child: const Text('Cerrar'),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Botón de centrar ubicación
          Positioned(
            right: 20,
            bottom: 490, // Movido más arriba desde 340 a 490
            child: GestureDetector(
              onTap: _centerOnUserLocation,
              child: Container(
                width: 50,
                height: 50,
                decoration: const BoxDecoration(
                  color: Colors.blue,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.my_location,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ),

          // Botón de configuración (derecha)
          Positioned(
            right: 20,
            bottom: 400, // Movido más arriba desde 280 a 430
            child: GestureDetector(
              onTap: () => Navigator.pushNamed(context, '/settings'),
              child: Container(
                width: 50,
                height: 50,
                decoration: const BoxDecoration(
                  color: Colors.black,
                  shape: BoxShape.rectangle,
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.settings,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ),

          // Panel inferior
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Handle del panel
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Texto dinámico según estado
                  Column(
                    children: [
                      Text(
                        _statusMessage(),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _isListening ? Colors.blue : Colors.black,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),

                      // Indicador de confianza cuando está escuchando
                      if (_isListening && _speechConfidence > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(
                            children: [
                              Text(
                                'Confianza: ${(_speechConfidence * 100).toInt()}%',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _speechConfidence > 0.7
                                      ? Colors.green
                                      : _speechConfidence > 0.5
                                      ? Colors.orange
                                      : Colors.red,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              SizedBox(
                                width: 150,
                                child: LinearProgressIndicator(
                                  value: _speechConfidence,
                                  backgroundColor: Colors.grey[300],
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    _speechConfidence > 0.7
                                        ? Colors.green
                                        : _speechConfidence > 0.5
                                        ? Colors.orange
                                        : Colors.red,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                      // Indicador de procesamiento
                      if (_isProcessingCommand)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Procesando comando...',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.blue,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Botón del micrófono
                  Semantics(
                    label: _isListening
                        ? 'Botón micrófono, escuchando'
                        : 'Botón micrófono, no escuchando',
                    hint: _isListening
                        ? 'Toca para detener'
                        : 'Toca para iniciar',
                    button: true,
                    enabled: true,
                    child: GestureDetector(
                      onTap: _toggleMicrophone,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        width: double.infinity,
                        height: 120,
                        decoration: BoxDecoration(
                          color: _isListening ? Colors.red : Colors.black,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: _isListening
                              ? [
                                  BoxShadow(
                                    color: Colors.red.withValues(alpha: 0.3),
                                    blurRadius: 20,
                                    spreadRadius: 5,
                                  ),
                                ]
                              : null,
                        ),
                        child: Icon(
                          _isListening ? Icons.mic : Icons.mic_off,
                          color: Colors.white,
                          size: 48,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Botón de calibración del micrófono
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: _startMicrophoneCalibration,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey[200],
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.grey[400]!),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.tune, size: 16, color: Colors.grey),
                              SizedBox(width: 4),
                              Text(
                                'Calibrar micrófono',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Barra de navegación inferior
                  BottomNavBar(
                    currentIndex: 0,
                    onTap: (index) {
                      switch (index) {
                        case 0:
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Explorar')),
                          );
                          break;
                        case 1:
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Guardados (no implementado)')),
                          );
                          break;
                        case 2:
                          Navigator.pushNamed(context, ContributeScreen.routeName);
                          break;
                        case 3:
                          Navigator.pushNamed(context, SettingsScreen.routeName);
                          break;
                      }
                    },
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),

          // Sistema de notificaciones
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Column(
                children: _activeNotifications.map((notification) {
                  return AccessibleNotification(
                    key: ValueKey(notification.hashCode),
                    notification: notification,
                    onDismiss: () => _dismissNotification(notification),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
