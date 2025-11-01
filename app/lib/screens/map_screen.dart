import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:speech_to_text/speech_to_text.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:vibration/vibration.dart';
import '../services/device/tts_service.dart';
import '../services/device/smart_vibration_service.dart';
import '../services/backend/address_validation_service.dart';
import '../services/backend/bus_arrivals_service.dart';
import '../services/backend/bus_geometry_service.dart';
import '../services/navigation/integrated_navigation_service.dart';
import '../services/device/npu_detector_service.dart';
import '../services/debug_logger.dart';
import '../services/ui/timer_manager.dart'; // Gestor de timers centralizado
import '../widgets/map/accessible_notification.dart';
import '../mixins/navigation_geometry_mixin.dart'; // 🆕 Mixin centralizado de geometrías
import 'settings_screen.dart';
import '../widgets/bottom_nav.dart';

class MapScreen extends StatefulWidget {
  final String? welcomeMessage; // 🆕 Mensaje de bienvenida opcional
  
  const MapScreen({
    super.key,
    this.welcomeMessage,
  });
  
  static const routeName = '/map';

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> 
    with TimerManagerMixin, NavigationGeometryMixin {
  void _log(String message, {Object? error, StackTrace? stackTrace}) {
    developer.log(
      message,
      name: 'MapScreen',
      error: error,
      stackTrace: stackTrace,
    );
  }

  bool _isListening = false;
  String _lastWords = '';
  final SpeechToText _speech = SpeechToText();
  bool _speechEnabled = false;
  // ✅ _resultDebounce gestionado por TimerManagerMixin
  String _pendingWords = '';

  bool _npuAvailable = false;
  bool _npuLoading = false;
  bool _npuChecked = false;

  // Reconocimiento de voz simplificado
  bool _isProcessingCommand = false;
  // ✅ Timers gestionados por TimerManagerMixin: speechTimeout, confirmation, feedback, walkSimulation
  final List<String> _recognitionHistory = [];
  static const Duration _speechTimeout = Duration(seconds: 5);

  // CAP-9: Confirmación de destino
  String? _pendingConfirmationDestination;
  // ✅ _confirmationTimer gestionado por TimerManagerMixin

  // CAP-12: Instrucciones de ruta
  List<String> _currentInstructions = [];
  int _currentInstructionStep = 0;
  bool _isCalculatingRoute = false;
  bool _showInstructionsPanel = false;

  // Lectura automática de instrucciones
  bool _autoReadInstructions = true; // Por defecto ON para no videntes

  // Accessibility features
  // ✅ _feedbackTimer gestionado por TimerManagerMixin

  // Cache de geometría para optimización
  List<LatLng> _cachedStepGeometry = [];
  int _cachedStepIndex = -1;

  // Control de simulación GPS
  bool _isSimulating = false; // Evita auto-centrado durante simulación
  int _currentSimulatedBusStopIndex = -1; // Índice del paradero actual durante simulación de bus
  
  // ✅ Anuncios automáticos de instrucciones
  int _lastAnnouncedInstructionIndex = -1;
  
  // ============================================================================
  // SIMULACIÓN REALISTA CON DESVIACIONES (SOLO PARA DESARROLLO/DEBUG)
  // ============================================================================
  // IMPORTANTE: Estas variables son SOLO para el botón "Simular" (desarrollo)
  // Los usuarios finales NO tienen este botón - usan GPS real automático
  // El sistema de detección de desviación funciona AUTOMÁTICAMENTE con GPS real
  // en IntegratedNavigationService._onLocationUpdate()
  // ============================================================================
  final bool _simulationDeviationEnabled = true; // Habilitar desviaciones aleatorias en simulación
  int _simulationDeviationStep = -1; // En qué punto índice se desviará (simulación)
  List<LatLng>? _simulationDeviationRoute; // Ruta de desviación temporal (simulación)
  bool _isCurrentlyDeviated = false; // Si está actualmente desviado (simulación)

  // Notification system
  final List<NotificationData> _activeNotifications = [];
  final int _maxNotifications = 3;
  final List<String> _messageHistory = [];

  // Map and location services
  final MapController _mapController = MapController();
  bool _isMapReady = false;
  double? _pendingRotation;
  LatLng? _pendingCenter;
  double? _pendingZoom;
  Position? _currentPosition;
  List<Marker> _markers = [];
  // ✅ _polylines eliminado - ahora se usa navigationPolylines del mixin para navegación real
  // ⚠️ Para simulación de desarrollo, se usa _simulationPolylines separadamente
  List<Polyline> _simulationPolylines = []; // Solo para _simulateArrivalAtStop (testing)
  
  // NOTA: Variables de compass removidas (causaban bugs en el mapa)

  // Default location (Santiago, Chile)
  static const LatLng _initialPosition = LatLng(-33.4489, -70.6693);

  double _overlayBaseOffset(BuildContext context, {double min = 240}) {
    final media = MediaQuery.of(context);
    // ✅ Reducido de 0.28 a 0.20 (20% en lugar de 28%) para dar más visibilidad al mapa
    final double estimate = media.size.height * 0.20 + media.padding.bottom;
    return math.max(estimate, min);
  }

  double _overlayGap(BuildContext context) {
    final media = MediaQuery.of(context);
    return math.max(media.size.height * 0.035, 28);
  }

  @override
  void initState() {
    super.initState();
    
    // Log de inicialización con optimizaciones
    DebugLogger.separator(title: 'MAP SCREEN OPTIMIZADO');
    DebugLogger.info('🗺️ Inicializando con autocentrado permanente', context: 'MapScreen');
    DebugLogger.info('⚡ Throttling activado: Map(100ms), GPS(10m)', context: 'MapScreen');
    DebugLogger.info('💾 Caché de geometrías + Compresión Douglas-Peucker activos', context: 'MapScreen');
    
    unawaited(TtsService.instance.setActiveContext('map_navigation'));
    
    // 🆕 Reproducir mensaje de bienvenida PRIMERO si existe
    if (widget.welcomeMessage != null && widget.welcomeMessage!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _speakWelcomeMessage();
      });
    }
    
    _initializeNpuDetection();
    // Usar post-frame callback para evitar bloquear la construcción del widget
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initServices();
    });
  }

  /// 🆕 Reproducir mensaje de bienvenida con prioridad
  Future<void> _speakWelcomeMessage() async {
    if (widget.welcomeMessage == null || widget.welcomeMessage!.isEmpty) {
      return;
    }
    
    // Esperar 800ms para que el MapScreen termine de renderizar
    await Future.delayed(const Duration(milliseconds: 800));
    
    // Reproducir mensaje de bienvenida
    await TtsService.instance.speak(widget.welcomeMessage!);
    
    _log('🔊 Mensaje de bienvenida reproducido: ${widget.welcomeMessage}');
  }

  Future<void> _initializeNpuDetection() async {
    setState(() {
      _npuLoading = true;
      _npuChecked = false;
    });

    try {
      final capabilities = await NpuDetectorService.instance
          .detectCapabilities();
      if (!mounted) return;
      setState(() {
        _npuAvailable = capabilities.hasNnapi;
        _npuLoading = false;
        _npuChecked = true;
      });
    } catch (e, st) {
      if (!mounted) return;
      _log('⚠️ [MAP] Error detectando NPU: $e', error: e, stackTrace: st);
      setState(() {
        _npuAvailable = false;
        _npuLoading = false;
        _npuChecked = true;
      });
    }
  }

  /// Inicia servicios de forma no bloqueante y escalonada para evitar ANR
  void _initServices() {
    // Iniciar reconocimiento de voz inmediatamente, pero no await para no bloquear UI
    _initSpeech().catchError((e, st) {
      _log('Error inicializando Speech: $e', error: e, stackTrace: st);
    });

    // Iniciar ubicación con delay mínimo optimizado (100ms en vez de 250ms)
    Future.delayed(const Duration(milliseconds: 100), () {
      _initLocation().catchError((e, st) {
        _log('Error inicializando Location: $e', error: e, stackTrace: st);
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
        cancelTimer('speechTimeout'); // ✅ Usar TimerManagerMixin

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
          });
          cancelTimer('speechTimeout'); // ✅ Usar TimerManagerMixin

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
    // ✅ Eliminado setState vacío innecesario
  }

  /// Determina el índice de la instrucción actual basado en la posición GPS
  // ✅ Timer para simular caminata gestionado por TimerManagerMixin

  /// Devuelve el texto del botón de simulación según el paso actual
  String _getSimulationButtonLabel() {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null) return 'TEST';

    final currentStep = activeNav.currentStep;
    if (currentStep == null) return 'TEST';

    switch (currentStep.type) {
      case 'walk':
        // Verificar si el siguiente paso es esperar el bus o es la caminata final
        if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
          final nextStep = activeNav.steps[activeNav.currentStepIndex + 1];
          if (nextStep.type == 'wait_bus') {
            return 'Simular → Paradero';
          }
        }
        return 'Simular → Destino';
      case 'wait_bus':
        return 'Subir al bus';
      case 'ride_bus':
      case 'bus':
        return 'Simular viaje';
      default:
        return 'Simular';
    }
  }

  /// TEST: Simula movimiento GPS realista a lo largo de la geometría para desarrolladores
  void _simulateArrivalAtStop() async {
    try {
      _log('🔴🔴🔴 _simulateArrivalAtStop CALLED 🔴🔴🔴');
      _log('🔧 [SIMULAR] ═══════════════════════════════════════════════════════');
      _log('🔧 [SIMULAR] Función _simulateArrivalAtStop INICIADA');
      
      final activeNav = IntegratedNavigationService.instance.activeNavigation;
      _log('🔴 activeNav = ${activeNav != null ? "NOT NULL" : "NULL"}');

    if (activeNav == null) {
      _log('🔴 activeNav is NULL - returning');
      _log('⚠️ [SIMULAR] No hay navegación activa');
      await TtsService.instance.speak('No hay navegación activa');
      _showWarningNotification(
        'Primero inicia navegación diciendo: ir a Costanera Center',
      );
      return;
    }

    _log('🔴 activeNav OK - currentStepIndex = ${activeNav.currentStepIndex}/${activeNav.steps.length}');
    _log('🔧 [SIMULAR] Navegación activa encontrada');
    _log('🔧 [SIMULAR] Paso actual: índice ${activeNav.currentStepIndex}/${activeNav.steps.length}');
    
    // Verificar si ya completamos todos los pasos
    if (activeNav.currentStepIndex >= activeNav.steps.length) {
      _log('🔴 Navigation completed - returning');
      _log('✅ [SIMULAR] Navegación completada');
      await TtsService.instance.speak('Navegación completada');
      _showSuccessNotification('Ruta completada');
      return;
    }
    
    final currentStep = activeNav.steps[activeNav.currentStepIndex];
    _log('🔴 currentStep.type = ${currentStep.type}');
    _log('🔧 [SIMULAR] Tipo de paso actual: ${currentStep.type}');
    _log('🔧 [SIMULAR] Instrucción: ${currentStep.instruction}');

    // ═══════════════════════════════════════════════════════════════
    // CASO ESPECIAL: WAIT_BUS - Usuario confirma que subió al bus
    // ═══════════════════════════════════════════════════════════════
    if (currentStep.type == 'wait_bus') {
      _log('🔴🔴🔴 ENTERING wait_bus BLOCK 🔴🔴🔴');
      _log('🚌 [SIMULAR] ══════════════════════════════════════════════════════');
      _log('🚌 [SIMULAR] Usuario confirmó que subió al bus desde wait_bus');
      _log('🚌 [SIMULAR] ══════════════════════════════════════════════════════');
      
      // Detener tracking de llegadas (usuario ya subió al bus)
      _log('🛑 [ARRIVALS] Deteniendo tracking - usuario subió al bus');
      BusArrivalsService.instance.stopTracking();
      
      // Feature de monitoreo de bus deshabilitada
      // _stopBusArrivalMonitoring();
      
      // Verificar que existe un siguiente paso de tipo ride_bus
      if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
        final nextStep = activeNav.steps[activeNav.currentStepIndex + 1];
        
        if (nextStep.type == 'ride_bus') {
          // ✅ NUEVA ESTRATEGIA: Usar servicio del backend para geometría exacta
          _log('🚌 [BUS] Solicitando geometría exacta desde backend...');
          
          final busRoute = nextStep.busRoute;
          final fromStopId = currentStep.stopId; // Paradero de subida
          final toStopId = nextStep.stopId; // Paradero de bajada
          
          List<LatLng> busGeometry = [];
          
          // Intentar obtener geometría exacta del backend (GTFS shapes)
          if (busRoute != null && fromStopId != null && toStopId != null) {
            _log('🚌 [BUS] Llamando servicio: Ruta $busRoute desde $fromStopId hasta $toStopId');
            
            final geometryResult = await BusGeometryService.instance.getBusSegmentGeometry(
              routeNumber: busRoute,
              fromStopCode: fromStopId,
              toStopCode: toStopId,
              fromLat: currentStep.location?.latitude,
              fromLon: currentStep.location?.longitude,
              toLat: nextStep.location?.latitude,
              toLon: nextStep.location?.longitude,
            );
            
            if (geometryResult != null && 
                BusGeometryService.instance.isValidGeometry(geometryResult.geometry)) {
              busGeometry = geometryResult.geometry;
              _log('✅ [BUS] Geometría obtenida desde backend (${geometryResult.source})');
              _log('✅ [BUS] ${busGeometry.length} puntos, ${geometryResult.distanceMeters.toStringAsFixed(0)}m');
              _log('✅ [BUS] ${geometryResult.numStops} paradas intermedias');
            } else {
              _log('⚠️ [BUS] Backend no retornó geometría válida, usando fallback');
            }
          }
          
          // FALLBACK: Si backend falla, usar geometría del itinerario
          if (busGeometry.isEmpty) {
            _log('🔄 [BUS] Usando geometría del itinerario como fallback');
            
            try {
              final busLeg = activeNav.itinerary.legs.firstWhere(
                (leg) => leg.type == 'bus' && leg.isRedBus,
                orElse: () => throw Exception('No bus leg found'),
              );
              
              busGeometry = busLeg.geometry ?? [];
              
              if (busGeometry.isNotEmpty) {
                _log('✅ [BUS] Geometría del itinerario: ${busGeometry.length} puntos');
                
                // Aplicar recorte manual solo como último recurso
                final originLocation = currentStep.location;
                final destinationLocation = nextStep.location;
                
                if (originLocation != null && destinationLocation != null) {
                  // Encontrar punto más cercano al origen
                  int startIndex = 0;
                  double minStartDist = double.infinity;
                  for (int i = 0; i < busGeometry.length; i++) {
                    final dist = Geolocator.distanceBetween(
                      originLocation.latitude,
                      originLocation.longitude,
                      busGeometry[i].latitude,
                      busGeometry[i].longitude,
                    );
                    if (dist < minStartDist) {
                      minStartDist = dist;
                      startIndex = i;
                    }
                  }
                  
                  // Encontrar punto más cercano al destino
                  int endIndex = busGeometry.length - 1;
                  double minEndDist = double.infinity;
                  for (int i = startIndex; i < busGeometry.length; i++) {
                    final dist = Geolocator.distanceBetween(
                      destinationLocation.latitude,
                      destinationLocation.longitude,
                      busGeometry[i].latitude,
                      busGeometry[i].longitude,
                    );
                    if (dist < minEndDist) {
                      minEndDist = dist;
                      endIndex = i;
                    }
                  }
                  
                  // Validar y recortar solo si tiene sentido
                  if (startIndex < endIndex && minStartDist < 500 && minEndDist < 500) {
                    busGeometry = busGeometry.sublist(startIndex, endIndex + 1);
                    _log('✅ [BUS] Geometría recortada: ${busGeometry.length} puntos');
                  } else {
                    _log('⚠️ [BUS] Recorte no válido, usando geometría completa');
                  }
                }
              }
            } catch (e) {
              _log('⚠️ [BUS] Error obteniendo geometría del itinerario: $e');
            }
          }
          
          // Dibujar la geometría final (si existe)
          if (busGeometry.isNotEmpty) {
            _log('🚌 [BUS] Dibujando ruta del bus: ${busGeometry.length} puntos');
            
            setState(() {
              _simulationPolylines = [
                Polyline(
                  points: busGeometry,
                  color: const Color(0xFFE30613), // ROJO para ruta de bus
                  strokeWidth: 5.0,
                ),
              ];
              // Actualizar marcadores para mostrar todos los paraderos
              _updateNavigationMarkers(nextStep, activeNav);
            });
          } else {
            _log('❌ [BUS] No se pudo obtener geometría del bus');
            // Limpiar polilínea si no hay geometría
            setState(() {
              _simulationPolylines = [];
              _updateNavigationMarkers(nextStep, activeNav);
            });
          }
          
          // Vibración de confirmación
          final hasVibrator = await Vibration.hasVibrator();
          if (hasVibrator == true) {
            Vibration.vibrate(duration: 200);
          }
          
          // ✅ MEJORA: Mensaje TTS combinado con información del destino
          final destinationName = nextStep.stopName ?? 'tu parada';
          final totalStops = nextStep.totalStops ?? 0;
          
          String ttsMessage = 'Subiendo al bus Red ${busRoute ?? ""}';
          
          if (totalStops > 0) {
            ttsMessage += '. Viajarás $totalStops paradas hasta $destinationName';
          } else if (destinationName.isNotEmpty) {
            ttsMessage += '. Destino: $destinationName';
          }
          
          // Anunciar mensaje completo
          await TtsService.instance.speak(ttsMessage, urgent: true);
          
          _log('🗣️ [TTS] Anunciando: $ttsMessage');
          
          // ✅ ESPERAR 3 segundos para que el TTS tenga tiempo de hablar
          await Future.delayed(const Duration(seconds: 3));
        } else {
          _log('⚠️ [SIMULAR] Siguiente paso no es ride_bus: ${nextStep.type}');
        }
      }
      
      // ✅ CRÍTICO: Resetear índice de paradas para el nuevo viaje en bus
      // Como las paradas en step.busStops ya vienen recortadas (solo del viaje del usuario),
      // simplemente reseteamos a 0 para empezar desde la primera parada
      _log('🚌 [RIDE_BUS] Reseteando _currentSimulatedBusStopIndex a 0 (primera parada del viaje)');
      _currentSimulatedBusStopIndex = 0;
      
      // Avanzar al siguiente paso (ride_bus)
      _log('📍 [STEP] Avanzando de wait_bus → ride_bus');
      IntegratedNavigationService.instance.advanceToNextStep();
      if (mounted) {
        setState(() {
          _updateNavigationMapState(IntegratedNavigationService.instance.activeNavigation!);
        });
      }
      return;
    }

    // SIMULAR MOVIMIENTO GPS REALISTA SEGÚN EL TIPO DE PASO
    _log('🔧 [SIMULAR] Iniciando simulación GPS para: ${currentStep.type}');
    _showSuccessNotification('Simulando: ${currentStep.type}');

    if (currentStep.type == 'walk') {
      // SIMULAR CAMINATA: Mover GPS punto por punto a lo largo de la geometría
      _log('🚶 [SIMULAR] Caminata - Moviendo GPS por geometría');
      
      final geometry = _getCurrentStepGeometryCached();
      
      if (geometry.isEmpty) {
        _log('⚠️ [SIMULAR] Sin geometría para simular');
        await TtsService.instance.speak('Sin datos de ruta');
        return;
      }
      
      // ✅ Planificar desviación aleatoria (40% probabilidad)
      _resetSimulationDeviation();
      _planSimulationDeviation(geometry);
      
      // ✅ Cancelar simulación previa usando TimerManagerMixin
      cancelTimer('walkSimulation');
      
      // ✅ CRÍTICO: Dibujar la geometría COMPLETA al inicio para que sea visible desde el principio
      // Esto asegura que el usuario vea la ruta roja inmediatamente al presionar "Simular"
      _log('🎨 [SIMULAR] Dibujando geometría completa inicial: ${geometry.length} puntos');
      
      // Activar modo simulación para evitar auto-centrado
      setState(() {
        _isSimulating = true;
        
        // ✅ DIBUJAR RUTA COMPLETA AL INICIO
        _simulationPolylines = [
          Polyline(
            points: geometry,
            color: const Color(0xFFE30613), // Rojo desde el inicio
            strokeWidth: 5.0,
          ),
        ];
        
        // ✅ INICIALIZAR MARCADORES antes de comenzar la simulación
        _updateNavigationMarkers(currentStep, activeNav);
      });
      
      int currentPointIndex = 0;
      final totalPoints = geometry.length;
      final totalSimulationPoints = totalPoints + (_simulationDeviationRoute?.length ?? 0);
      final pointsPerInstruction = (totalPoints / (currentStep.streetInstructions?.length ?? 1)).ceil();
      
      // Variable para rastrear la última instrucción anunciada
      int lastAnnouncedInstruction = -1;
      
      // ✅ Timer periódico usando TimerManagerMixin
      createPeriodicTimer(
        const Duration(seconds: 5), // Reducido de 2 a 5 segundos para mejor control
        (timer) async {
        // ═══════════════════════════════════════════════════════════════
        // VERIFICAR SI LLEGAMOS AL DESTINO (últimos 2-3 puntos)
        // ═══════════════════════════════════════════════════════════════
        final isNearEnd = currentPointIndex >= totalSimulationPoints - 2;
        final isAtEnd = currentPointIndex >= totalSimulationPoints;
        
        if (isAtEnd) {
          cancelTimer('walkSimulation');
          _log('✅ [SIMULAR] Caminata completada - Llegamos al destino');
          
          // Resetear desviación
          _resetSimulationDeviation();
          
          // ✅ CRÍTICO: Restaurar navegación real después de simulación
          // Desactivar modo simulación y actualizar geometría desde el mixin
          setState(() {
            _isSimulating = false;
            _simulationPolylines.clear(); // Limpiar polylines de simulación
          });
          
          // Restaurar geometría del mixin para navegación real
          final activeNavAfterSim = IntegratedNavigationService.instance.activeNavigation;
          if (activeNavAfterSim != null && mounted) {
            await updateNavigationGeometry(
              navigation: activeNavAfterSim, 
              forceRefresh: true,
            );
            if (mounted) {
              setState(() {}); // Forzar rebuild para mostrar navigationPolylines
            }
          }
          
          // Vibración de llegada (doble vibración)
          final hasVibrator = await Vibration.hasVibrator();
          if (hasVibrator == true) {
            Vibration.vibrate(duration: 150);
            await Future.delayed(const Duration(milliseconds: 200));
            Vibration.vibrate(duration: 150);
          }
          
          // Detectar si es el destino final o un paradero intermedio
          final isLastStep = activeNav.currentStepIndex >= activeNav.steps.length - 1;
          if (isLastStep) {
          // ═══════════════════════════════════════════════════════════════
          // DESTINO FINAL - Mantener polilínea visible
          // ═══════════════════════════════════════════════════════════════
            await TtsService.instance.speak('Has llegado a tu destino, ${currentStep.stopName}', urgent: true);
            
            // ✅ FIX: Mantener la polilínea completa visible (no solo último punto)
            // Una polilínea necesita al menos 2 puntos para dibujarse
            setState(() {
              if (geometry.length >= 2) {
                // Mostrar toda la ruta recorrida en verde
                _simulationPolylines = [
                  Polyline(
                    points: geometry,
                    color: const Color(0xFF10B981), // Verde para destino completado
                    strokeWidth: 5.0,
                  ),
                ];
              } else if (geometry.isNotEmpty && _currentPosition != null) {
                // Fallback: crear línea desde posición actual al destino
                _simulationPolylines = [
                  Polyline(
                    points: [
                      LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
                      geometry.last
                    ],
                    color: const Color(0xFF10B981),
                    strokeWidth: 5.0,
                  ),
                ];
              }
            });            // Finalizar navegación después de un delay
            await Future.delayed(const Duration(seconds: 2));
            IntegratedNavigationService.instance.stopNavigation();
          } else {
            // ═══════════════════════════════════════════════════════════════
            // LLEGADA AL PARADERO - Proceso más realista
            // ═══════════════════════════════════════════════════════════════
            final nextStep = activeNav.steps[activeNav.currentStepIndex + 1];
            _log('🚏 [SIMULAR] Llegaste al paradero. Siguiente paso: ${nextStep.type}');
            
            if (nextStep.type == 'wait_bus') {
              // PRIMERO: Anunciar llegada ANTES de cambiar el paso
              await TtsService.instance.speak(
                'Has llegado al paradero ${nextStep.stopName}.',
                urgent: true,
              );
              
              await Future.delayed(const Duration(milliseconds: 800));
              
              // SEGUNDO: Avanzar al paso wait_bus
              IntegratedNavigationService.instance.advanceToNextStep();
              
              // ═══════════════════════════════════════════════════════════════
              // OBTENER TIEMPO DE LLEGADA DEL BUS
              // ═══════════════════════════════════════════════════════════════
              String waitMessage;
              final stopCode = nextStep.stopId;
              final routeNumber = nextStep.busRoute;
              
              if (stopCode != null && stopCode.isNotEmpty && routeNumber != null) {
                _log('📡 [ARRIVALS] Consultando llegada del bus $routeNumber en paradero $stopCode');
                final arrivals = await BusArrivalsService.instance.getBusArrivals(stopCode);
                
                // Feature de monitoreo en tiempo real deshabilitada
                // _startBusArrivalMonitoring(stopCode, routeNumber);
                
                if (arrivals != null) {
                  final targetBus = arrivals.findBus(routeNumber);
                  
                  if (targetBus != null) {
                    final minutes = targetBus.estimatedMinutes;
                    _log('� [ARRIVALS] Bus $routeNumber llegaría en $minutes minutos');
                    
                    if (minutes <= 0) {
                      waitMessage = 'El bus $routeNumber está llegando al paradero ahora.';
                    } else if (minutes <= 3) {
                      waitMessage = 'Prepárate, el bus $routeNumber está llegando al paradero.';
                    } else if (minutes <= 10) {
                      waitMessage = 'Espera el bus $routeNumber, llegaría en $minutes minutos.';
                    } else {
                      waitMessage = 'Espera el bus $routeNumber, llegaría en aproximadamente ${targetBus.formattedTime}.';
                    }
                  } else {
                    _log('⚠️ [ARRIVALS] Bus $routeNumber no encontrado en llegadas');
                    waitMessage = 'Espera el bus $routeNumber en este paradero.';
                  }
                } else {
                  _log('⚠️ [ARRIVALS] No se pudieron obtener llegadas para paradero $stopCode');
                  waitMessage = 'Espera el bus $routeNumber en este paradero.';
                }
              } else {
                _log('⚠️ [ARRIVALS] Sin código de paradero o ruta de bus');
                waitMessage = routeNumber != null 
                    ? 'Espera el bus $routeNumber en este paradero.'
                    : 'Espera el bus en este paradero.';
              }
              
              // TERCERO: Anunciar instrucción de espera CON TIEMPO ESTIMADO
              await TtsService.instance.speak(waitMessage, urgent: true);
              
              // CUARTO: Actualizar UI para mostrar paraderos
              if (mounted) {
                setState(() {
                  // ✅ Desactivar simulación y limpiar polylines
                  _isSimulating = false;
                  _simulationPolylines.clear();
                });
                
                // ✅ Actualizar geometría desde el mixin (wait_bus limpia la geometría)
                await updateNavigationGeometry(
                  navigation: IntegratedNavigationService.instance.activeNavigation!,
                  forceRefresh: true,
                );
                
                // Actualizar marcadores para mostrar paraderos de bus
                if (mounted) {
                  setState(() {
                    _updateNavigationMarkers(
                      IntegratedNavigationService.instance.activeNavigation!.currentStep!,
                      IntegratedNavigationService.instance.activeNavigation!,
                    );
                  });
                }
              }
              
              _log('🚏 [SIMULAR] Paso actual ahora: wait_bus. Esperando que el usuario suba al bus.');
            } else {
              // Fallback si no hay wait_bus (no debería pasar)
              await TtsService.instance.speak('Llegaste al paradero', urgent: true);
              _log('⚠️ [SIMULAR] Siguiente paso no es wait_bus: ${nextStep.type}');
            }
          }
          return;
        }
        
        // ═══════════════════════════════════════════════════════════════
        // SIMULACIÓN CONTINUA - Moverse al siguiente punto
        // ═══════════════════════════════════════════════════════════════
        
        // ✅ Obtener siguiente punto (con lógica de desviación incluida)
        final nextPoint = _getNextSimulationPoint(geometry, currentPointIndex);
        
        // Mover GPS al siguiente punto (SIN mover el mapa para permitir interacción)
        _updateSimulatedGPS(nextPoint, moveMap: false);
        
        // ✅ ACTUALIZAR POLILÍNEA: mostrar solo el camino restante desde el punto actual
        // IMPORTANTE: Mantener al menos los últimos 2 puntos para que no desaparezca
        // Y MANTENER LOS MARCADORES (paradero destino, usuario, etc.)
        setState(() {
          final remainingGeometry = currentPointIndex < geometry.length 
              ? geometry.sublist(currentPointIndex)
              : [geometry.last]; // Mantener último punto si llegamos al final
          
          _simulationPolylines = [
            Polyline(
              points: remainingGeometry,
              color: isNearEnd 
                  ? const Color(0xFF10B981) // Verde cuando estamos cerca
                  : const Color(0xFFE30613), // Rojo normal
              strokeWidth: 5.0,
            ),
          ];
          
          // ✅ MANTENER MARCADORES: Actualizar marcadores en cada iteración
          // para que no desaparezcan durante la simulación
          _updateNavigationMarkers(currentStep, activeNav);
        });
        
        // Anunciar instrucción cuando se alcanza un nuevo segmento (solo si NO está desviado)
        if (!_isCurrentlyDeviated && 
            currentStep.streetInstructions != null && 
            currentStep.streetInstructions!.isNotEmpty) {
          final instructionIndex = (currentPointIndex / pointsPerInstruction).floor()
              .clamp(0, currentStep.streetInstructions!.length - 1);
          
          // Solo anunciar si es una nueva instrucción
          if (instructionIndex != lastAnnouncedInstruction && instructionIndex < currentStep.streetInstructions!.length) {
            final instruction = currentStep.streetInstructions![instructionIndex];
            lastAnnouncedInstruction = instructionIndex;
            
            _log('📍 [SIMULAR] Nueva instrucción (${instructionIndex + 1}/${currentStep.streetInstructions!.length}): $instruction');
            
            // Anunciar la instrucción por TTS
            await TtsService.instance.speak(instruction, urgent: false);
          }
        }
        
        currentPointIndex++;
        // ✅ No necesita setState aquí porque se actualiza en el bloque anterior
      },
        name: 'walkSimulation',
      );
      
    } else if (currentStep.type == 'ride_bus') {
      // ═══════════════════════════════════════════════════════════════
      // SIMULAR VIAJE EN BUS: Mover GPS por cada parada
      // ═══════════════════════════════════════════════════════════════
      _log('🚌 [SIMULAR] Viaje en bus - Moviendo GPS por paradas');
      
      // Dar un pequeño delay antes de empezar
      await Future.delayed(const Duration(milliseconds: 500));
      
      // Obtener paradas del bus
      final busLeg = activeNav.itinerary.legs.firstWhere(
        (leg) => leg.type == 'bus' && leg.isRedBus,
        orElse: () => throw Exception('No bus leg found'),
      );
      
      final allStops = busLeg.stops ?? [];
      if (allStops.isEmpty) {
        _log('⚠️ [SIMULAR] Sin paradas para simular');
        await TtsService.instance.speak('Viaje en bus completado');
        IntegratedNavigationService.instance.advanceToNextStep();
        if (mounted) {
          setState(() {
            _updateNavigationMapState(activeNav);
          });
        }
        return;
      }
      
      // ✅ ENCONTRAR ÍNDICE REAL del paradero de origen (donde subimos)
      // El origen está en el paso wait_bus anterior
      int startStopIndex = 0;
      LatLng? originLocation;
      
      // Buscar el paso wait_bus anterior
      if (activeNav.currentStepIndex > 0) {
        final previousStep = activeNav.steps[activeNav.currentStepIndex - 1];
        _log('🚌 [SIMULAR] Paso anterior: ${previousStep.type} - ${previousStep.stopName}');
        if (previousStep.type == 'wait_bus' && previousStep.location != null) {
          originLocation = previousStep.location;
          _log('🚌 [SIMULAR] Origen tomado del paso wait_bus: ${previousStep.stopName} en $originLocation');
        } else {
          _log('⚠️ [SIMULAR] Paso anterior no es wait_bus o no tiene location');
        }
      }
      
      // Fallback: usar posición actual del GPS
      if (originLocation == null && _currentPosition != null) {
        originLocation = LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
        _log('🚌 [SIMULAR] Origen tomado del GPS actual: $originLocation');
      }
      
      _log('🚌 [SIMULAR] Total de paradas en busLeg: ${allStops.length}');
      _log('🚌 [SIMULAR] Primera parada: ${allStops.first.name} en ${allStops.first.location}');
      _log('🚌 [SIMULAR] Última parada: ${allStops.last.name} en ${allStops.last.location}');
      
      if (originLocation != null) {
        double minDistance = double.infinity;
        for (int i = 0; i < allStops.length; i++) {
          final distance = Geolocator.distanceBetween(
            originLocation.latitude,
            originLocation.longitude,
            allStops[i].location.latitude,
            allStops[i].location.longitude,
          );
          if (distance < minDistance) {
            minDistance = distance;
            startStopIndex = i;
          }
        }
        _log('🚌 [SIMULAR] Paradero de origen encontrado: índice $startStopIndex (${allStops[startStopIndex].name}) a ${minDistance.toStringAsFixed(0)}m');
      } else {
        _log('⚠️ [SIMULAR] No hay location en currentStep, usando primer paradero');
      }
      
      // ✅ ENCONTRAR ÍNDICE REAL del paradero de destino (donde bajamos)
      // El ride_bus tiene location que apunta al paradero de bajada
      int endStopIndex = allStops.length - 1;
      
      if (currentStep.location != null) {
        // Buscar desde el paradero de origen hacia adelante
        double minDistance = double.infinity;
        for (int i = startStopIndex + 1; i < allStops.length; i++) {
          final distance = Geolocator.distanceBetween(
            currentStep.location!.latitude,
            currentStep.location!.longitude,
            allStops[i].location.latitude,
            allStops[i].location.longitude,
          );
          if (distance < minDistance) {
            minDistance = distance;
            endStopIndex = i;
          }
        }
        _log('🚌 [SIMULAR] Paradero de destino encontrado: índice $endStopIndex (${allStops[endStopIndex].name}) a ${minDistance.toStringAsFixed(0)}m');
      } else {
        _log('⚠️ [SIMULAR] No hay destino definido, usando última parada');
      }
      
      // ✅ RECORTAR lista de paradas para simular SOLO desde origen hasta destino
      final stopsToSimulate = allStops.sublist(startStopIndex, endStopIndex + 1);
      _log('🚌 [SIMULAR] Simulando ${stopsToSimulate.length} paradas (desde $startStopIndex hasta $endStopIndex)');
      
      // ✅ Cancelar timer previo usando TimerManagerMixin
      cancelTimer('walkSimulation');
      
      // Activar modo simulación
      setState(() {
        _isSimulating = true;
        _currentSimulatedBusStopIndex = startStopIndex; // ✅ EMPEZAR desde el índice real
      });
      
      int currentLocalIndex = 0; // Índice local en stopsToSimulate
      
      // Determinar qué paraderos anunciar (evitar spam en rutas largas)
      final importantStopIndices = _getImportantStopIndices(stopsToSimulate.length);
      
      // Anunciar primera parada
      await TtsService.instance.speak(
        'Partiendo desde ${stopsToSimulate[0].name}',
        urgent: false,
      );
      
      // ✅ Timer periódico usando TimerManagerMixin  
      createPeriodicTimer(
        const Duration(seconds: 8),
        (timer) async {
        if (currentLocalIndex >= stopsToSimulate.length) {
          cancelTimer('walkSimulation');
          _log('✅ [SIMULAR] Viaje en bus completado');
          
          // Desactivar modo simulación
          setState(() {
            _isSimulating = false;
            _currentSimulatedBusStopIndex = -1; // Resetear índice
          });
          
          // Vibración al bajar del bus (triple vibración)
          final hasVibrator = await Vibration.hasVibrator();
          if (hasVibrator == true) {
            Vibration.vibrate(duration: 100);
            await Future.delayed(const Duration(milliseconds: 150));
            Vibration.vibrate(duration: 100);
            await Future.delayed(const Duration(milliseconds: 150));
            Vibration.vibrate(duration: 100);
          }
          
          await TtsService.instance.speak('Bajaste del bus', urgent: true);
          
          // Pausa para que el usuario procese la información
          await Future.delayed(const Duration(milliseconds: 1500));
          
          // Avanzar al siguiente paso (probablemente walk final)
          if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
            IntegratedNavigationService.instance.advanceToNextStep();
            
            // Anunciar el siguiente paso
            final nextStep = IntegratedNavigationService.instance.activeNavigation?.currentStep;
            if (nextStep?.type == 'walk') {
              await TtsService.instance.speak(
                'Ahora camina hacia tu destino final. Presiona "Simular" para continuar.',
                urgent: true,
              );
            }
            
            if (mounted) {
              setState(() {
                _updateNavigationMapState(IntegratedNavigationService.instance.activeNavigation!);
              });
            }
          }
          return;
        }
        
        // Mover GPS a la parada (SIN mover el mapa para permitir interacción)
        final stop = stopsToSimulate[currentLocalIndex];
        final globalStopIndex = startStopIndex + currentLocalIndex; // Índice real en allStops
        _updateSimulatedGPS(stop.location, moveMap: false);
        
        final isFirstStop = currentLocalIndex == 0;
        final isLastStop = currentLocalIndex == stopsToSimulate.length - 1;
        final isImportantStop = importantStopIndices.contains(currentLocalIndex);
        
        // Anunciar SOLO paraderos importantes para evitar spam
        String announcement = '';
        if (isLastStop) {
          announcement = 'Próxima parada: ${stop.name}. Prepárate para bajar';
          // Vibración más fuerte para última parada
          final hasVibrator = await Vibration.hasVibrator();
          if (hasVibrator == true) {
            Vibration.vibrate(duration: 300);
          }
        } else if (isImportantStop && !isFirstStop) {
          // Anunciar paraderos importantes (cada N paradas)
          final stopCode = stop.code != null ? 'código ${stop.code}' : '';
          announcement = 'Paradero ${stop.name} $stopCode';
          // Vibración sutil para paraderos importantes
          final hasVibrator = await Vibration.hasVibrator();
          if (hasVibrator == true) {
            Vibration.vibrate(duration: 100);
          }
        }
        
        if (announcement.isNotEmpty) {
          await TtsService.instance.speak(announcement, urgent: false);
        }
        
        _log('🚏 [SIMULAR] Parada ${currentLocalIndex + 1}/${stopsToSimulate.length} (global: ${globalStopIndex + 1}/${allStops.length}): ${stop.name} ${stop.code ?? ""}');
        
        currentLocalIndex++;
        
        if (mounted) {
          setState(() {
            _currentSimulatedBusStopIndex = globalStopIndex + 1; // ✅ Actualizar índice GLOBAL
            
            // ✅ Actualizar marcadores para reflejar progreso en el viaje
            final activeNav = IntegratedNavigationService.instance.activeNavigation;
            if (activeNav != null) {
              _updateNavigationMarkers(activeNav.currentStep, activeNav);
            }
          });
        }
      },
        name: 'walkSimulation',
      );
      
    } else {
      // Otros tipos de pasos
      _log('⚠️ [SIMULAR] Tipo no manejado: ${currentStep.type}');
      await TtsService.instance.speak('Paso completado');
      
      if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
        IntegratedNavigationService.instance.advanceToNextStep();
        if (mounted) {
          setState(() {
            _updateNavigationMapState(activeNav);
          });
        }
      }
    }
    } catch (e, stackTrace) {
      _log('🔴🔴🔴 EXCEPTION in _simulateArrivalAtStop: $e');
      _log('🔴🔴🔴 Stack trace: $stackTrace');
    }
  }

  /// Determina qué paraderos son importantes para anunciar según la longitud del viaje
  /// Evita spam en rutas largas anunciando solo paraderos clave
  Set<int> _getImportantStopIndices(int totalStops) {
    final Set<int> importantIndices = {};
    
    if (totalStops <= 5) {
      // Ruta corta: anunciar todos los intermedios
      for (int i = 1; i < totalStops - 1; i++) {
        importantIndices.add(i);
      }
    } else if (totalStops <= 10) {
      // Ruta mediana: anunciar cada 2 paradas
      for (int i = 1; i < totalStops - 1; i += 2) {
        importantIndices.add(i);
      }
    } else if (totalStops <= 20) {
      // Ruta larga: anunciar cada 3 paradas
      for (int i = 1; i < totalStops - 1; i += 3) {
        importantIndices.add(i);
      }
    } else {
      // Ruta muy larga: anunciar cada 5 paradas
      for (int i = 1; i < totalStops - 1; i += 5) {
        importantIndices.add(i);
      }
    }
    
    // Siempre incluir el penúltimo para dar aviso antes del final
    if (totalStops > 2) {
      importantIndices.add(totalStops - 2);
    }
    
    return importantIndices;
  }

  /// Obtiene las instrucciones de caminata activas
  List<String>? _getActiveWalkInstructions() {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    final step = activeNav?.currentStep;

    if (step != null &&
        step.type == 'walk' &&
        step.streetInstructions != null &&
        step.streetInstructions!.isNotEmpty) {
      return step.streetInstructions;
    }

    if (_currentInstructions.isNotEmpty) {
      return _currentInstructions;
    }

    return null;
  }

  void _focusOnInstruction(int index, {bool speak = true}) {
    final instructions = _getActiveWalkInstructions();
    if (instructions == null || instructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones activas');
      return;
    }

    int clampedIndex = index;
    if (clampedIndex < 0) {
      clampedIndex = 0;
    } else if (clampedIndex >= instructions.length) {
      clampedIndex = instructions.length - 1;
    }

    if (speak) {
      final instruction = instructions[clampedIndex];
      TtsService.instance.speak('Paso ${clampedIndex + 1}: $instruction');
    }
  }

  // Calcular nueva posición dado bearing y distancia
  void _moveMap(LatLng target, double zoom) {
    // Movimiento inmediato (solo se usa para carga inicial del mapa)
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
        return;
      }

      // ⚡ OPTIMIZACIÓN 1: Usar última posición conocida para centrar inmediatamente
      final lastKnownPosition = await Geolocator.getLastKnownPosition();
      if (lastKnownPosition != null && mounted) {
        _currentPosition = lastKnownPosition;
        _updateCurrentLocationMarker();
        _moveMap(
          LatLng(lastKnownPosition.latitude, lastKnownPosition.longitude),
          14.0,
        );
        _log('⚡ [GPS RÁPIDO] Centrado con última posición conocida');
      }

      // ⚡ OPTIMIZACIÓN 2: Obtener posición actual con precisión media primero (más rápido)
      try {
        _currentPosition = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium, // Cambio: medium es más rápido que high
            // ❌ SIN timeLimit - permite esperar el tiempo necesario
            // En dispositivos lentos o con mala señal, el timeout puede ser problemático
          ),
        );

        if (!mounted) return;

        // Actualizar con la nueva posición
        _updateCurrentLocationMarker();

        // Move camera to current location if map is ready
        if (_currentPosition != null) {
          _moveMap(
            LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            14.0,
          );
          _log('📍 [GPS] Centrado con posición actual (precisión media)');
        }
      } catch (e) {
        // ✅ No es fatal: el listener de GPS se configurará de todas formas
        _log('⚠️ [GPS INIT] Error obteniendo posición inicial (no es grave): $e');
        // ✅ NO anunciar por TTS, es molesto y el GPS funcionará después
      }

      // Configurar listener de GPS en tiempo real (con alta precisión)
      // ✅ Esto se ejecuta SIEMPRE, incluso si getCurrentPosition falló
      _setupGPSListener();
    } catch (e) {
      if (!mounted) return;
      _log('⚠️ [GPS] Error crítico en inicialización de ubicación: $e', error: e);
      // Solo anunciar si es un error realmente grave (permisos denegados, etc.)
      if (e.toString().contains('denied') || e.toString().contains('permission')) {
        TtsService.instance.speak('Error: permisos de ubicación denegados');
      }
    }
  }

  /// Configura el listener de GPS para navegación en tiempo real
  void _setupGPSListener() {
    // ⚡ OPTIMIZACIÓN: Configuración balanceada para rendimiento y precisión
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high, // Alta precisión para navegación
      distanceFilter: 5, // Actualizar cada 5 metros (más reactivo que 10m)
      // ❌ SIN timeLimit - el GPS debe funcionar indefinidamente
      // El timeout de 30 segundos estaba causando crashes en dispositivos lentos
    );

    Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position position) {
        if (!mounted) return;

        setState(() {
          _currentPosition = position;
        });

        _updateCurrentLocationMarker();

        // NO AUTO-CENTRAR - el usuario tiene control total del mapa

        // Verificar llegada a waypoint si hay navegación activa
        _checkArrivalAtWaypoint(position);
      },
      onError: (error) {
        _log('❌ [GPS] Error en stream de ubicación: $error', error: error);
      },
    );
  }

  /// Verifica si el usuario llegó a un waypoint de la ruta
  void _checkArrivalAtWaypoint(Position currentPos) {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null || activeNav.isComplete) return;

    final currentStep = activeNav.steps[activeNav.currentStepIndex];
    
    // Solo verificar en pasos de caminata
    if (currentStep.type != 'walk') return;

    // Usar geometría cacheada
    final stepGeometry = _getCurrentStepGeometryCached();
    if (stepGeometry.isEmpty) return;

    // Obtener el waypoint destino del paso actual
    final targetWaypoint = stepGeometry.last;
    
    final distanceToTarget = Geolocator.distanceBetween(
      currentPos.latitude,
      currentPos.longitude,
      targetWaypoint.latitude,
      targetWaypoint.longitude,
    );

    // ✅ NUEVO: Alertas de proximidad para giros
    _checkProximityAlerts(currentPos, currentStep, stepGeometry);
    
    // ✅ NUEVO: Detectar desviación de la ruta
    _checkDeviationFromRoute(currentPos, stepGeometry);

    // Umbral de llegada: 15 metros
    const double arrivalThreshold = 15.0;

    if (distanceToTarget <= arrivalThreshold) {
      _log('✅ [GPS] Llegada a waypoint detectada (${distanceToTarget.toStringAsFixed(1)}m)');
      
      // Anunciar llegada
      TtsService.instance.speak('Has llegado al waypoint');
      _showSuccessNotification('Waypoint alcanzado');

      // Avanzar al siguiente paso si es posible
      if (activeNav.currentStepIndex < activeNav.steps.length - 1) {
        Future.delayed(const Duration(seconds: 2), () {
          IntegratedNavigationService.instance.advanceToNextStep();
          if (mounted) {
            setState(() {
              _updateNavigationMapState(activeNav);
            });
          }
        });
      }
    }
  }
  
  /// ✅ NUEVO: Detecta proximidad a giros y alerta al usuario
  DateTime? _lastProximityAlert;
  
  void _checkProximityAlerts(Position currentPos, dynamic currentStep, List<LatLng> geometry) {
    // No alertar más de una vez cada 15 segundos
    if (_lastProximityAlert != null && 
        DateTime.now().difference(_lastProximityAlert!) < const Duration(seconds: 15)) {
      return;
    }
    
    // Verificar si hay instrucciones de calle
    if (currentStep.streetInstructions == null || 
        currentStep.streetInstructions!.isEmpty) {
      return;
    }
    
    final instructions = currentStep.streetInstructions! as List<String>;
    
    // Calcular índice de instrucción actual (sin anunciar)
    final currentInstructionIndex = _calculateCurrentInstructionIndexSilent(
      instructions: instructions,
      geometry: geometry,
    );
    
    // Si hay una siguiente instrucción
    if (currentInstructionIndex < instructions.length - 1) {
      final nextInstruction = instructions[currentInstructionIndex + 1];
      
      // Estimar distancia a la siguiente instrucción
      // (dividir geometría entre instrucciones)
      final pointsPerInstruction = geometry.length / instructions.length;
      final nextInstructionPointIndex = ((currentInstructionIndex + 1) * pointsPerInstruction).round();
      
      if (nextInstructionPointIndex < geometry.length) {
        final nextInstructionPoint = geometry[nextInstructionPointIndex];
        
        final distanceToNextInstruction = Geolocator.distanceBetween(
          currentPos.latitude,
          currentPos.longitude,
          nextInstructionPoint.latitude,
          nextInstructionPoint.longitude,
        );
        
        // ALERTA: Giro en 50 metros
        if (distanceToNextInstruction < 50 && distanceToNextInstruction > 30) {
          _lastProximityAlert = DateTime.now();
          SmartVibrationService.instance.vibrate(VibrationType.nearTurn);
          TtsService.instance.speak('En 50 metros, $nextInstruction', urgent: false);
          _log('⚠️ [PROXIMITY] Alerta 50m: $nextInstruction');
        }
        // ALERTA CRÍTICA: Giro en 10 metros
        else if (distanceToNextInstruction < 10) {
          _lastProximityAlert = DateTime.now();
          SmartVibrationService.instance.vibrate(VibrationType.criticalTurn);
          TtsService.instance.speak('Ahora, $nextInstruction', urgent: true);
          _log('🔴 [PROXIMITY] Alerta CRÍTICA: $nextInstruction');
        }
      }
    }
  }
  
  /// Versión silenciosa que no anuncia (para alertas de proximidad)
  int _calculateCurrentInstructionIndexSilent({
    required List<String> instructions,
    required List<LatLng> geometry,
  }) {
    if (_currentPosition == null || geometry.isEmpty || geometry.length < 2) return 0;
    
    final userLat = _currentPosition!.latitude;
    final userLon = _currentPosition!.longitude;
    
    int closestPointIndex = 0;
    double minDistance = double.infinity;
    
    for (int i = 0; i < geometry.length; i++) {
      final distance = Geolocator.distanceBetween(
        userLat,
        userLon,
        geometry[i].latitude,
        geometry[i].longitude,
      );
      
      if (distance < minDistance) {
        minDistance = distance;
        closestPointIndex = i;
      }
    }
    
    final progress = closestPointIndex / geometry.length;
    final instructionIndex = (progress * instructions.length).floor();
    
    return instructionIndex.clamp(0, instructions.length - 1);
  }
  
  /// ✅ NUEVO: Detecta si el usuario se desvió de la ruta
  DateTime? _lastDeviationCheck;
  bool _isCurrentlyOffRoute = false;
  
  void _checkDeviationFromRoute(Position currentPos, List<LatLng> geometry) {
    // No verificar más de una vez cada 10 segundos
    if (_lastDeviationCheck != null && 
        DateTime.now().difference(_lastDeviationCheck!) < const Duration(seconds: 10)) {
      return;
    }
    
    _lastDeviationCheck = DateTime.now();
    
    if (geometry.isEmpty) return;
    
    // Encontrar distancia al punto más cercano de la ruta
    double minDistanceToRoute = double.infinity;
    for (final point in geometry) {
      final distance = Geolocator.distanceBetween(
        currentPos.latitude,
        currentPos.longitude,
        point.latitude,
        point.longitude,
      );
      minDistanceToRoute = math.min(minDistanceToRoute, distance);
    }
    
    // UMBRAL: Si está a más de 30m de la ruta, se considera desviado
    const double deviationThreshold = 30.0;
    
    if (minDistanceToRoute > deviationThreshold && !_isCurrentlyOffRoute) {
      _isCurrentlyOffRoute = true;
      _handleDeviation(currentPos, minDistanceToRoute);
    } else if (minDistanceToRoute <= deviationThreshold && _isCurrentlyOffRoute) {
      // Usuario volvió a la ruta
      _isCurrentlyOffRoute = false;
      SmartVibrationService.instance.vibrate(VibrationType.success);
      TtsService.instance.speak('Has vuelto a la ruta correcta', urgent: false);
      _log('✅ [DEVIATION] Usuario volvió a la ruta');
    }
  }
  
  /// Maneja la desviación del usuario de la ruta planificada
  Future<void> _handleDeviation(Position pos, double distance) async {
    _log('⚠️ [DEVIATION] Desviación detectada: ${distance.toStringAsFixed(1)}m de la ruta');
    
    // Vibración de alerta
    await SmartVibrationService.instance.vibrate(VibrationType.deviation);
    
    // Anunciar desviación
    await TtsService.instance.speak(
      'Te desviaste de la ruta. Recalculando...',
      urgent: true,
    );
    
    _showWarningNotification('Fuera de ruta - Recalculando');
    
    // RECALCULAR ruta desde posición actual
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav != null) {
      try {
        // Obtener destino final
        final finalDestination = activeNav.steps.last;
        
        if (finalDestination.location != null) {
          _log('🔄 [DEVIATION] Recalculando ruta desde posición actual');
          
          // Obtener nombre del destino
          final destinationName = finalDestination.stopName ?? finalDestination.instruction;
          
          // Reiniciar navegación desde posición actual al mismo destino
          await _startIntegratedMoovitNavigation(
            destinationName,
            finalDestination.location!.latitude,
            finalDestination.location!.longitude,
          );
          
          await TtsService.instance.speak(
            'Nueva ruta calculada. Sigue las instrucciones.',
            urgent: true,
          );
        }
      } catch (e) {
        _log('❌ [DEVIATION] Error recalculando ruta: $e');
        await TtsService.instance.speak(
          'No se pudo recalcular la ruta. Intenta volver a la ruta original.',
          urgent: true,
        );
      }
    }
  }
  
  // MONITOREO DE LLEGADAS DE BUS - FEATURE DESHABILITADA
  // (Requiere TripAlertsService que fue eliminado por no estar integrado)
  // TODO: Implementar usando IntegratedNavigationService si es necesario

  void _updateCurrentLocationMarker() {
    if (_currentPosition == null || !mounted) return;

    final currentMarker = Marker(
      point: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
      width: 56,
      height: 56,
      // Optimización: usar const para widgets estáticos
      child: const _UserLocationMarkerWidget(),
    );

    setState(() {
      _markers = [currentMarker]; // Solo mostrar ubicación actual
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
    // IMPORTANTE: Detener TTS antes de habilitar el micrófono
    await TtsService.instance.stop();

    // Verificar permisos de micrófono
    var status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      _showPermissionDialog();
      TtsService.instance.speak('Permiso de micrófono denegado');
      return;
    }

    // ✅ Configurar timeout usando TimerManagerMixin
    cancelTimer('speechTimeout');
    createTimer(
      _speechTimeout,
      () {
      if (_isListening) {
        _speech.stop();
        _showWarningNotification('Tiempo de escucha agotado');
      }
    },
      name: 'speechTimeout',
    );

    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;

        // Procesar resultado final
        if (result.finalResult) {
          cancelTimer('speechTimeout'); // ✅ Usar TimerManagerMixin
          _processRecognizedText(result.recognizedWords);
        } else {
          // ✅ Debounce usando TimerManagerMixin
          _pendingWords = result.recognizedWords;
          cancelTimer('resultDebounce');
          createTimer(
            const Duration(milliseconds: 300),
            () {
            if (!mounted) return;
            setState(() {
              _lastWords = _pendingWords;
            });
          },
            name: 'resultDebounce',
          );
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
      });
      return;
    }

    final destination = _extractDestination(normalized);
    if (destination != null) {
      setState(() {
        _lastWords = command;
      });

      // CAP-9: Solicitar confirmación antes de buscar ruta
      _requestDestinationConfirmation(destination);
      return;
    }

    setState(() {
      _lastWords = command;
    });
    _announce('Comando "$command" aún no está soportado');
    TtsService.instance.speak('Ese comando no está disponible.');
  }

  bool _handleNavigationCommand(String command) {
    // ============================================================================
    // COMANDOS DE VOZ CONTEXTUALES
    // ============================================================================
    // Los comandos disponibles cambian según el estado de la navegación
    // ============================================================================

    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    final currentStep = activeNav?.currentStep;

    // CONFIRMACIÓN: Sí (después de "ir a X")
    if (command.contains('sí') || command.contains('si')) {
      if (_pendingConfirmationDestination != null) {
        _confirmDestination();
        return true;
      }
    }

    // CONFIRMACIÓN: No (cancelar "ir a X")
    if (command.contains('no')) {
      if (_pendingConfirmationDestination != null) {
        _cancelDestinationConfirmation();
        return true;
      }
    }

    // ✅ COMANDOS CONTEXTUALES SEGÚN ESTADO DE NAVEGACIÓN
    
    // SIN NAVEGACIÓN ACTIVA
    if (activeNav == null) {
      return _handleIdleCommands(command);
    }
    
    // CON NAVEGACIÓN ACTIVA - comandos según tipo de paso
    if (currentStep?.type == 'walk') {
      return _handleWalkCommands(command, currentStep, activeNav);
    } else if (currentStep?.type == 'wait_bus') {
      return _handleWaitBusCommands(command, currentStep);
    } else if (currentStep?.type == 'ride_bus') {
      return _handleRideBusCommands(command, currentStep);
    }

    return false;
  }
  
  /// ✅ NUEVO: Comandos cuando NO hay navegación activa
  bool _handleIdleCommands(String command) {
    // COMANDO: "Dónde estoy"
    if (command.contains('dónde') || command.contains('donde')) {
      _announceCurrentLocation();
      return true;
    }
    
    // COMANDO: "Qué hora es"
    if (command.contains('qué hora') || command.contains('que hora') || 
        command.contains('hora')) {
      _announceTime();
      return true;
    }
    
    // COMANDO: Cancelar (sin navegación activa)
    if (command.contains('cancelar')) {
      TtsService.instance.speak('No hay ruta activa');
      return true;
    }
    
    return false;
  }
  
  /// ✅ NUEVO: Comandos durante caminata
  bool _handleWalkCommands(String command, dynamic currentStep, dynamic activeNav) {
    // COMANDO: "Repetir" - repite la instrucción actual
    if (command.contains('repetir') || command.contains('repite')) {
      final instructions = currentStep.streetInstructions as List<String>?;
      if (instructions != null && instructions.isNotEmpty) {
        final currentIndex = _calculateCurrentInstructionIndexSilent(
          instructions: instructions,
          geometry: _getCurrentStepGeometryCached(),
        );
        TtsService.instance.speak(instructions[currentIndex], urgent: true);
      } else {
        TtsService.instance.speak('No hay instrucciones disponibles');
      }
      return true;
    }
    
    // COMANDO: "Siguiente" - anuncia la siguiente instrucción
    if (command.contains('siguiente') || command.contains('próxima')) {
      final instructions = currentStep.streetInstructions as List<String>?;
      if (instructions != null && instructions.isNotEmpty) {
        final currentIndex = _calculateCurrentInstructionIndexSilent(
          instructions: instructions,
          geometry: _getCurrentStepGeometryCached(),
        );
        if (currentIndex < instructions.length - 1) {
          TtsService.instance.speak(
            'Siguiente instrucción: ${instructions[currentIndex + 1]}',
            urgent: true,
          );
        } else {
          TtsService.instance.speak('Ya estás en la última instrucción');
        }
      }
      return true;
    }
    
    // COMANDO: "Cuánto falta" - distancia al destino
    if (command.contains('cuánto') || command.contains('cuanto') || 
        command.contains('falta')) {
      _announceDistanceRemaining();
      return true;
    }
    
    // COMANDO: "Más despacio" - reduce velocidad TTS
    if (command.contains('más despacio') || command.contains('mas despacio') ||
        command.contains('despacio')) {
      TtsService.instance.setRate(0.4);
      TtsService.instance.speak('Velocidad reducida');
      return true;
    }
    
    // COMANDO: "Más rápido" - aumenta velocidad TTS
    if (command.contains('más rápido') || command.contains('mas rapido') ||
        command.contains('rápido') || command.contains('rapido')) {
      TtsService.instance.setRate(0.6);
      TtsService.instance.speak('Velocidad aumentada');
      return true;
    }
    
    // COMANDO: "Velocidad normal" - reset velocidad TTS
    if (command.contains('normal')) {
      TtsService.instance.setRate(0.45);
      TtsService.instance.speak('Velocidad normal');
      return true;
    }
    
    // COMANDO: "Cancelar ruta"
    if (command.contains('cancelar')) {
      IntegratedNavigationService.instance.stopNavigation();
      setState(() {
        clearGeometryCache();
        _simulationPolylines.clear();
        _currentInstructions.clear();
        _showInstructionsPanel = false;
      });
      TtsService.instance.speak('Ruta cancelada', urgent: true);
      return true;
    }
    
    return false;
  }
  
  /// ✅ NUEVO: Comandos mientras espera el bus
  bool _handleWaitBusCommands(String command, dynamic currentStep) {
    // COMANDO: "Cuándo llega el bus"
    if (command.contains('cuándo') || command.contains('cuando') ||
        command.contains('llega')) {
      _announceBusArrival(currentStep);
      return true;
    }
    
    // COMANDO: "Qué buses pasan"
    if (command.contains('qué buses') || command.contains('que buses') ||
        command.contains('buses pasan')) {
      _announceAvailableBuses(currentStep);
      return true;
    }
    
    // COMANDO: "Cancelar ruta"
    if (command.contains('cancelar')) {
      // _stopBusArrivalMonitoring(); // Feature deshabilitada
      IntegratedNavigationService.instance.stopNavigation();
      setState(() {
        clearGeometryCache();
        _simulationPolylines.clear();
      });
      TtsService.instance.speak('Ruta cancelada', urgent: true);
      return true;
    }
    
    return false;
  }
  
  /// ✅ NUEVO: Comandos durante viaje en bus
  bool _handleRideBusCommands(String command, dynamic currentStep) {
    // COMANDO: "Cuánto falta"
    if (command.contains('cuánto') || command.contains('cuanto') ||
        command.contains('falta')) {
      final stopsRemaining = currentStep.totalStops ?? 0;
      final destination = currentStep.stopName ?? 'tu parada';
      TtsService.instance.speak(
        'Faltan $stopsRemaining paradas hasta $destination',
        urgent: true,
      );
      return true;
    }
    
    // COMANDO: "Próxima parada"
    if (command.contains('próxima') || command.contains('proxima') ||
        command.contains('siguiente')) {
      TtsService.instance.speak(
        'Manténte atento, te avisaré cuando estés cerca de tu parada',
        urgent: true,
      );
      return true;
    }
    
    return false;
  }
  
  /// Anuncia la ubicación actual del usuario
  void _announceCurrentLocation() {
    if (_currentPosition == null) {
      TtsService.instance.speak('No se puede obtener tu ubicación');
      return;
    }
    
    // En producción, esto debería hacer geocoding inverso
    TtsService.instance.speak(
      'Estás en las coordenadas: ${_currentPosition!.latitude.toStringAsFixed(4)}, '
      '${_currentPosition!.longitude.toStringAsFixed(4)}',
    );
  }
  
  /// Anuncia la hora actual
  void _announceTime() {
    final now = DateTime.now();
    final hour = now.hour;
    final minute = now.minute;
    final minuteText = minute < 10 ? 'cero $minute' : minute.toString();
    
    TtsService.instance.speak(
      'Son las $hour con $minuteText',
      urgent: true,
    );
  }
  
  /// Anuncia distancia restante al destino
  void _announceDistanceRemaining() {
    if (_currentPosition == null) {
      TtsService.instance.speak('No se puede calcular la distancia');
      return;
    }
    
    final geometry = _getCurrentStepGeometryCached();
    if (geometry.isEmpty) {
      TtsService.instance.speak('No hay ruta activa');
      return;
    }
    
    final destination = geometry.last;
    final distanceMeters = Geolocator.distanceBetween(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      destination.latitude,
      destination.longitude,
    );
    
    String distanceText;
    if (distanceMeters < 100) {
      distanceText = '${distanceMeters.round()} metros';
    } else if (distanceMeters < 1000) {
      distanceText = '${(distanceMeters / 10).round() * 10} metros';
    } else {
      distanceText = '${(distanceMeters / 1000).toStringAsFixed(1)} kilómetros';
    }
    
    TtsService.instance.speak('Faltan $distanceText', urgent: true);
  }
  
  /// Anuncia cuándo llega el bus
  Future<void> _announceBusArrival(dynamic currentStep) async {
    final stopCode = currentStep.stopId;
    final routeNumber = currentStep.busRoute;
    
    if (stopCode == null || routeNumber == null) {
      TtsService.instance.speak('No hay información del bus');
      return;
    }
    
    try {
      final arrivals = await BusArrivalsService.instance.getBusArrivals(stopCode);
      
      if (arrivals != null && arrivals.arrivals.isNotEmpty) {
        final targetBus = arrivals.arrivals.firstWhere(
          (bus) => bus.routeNumber == routeNumber,
          orElse: () => arrivals.arrivals.first,
        );
        
        TtsService.instance.speak(
          'El bus $routeNumber llegará en ${targetBus.formattedTime}',
          urgent: true,
        );
      } else {
        TtsService.instance.speak('No hay información de llegadas');
      }
    } catch (e) {
      TtsService.instance.speak('Error consultando llegadas del bus');
    }
  }
  
  /// Anuncia qué buses pasan por el paradero
  Future<void> _announceAvailableBuses(dynamic currentStep) async {
    final stopCode = currentStep.stopId;
    
    if (stopCode == null) {
      TtsService.instance.speak('No hay información del paradero');
      return;
    }
    
    try {
      final arrivals = await BusArrivalsService.instance.getBusArrivals(stopCode);
      
      if (arrivals != null && arrivals.arrivals.isNotEmpty) {
        final routes = arrivals.arrivals.map((a) => a.routeNumber).toSet().toList();
        final routesList = routes.join(', ');
        
        TtsService.instance.speak(
          'Por este paradero pasan los buses: $routesList',
          urgent: true,
        );
      } else {
        TtsService.instance.speak('No hay información de buses');
      }
    } catch (e) {
      TtsService.instance.speak('Error consultando información del paradero');
    }
  }

  String? _extractDestination(String command) {
    // PATRÓN SIMPLIFICADO: Solo "ir a [destino]"
    final pattern = r'ir\s+a(?:l)?\s+(.+)';

    final match = RegExp(pattern, caseSensitive: false).firstMatch(command);
    if (match != null) {
      final destination = match.group(1)?.trim();
      if (destination != null && destination.isNotEmpty) {
        // Limpiar palabras innecesarias
        String cleaned = destination
            .replaceAll(
              RegExp(
                r'\s+(por\s+favor|porfavor|gracias)$',
                caseSensitive: false,
              ),
              '',
            )
            .trim();

        if (cleaned.isNotEmpty) {
          return cleaned;
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

    // ✅ Usar TimerManagerMixin para timeout de confirmación
    cancelTimer('confirmation');
    createTimer(
      const Duration(seconds: 15),
      () {
      if (_pendingConfirmationDestination != null) {
        _cancelDestinationConfirmation();
      }
    },
      name: 'confirmation',
    );

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
    cancelTimer('confirmation'); // ✅ Usar TimerManagerMixin

    setState(() {
      _pendingConfirmationDestination = null;
    });

    _showSuccessNotification('Destino confirmado', withVibration: true);
    TtsService.instance.speak('Perfecto, buscando ruta a $destination');

    _searchRouteToDestination(destination);
  }

  /// CAP-9: Cancelar confirmación de destino
  void _cancelDestinationConfirmation() {
    cancelTimer('confirmation'); // ✅ Usar TimerManagerMixin

    setState(() {
      _pendingConfirmationDestination = null;
    });

    TtsService.instance.speak(
      'Destino cancelado. Puedes decir un nuevo destino cuando quieras.',
    );

    _showWarningNotification('Confirmación cancelada');
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

    final currentIndex = _currentInstructionStep;
    final instruction = _currentInstructions[currentIndex];
    _focusOnInstruction(currentIndex, speak: false);
    TtsService.instance.speak('Paso ${currentIndex + 1}: $instruction');
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
      _focusOnInstruction(step, speak: false);
      TtsService.instance.speak('Repitiendo paso ${step + 1}: $instruction');
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

      _messageHistory.add(notification.message);
      if (_messageHistory.length > 1) {
        _messageHistory.removeAt(0);
      }
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

  /// Actualiza el GPS simulado a una nueva ubicación SIN mover el mapa
  void _updateSimulatedGPS(LatLng targetLocation, {bool moveMap = false}) {
    _log('📍 [GPS SIMULADO] Actualizando posición a: ${targetLocation.latitude}, ${targetLocation.longitude}');
    
    // Crear una nueva Position simulada
    _currentPosition = Position(
      latitude: targetLocation.latitude,
      longitude: targetLocation.longitude,
      timestamp: DateTime.now(),
      accuracy: 10.0, // Precisión simulada de 10 metros
      altitude: 0.0,
      altitudeAccuracy: 0.0,
      heading: 0.0,
      headingAccuracy: 0.0,
      speed: 0.0,
      speedAccuracy: 0.0,
    );
    
    // CRÍTICO: Actualizar también el servicio de navegación para que use esta posición
    // Esto asegura que la geometría se recorte desde la posición simulada correcta
    IntegratedNavigationService.instance.updateSimulatedPosition(_currentPosition!);
    
    // ✅ FIX: Forzar reconstrucción completa del widget para actualizar instrucciones visuales
    // Esto asegura que _calculateCurrentInstructionIndex se llame en build() y actualice el layout
    if (mounted) {
      setState(() {
        _updateCurrentLocationMarker();
        // El setState fuerza la reconstrucción del widget, lo que ejecuta build()
        // y recalcula el índice de instrucción basado en la nueva posición GPS
      });
    }
    
    // NO AUTO-CENTRAR - moveMap siempre es false, el usuario tiene control total
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

  // Procesar texto reconocido por voz
  void _processRecognizedText(String recognizedText) {
    if (!mounted || _isProcessingCommand) return;

    setState(() {
      _isProcessingCommand = true;
    });

    // Agregar a historial
    _recognitionHistory.add(recognizedText);
    if (_recognitionHistory.length > 10) {
      _recognitionHistory.removeAt(0);
    }

    // Procesar comando
    bool commandProcessed = _processVoiceCommandEnhanced(recognizedText);

    // Intentar con texto normalizado si no se procesó
    if (!commandProcessed) {
      String normalizedText = _normalizeText(recognizedText);
      commandProcessed = _processVoiceCommandEnhanced(normalizedText);
    }

    if (commandProcessed) {
      _showSuccessNotification(
        'Comando ejecutado: "$recognizedText"',
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

  // Método simplificado para normalizar texto
  String _normalizeText(String text) {
    String normalized = text.toLowerCase().trim();

    // Remover acentos
    normalized = normalized
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('ñ', 'n');

    // Limpiar palabras innecesarias
    normalized = normalized
        .replaceAll(RegExp(r'\s+(por favor|porfavor|gracias)\s*'), ' ')
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
      });
      return true;
    }

    // 🚌 Comando para navegación integrada con Moovit (buses Red)
    if (normalized.contains('navegación red') ||
        normalized.contains('ruta red') ||
        normalized.contains('bus red')) {
      final destination = _extractDestination(command);
      if (destination != null && destination.isNotEmpty) {
        setState(() {
          _lastWords = command;
        });

        // Llamar a navegación integrada con Moovit en vez de ruta normal
        _onIntegratedNavigationVoiceCommand(command);
        return true;
      }
    }

    // Intentar extraer destino del comando original (sin normalizar demasiado)
    final destination = _extractDestination(command);
    if (destination != null && destination.isNotEmpty) {
      final pretty = _toTitleCase(destination);
      setState(() {
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
      TtsService.instance.speak(
        'No se puede calcular ruta sin ubicación actual',
      );
      return;
    }

    // Activar viaje pero NO mostrar paradas automaticamente
    // (solo mostrar la ruta del bus en el mapa)
    setState(() {
      _isCalculatingRoute = true; // 🔄 Mostrar indicador de carga
      // NO activar _showStops - solo mostrar la ruta del bus
    });

    // Anunciar que se está calculando
    TtsService.instance.speak(
      'Buscando mejor ruta hacia $destination. Por favor espera.',
    );

    try {
      // Geocodificar destino usando el servicio de validación de direcciones
      final suggestions = await AddressValidationService.instance
          .suggestAddresses(destination, limit: 1);

      if (suggestions.isEmpty) {
        setState(() => _isCalculatingRoute = false); // ❌ Ocultar indicador
        _showErrorNotification('No se encontró el destino: $destination');
        TtsService.instance.speak('No se encontró el destino $destination');
        return;
      }

      final firstResult = suggestions.first;
      final destLat = (firstResult['lat'] as num).toDouble();
      final destLon = (firstResult['lon'] as num).toDouble();

      // Iniciar navegación directamente usando IntegratedNavigationService
      await _startIntegratedMoovitNavigation(destination, destLat, destLon);
      
      setState(() => _isCalculatingRoute = false); // ✅ Ocultar indicador al finalizar
    } catch (e) {
      setState(() => _isCalculatingRoute = false); // ❌ Ocultar indicador en error
      _showErrorNotification('Error calculando ruta: ${e.toString()}');
      TtsService.instance.speak(
        'Error al calcular la ruta. Por favor intenta nuevamente.',
      );
    }
  }

  /// 🚌 NAVEGACIÓN INTEGRADA CON MOOVIT 🚌
  /// Inicia navegación completa usando scraping de Moovit + GTFS + GPS
  /// Inicia navegación integrada usando Moovit + IntegratedNavigationService
  /// Este método configura toda la navegación paso a paso con actualización
  /// automática del mapa según el progreso del usuario
  Future<void> _startIntegratedMoovitNavigation(
    String destination,
    double destLat,
    double destLon,
  ) async {
    if (_currentPosition == null) {
      _showErrorNotification('No se puede calcular ruta sin ubicación actual');
      TtsService.instance.speak('No se puede obtener tu ubicación actual');
      return;
    }

    try {
      // Anunciar inicio de búsqueda
      TtsService.instance.speak('Buscando ruta hacia $destination');

      // Iniciar navegación integrada
      // Este servicio maneja: scraping Moovit, construcción de pasos,
      // geometrías separadas por paso, y anuncios TTS
      _log('🗺️ [MAP] Antes de llamar startNavigation...');

      final navigation = await IntegratedNavigationService.instance
          .startNavigation(
            originLat: _currentPosition!.latitude,
            originLon: _currentPosition!.longitude,
            destLat: destLat,
            destLon: destLon,
            destinationName: destination,
          );

      _log('🗺️ [MAP] startNavigation completado exitosamente');
      _log('🗺️ [MAP] Navigation tiene ${navigation.steps.length} pasos');

      // ══════════════════════════════════════════════════════════════
      // CONFIGURAR CALLBACKS PARA ACTUALIZAR UI CUANDO CAMBIA EL PASO
      // ══════════════════════════════════════════════════════════════

      _log('🗺️ [MAP] Configurando callbacks...');

      IntegratedNavigationService.instance.onStepChanged = (step) async {
        if (!mounted) return;

        // ✅ Actualizar geometría usando el mixin centralizado
        final activeNav = IntegratedNavigationService.instance.activeNavigation;
        if (activeNav != null) {
          await updateNavigationGeometry(navigation: activeNav, forceRefresh: false);
          
          if (!mounted) return;
          
          setState(() {
            // Actualizar marcadores: solo paso actual + destino final
            _updateNavigationMarkers(step, activeNav);

            // Actualizar instrucciones: usar instrucciones detalladas de GraphHopper si están disponibles
            if (step.streetInstructions != null &&
                step.streetInstructions!.isNotEmpty) {
              _currentInstructions = [
                step.instruction, // Instrucción principal
                '', // Línea en blanco
                'Sigue estos pasos:', // Encabezado
                ...step.streetInstructions!, // Instrucciones detalladas por calle
              ];
              _currentInstructionStep = 0;
              _log(
                '📝 Instrucciones detalladas actualizadas: ${step.streetInstructions!.length} pasos',
              );
            } else {
              // Fallback: solo instrucción principal
              _currentInstructions = [step.instruction];
              _currentInstructionStep = 0;
            }
          });
        }

        // Anunciar nuevo paso y mostrar notificación
        _showNavigationNotification(step.instruction);
        _log('📍 Paso actual: ${step.instruction}');

        // Si hay instrucciones detalladas, anunciar la primera
        if (step.streetInstructions != null &&
            step.streetInstructions!.isNotEmpty) {
          _log('🗣️ Primera instrucción: ${step.streetInstructions!.first}');
        }
      };

      // Callback cuando llega a un paradero
      IntegratedNavigationService.instance.onArrivalAtStop = (stopId) {
        if (!mounted) return;
        _log('✅ Llegaste al paradero: $stopId');

        // Vibración de confirmación
        Vibration.vibrate(duration: 500);
        _showSuccessNotification(
          'Has llegado al paradero',
          withVibration: true,
        );
      };

      IntegratedNavigationService.instance.onDestinationReached = () {
        if (!mounted) return;
        _log('🎉 ¡Destino alcanzado!');

        _showSuccessNotification(
          '¡Felicitaciones! Has llegado a tu destino',
          withVibration: true,
        );

        Vibration.vibrate(duration: 1000);
      };

      // Callback cuando la geometría se actualiza (posición del usuario cambia)
      IntegratedNavigationService.instance.onGeometryUpdated = () {
        if (!mounted) return;

        setState(() {
          // ✅ La geometría ya se maneja en el mixin, solo actualizar posición y marcadores
          
          // Actualizar posición del usuario
          final position = IntegratedNavigationService.instance.lastPosition;
          if (position != null) {
            _currentPosition = position;

            // Actualizar marcadores sin cambiar el paso
            final activeNav =
                IntegratedNavigationService.instance.activeNavigation;
            if (activeNav != null && activeNav.currentStep != null) {
              _updateNavigationMarkers(activeNav.currentStep!, activeNav);
            }

            // NO AUTO-CENTRAR - el usuario tiene control total del mapa
          }
        });
      };

      // ===================================================================
      // CALLBACKS PARA TRACKING DE LLEGADAS EN TIEMPO REAL
      // ===================================================================
      IntegratedNavigationService.instance.onBusArrivalsUpdated = (arrivals) {
        if (!mounted) return;
        
        _log('🔄 [ARRIVALS] UI actualizada: ${arrivals.arrivals.length} buses');
      };

      IntegratedNavigationService.instance.onBusMissed = (routeNumber) async {
        if (!mounted) return;
        
        _log('🚨 [RECALCULAR] Bus $routeNumber pasó - iniciando recálculo de ruta');
        
        // ===================================================================
        // ALERTAS AL USUARIO - MEJORADAS
        // ===================================================================
        // 1. Vibración de alerta (patrón fuerte)
        await Vibration.vibrate(pattern: [0, 300, 100, 300, 100, 300]);
        
        // 2. Mensaje claro y humano
        await TtsService.instance.speak(
          'El bus $routeNumber ya pasó por el paradero. Voy a verificar qué buses te pueden llevar a tu destino.',
          urgent: true,
        );
        
        // 3. Notificación visual
        _showErrorNotification('🚌 Bus $routeNumber pasó - Buscando alternativas...');
        
        // ===================================================================
        // RECÁLCULO DE RUTA
        // ===================================================================
        // Detener navegación actual
        IntegratedNavigationService.instance.stopNavigation();
        
        // Obtener destino actual
        final activeNav = IntegratedNavigationService.instance.activeNavigation;
        if (activeNav != null && _currentPosition != null) {
          final destination = activeNav.itinerary.destination; // Ya es LatLng
          
          // Recalcular ruta desde posición actual al mismo destino
          _log('🔄 [RECALCULAR] Origen: ${_currentPosition!.latitude},${_currentPosition!.longitude}');
          _log('🔄 [RECALCULAR] Destino: ${destination.latitude},${destination.longitude}');
          
          // Delay para que el usuario escuche el mensaje completo
          await Future.delayed(const Duration(seconds: 3));
          
          // TTS: Indicar que está calculando
          await TtsService.instance.speak('Calculando nuevas opciones de ruta...', urgent: false);
          
          // Iniciar nueva navegación
          try {
            final newNav = await IntegratedNavigationService.instance.startNavigation(
              originLat: _currentPosition!.latitude,
              originLon: _currentPosition!.longitude,
              destLat: destination.latitude,
              destLon: destination.longitude,
              destinationName: 'Destino', // Nombre genérico para recalculación
            );
            
            setState(() {
              _updateNavigationMapState(newNav);
            });
            
            // Verificar si encontró una nueva ruta con bus
            final hasRedBus = newNav.itinerary.redBusRoutes.isNotEmpty;
            String confirmationMessage;
            
            if (hasRedBus) {
              final newBuses = newNav.itinerary.redBusRoutes.join(', ');
              confirmationMessage = 'Encontré una nueva ruta. Puedes tomar el bus $newBuses. Continúa siguiendo las instrucciones.';
            } else {
              confirmationMessage = 'Nueva ruta calculada. Continúa siguiendo las instrucciones.';
            }
            
            await TtsService.instance.speak(confirmationMessage);
            _showSuccessNotification('✅ Nueva ruta encontrada');
            
          } catch (e) {
            _log('❌ [RECALCULAR] Error: $e');
            
            // Mensaje de error más amigable
            await TtsService.instance.speak(
              'Lo siento, no pude encontrar una nueva ruta. Por favor, intenta buscar manualmente.',
              urgent: true,
            );
            
            _showErrorNotification('❌ No se encontró ruta alternativa');
          }
        }
      };

      // Dibujar mapa inicial con geometría del primer paso
      setState(() {
        _log('🗺️ [MAP] Llamando _updateNavigationMapState...');

        // Configurar polyline y marcadores iniciales
        _updateNavigationMapState(navigation);

        _log('🗺️ [MAP] Polylines después de actualizar: ${navigationPolylines.length}'); // ✅ Usar getter del mixin
        _log('🗺️ [MAP] Markers después de actualizar: ${_markers.length}');
      });

      _showSuccessNotification(
        'Navegación iniciada. Duración estimada: ${navigation.estimatedDuration} minutos',
        withVibration: true,
      );
    } catch (e) {
      _showErrorNotification('Error al calcular la ruta: $e');
      TtsService.instance.speak('Error al calcular la ruta. Intenta de nuevo.');
      _log('❌ Error en navegación integrada: $e');
    }
  }

  /// Actualiza el estado del mapa (polylines y marcadores) para la navegación activa
  /// ✅ REFACTORIZADO: Ahora usa NavigationGeometryMixin centralizado
  void _updateNavigationMapState(ActiveNavigation navigation) async {
    _log('🗺️ [MAP] Actualizando estado del mapa...');
    
    // ✅ Usar mixin centralizado para gestionar geometría
    await updateNavigationGeometry(
      navigation: navigation,
      forceRefresh: false,
    );

    // Actualizar marcadores
    _updateNavigationMarkers(navigation.currentStep, navigation);
    
    // Notificar cambio de estado
    if (mounted) {
      setState(() {
        // El mixin ya actualizó navigationPolylines
        _log('🗺️ [MAP] Estado actualizado: ${navigationPolylines.length} polilíneas');
      });
    }
    
    // NO AUTO-CENTRAR - el usuario tiene control total del mapa en todo momento
    // El centrado solo ocurre al cargar el mapa inicialmente
  }

  /// Calcula el índice de la instrucción actual basándose en la posición GPS del usuario
  /// Divide la geometría en segmentos y determina en cuál está el usuario
  int _calculateCurrentInstructionIndex({
    required List<String> instructions,
    required dynamic currentStep,
    required dynamic activeNav,
  }) {
    // Si no hay GPS, mostrar la primera instrucción
    if (_currentPosition == null) return 0;
    
    // Obtener geometría del paso actual
    final geometry = _getCurrentStepGeometryCached();
    if (geometry.isEmpty || geometry.length < 2) return 0;
    
    // Posición actual del usuario
    final userLat = _currentPosition!.latitude;
    final userLon = _currentPosition!.longitude;
    
    // Encontrar el punto más cercano en la geometría
    int closestPointIndex = 0;
    double minDistance = double.infinity;
    
    for (int i = 0; i < geometry.length; i++) {
      final distance = Geolocator.distanceBetween(
        userLat,
        userLon,
        geometry[i].latitude,
        geometry[i].longitude,
      );
      
      if (distance < minDistance) {
        minDistance = distance;
        closestPointIndex = i;
      }
    }
    
    // Calcular progreso: qué porcentaje de la ruta ha completado el usuario
    final progress = closestPointIndex / geometry.length;
    
    // Mapear el progreso al índice de instrucción
    // Si hay 5 instrucciones y el usuario va al 60% de la ruta, mostrar instrucción 3
    final instructionIndex = (progress * instructions.length).floor();
    
    // Asegurar que el índice esté dentro del rango válido
    final validIndex = instructionIndex.clamp(0, instructions.length - 1);
    
    // ✅ NUEVO: Anunciar automáticamente cuando cambia la instrucción
    if (validIndex != _lastAnnouncedInstructionIndex && 
        validIndex < instructions.length &&
        !_isSimulating) { // No anunciar durante simulación (tiene su propio sistema)
      
      _lastAnnouncedInstructionIndex = validIndex;
      
      // Vibración distintiva para cambio de instrucción
      SmartVibrationService.instance.vibrate(VibrationType.instructionChange);
      
      // Anunciar nueva instrucción con prioridad
      final instruction = instructions[validIndex];
      TtsService.instance.speak(
        instruction,
        urgent: true,
      );
      
      _log('🔊 [AUTO-ANNOUNCE] Nueva instrucción (${validIndex + 1}/${instructions.length}): $instruction');
    }
    
    return validIndex;
  }

  /// Determina el icono adecuado según el texto de la instrucción
  IconData _getInstructionIcon(String instruction) {
    final lowerInstruction = instruction.toLowerCase();
    
    // Detectar giros a la derecha
    if (lowerInstruction.contains('derecha') || 
        lowerInstruction.contains('gira a la derecha') ||
        lowerInstruction.contains('dobla a la derecha')) {
      return Icons.turn_right;
    }
    
    // Detectar giros a la izquierda
    if (lowerInstruction.contains('izquierda') || 
        lowerInstruction.contains('gira a la izquierda') ||
        lowerInstruction.contains('dobla a la izquierda')) {
      return Icons.turn_left;
    }
    
    // Detectar continuar recto
    if (lowerInstruction.contains('continúa') || 
        lowerInstruction.contains('sigue') ||
        lowerInstruction.contains('recto') ||
        lowerInstruction.contains('adelante')) {
      return Icons.straight;
    }
    
    // Detectar llegada/destino
    if (lowerInstruction.contains('llegaste') || 
        lowerInstruction.contains('destino') ||
        lowerInstruction.contains('has llegado')) {
      return Icons.place;
    }
    
    // Detectar inicio
    if (lowerInstruction.contains('dirígete') || 
        lowerInstruction.contains('sal') ||
        lowerInstruction.contains('comienza')) {
      return Icons.north;
    }
    
    // Default: caminar
    return Icons.directions_walk;
  }

  /// Obtiene la geometría del paso actual usando caché para optimización
  /// ✅ Aplica compresión Douglas-Peucker automáticamente
  List<LatLng> _getCurrentStepGeometryCached() {
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    if (activeNav == null) return [];
    
    final currentStepIndex = activeNav.currentStepIndex;
    
    // Usar caché si el índice no ha cambiado
    if (_cachedStepIndex == currentStepIndex && _cachedStepGeometry.isNotEmpty) {
      return _cachedStepGeometry;
    }
    
    // Obtener geometría del servicio
    var geometry = IntegratedNavigationService.instance.currentStepGeometry;
    
    // Compresión deshabilitada - usando geometría completa del backend
    // (polyline_compression.dart fue eliminado con geometry_cache_service.dart)
    
    // Actualizar caché con geometría completa
    _cachedStepGeometry = geometry;
    _cachedStepIndex = currentStepIndex;
    
    return _cachedStepGeometry;
  }

  /// Actualiza los marcadores del mapa durante la navegación
  /// Muestra: (1) marcador del paso actual, (2) bandera del destino final, (3) ubicación del usuario
  /// NOTA: Preserva marcadores de paradas de bus si existen
  void _updateNavigationMarkers(
    NavigationStep? currentStep,
    ActiveNavigation navigation,
  ) {
    final newMarkers = <Marker>[];

    // Marcador de la ubicación del usuario (solo la flecha de navegación)
    if (_currentPosition != null) {
      newMarkers.add(
        Marker(
          point: LatLng(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
          ),
          child: const Icon(
            Icons.navigation,
            color: Colors.blue,
            size: 32,
            shadows: [
              Shadow(
                color: Colors.black54,
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ),
      );
    }

    // ═══════════════════════════════════════════════════════════════
    // MOSTRAR PARADEROS DE BUS
    // - Durante WALK hacia el paradero: Mostrar solo el DESTINO (paradero de subida)
    // - Durante WAIT_BUS: Mostrar subida y bajada
    // - Durante RIDE_BUS: Mostrar todas las paradas
    // ═══════════════════════════════════════════════════════════════
    final shouldShowBusStops = currentStep?.type == 'walk' || currentStep?.type == 'wait_bus' || currentStep?.type == 'ride_bus';
    
    if (shouldShowBusStops) {
      _log('🔍 [MARKERS] Buscando leg de bus en itinerario...');
      try {
        final busLeg = navigation.itinerary.legs.firstWhere(
          (leg) => leg.type == 'bus' && leg.isRedBus,
          orElse: () => throw Exception('No bus leg found'),
        );

        _log('✅ [MARKERS] Leg de bus encontrado');

        final isWalking = currentStep?.type == 'walk';
        final isRidingBus = currentStep?.type == 'ride_bus';
        final isWaitingBus = currentStep?.type == 'wait_bus';
        _log('🚌 [MARKERS] Estado: walk=$isWalking, wait=$isWaitingBus, ride=$isRidingBus');

      // ═══════════════════════════════════════════════════════════════
      // DISEÑO ÚNICO DE PARADEROS - Simplificado y consistente
      // ═══════════════════════════════════════════════════════════════
      
      final stops = busLeg.stops;
      if (stops != null && stops.isNotEmpty) {
        _log('📍 [MARKERS] Procesando ${stops.length} paradas del bus');
        
        // Determinar qué paraderos mostrar según el estado
        final List<int> visibleStopIndices = [];
        
        if (isWalking) {
          // CAMINANDO: NO mostrar paraderos de la lista del bus
          // El marcador especial del paradero destino se muestra más abajo
          _log('🚶 [MARKERS] Modo CAMINATA: NO mostrar paraderos del busLeg');
        } else if (isWaitingBus) {
          // ESPERANDO: Mostrar solo el paradero de BAJADA
          // El paradero de subida (donde estás) se muestra con marcador especial más abajo
          if (stops.length > 1) {
            visibleStopIndices.add(stops.length - 1); // Solo bajada
          }
          _log('🚏 [MARKERS] Modo ESPERA: Mostrando solo paradero de bajada. El de origen se muestra abajo');
        } else if (isRidingBus) {
          // DURANTE el viaje: Mostrar todas las paradas
          for (int i = 0; i < stops.length; i++) {
            visibleStopIndices.add(i);
          }
          _log('🚌 [MARKERS] Modo VIAJE: Mostrando todas las paradas');
        }
        
        // Crear marcadores con diseño formal y empresarial
        for (final index in visibleStopIndices) {
          final stop = stops[index];
          final isCurrent = _isSimulating && index == _currentSimulatedBusStopIndex;
          
          newMarkers.add(
            Marker(
              point: stop.location,
              width: 120, // Reducido de 150
              height: 60, // Reducido de 80
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  // Nombre del paradero arriba
                  Positioned(
                    top: 0,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 110), // Reducido de 140
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), // Más compacto
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        stop.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9, // Reducido de 10
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                          height: 1.1,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  // Ícono del bus (más pequeño)
                  Positioned(
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.all(6), // Reducido de 8
                      decoration: BoxDecoration(
                        color: isCurrent ? const Color(0xFFEF6C00) : const Color(0xFFD84315),
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.directions_bus,
                        color: Colors.white,
                        size: isCurrent ? 20 : 18, // Reducido de 28/24
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
          
          _log('🚏 [MARKERS] Paradero ${index + 1}/${stops.length}: ${stop.name} ${isCurrent ? "(ACTUAL)" : ""}');
        }
        
        _log('🗺️ [MARKERS] Creados ${visibleStopIndices.length} marcadores de paradero');
      }
      } catch (e) {
        _log('⚠️ [MARKERS] No hay leg de bus en este itinerario: $e');
      }
    } else {
      _log('🚫 [MARKERS] No mostrar paraderos - paso actual: ${currentStep?.type}');
    }

    // ═══════════════════════════════════════════════════════════════
    // MARCADOR DE PARADERO DESTINO durante WALK
    // Mostrar el paradero destino con diseño naranja profesional
    // Usa el ÚLTIMO punto de la geometría walk (destino real)
    // ═══════════════════════════════════════════════════════════════
    if (currentStep?.type == 'walk' && currentStep?.location != null) {
      final nextStep = navigation.currentStepIndex < navigation.steps.length - 1
          ? navigation.steps[navigation.currentStepIndex + 1]
          : null;
      
      // Verificar si el siguiente paso es wait_bus (paradero)
      if (nextStep?.type == 'wait_bus' && nextStep?.stopName != null) {
        // Obtener el último punto de la geometría walk (destino exacto)
        final walkGeometry = _getCurrentStepGeometryCached();
        final paraderoLocation = walkGeometry.isNotEmpty 
            ? walkGeometry.last  // Usar último punto de la geometría
            : currentStep!.location!;  // Fallback a currentStep.location
        
        _log('🚏 [MARKERS] Mostrando paradero destino: ${nextStep!.stopName} en $paraderoLocation');
        
        newMarkers.add(
          Marker(
            point: paraderoLocation,
            width: 160,
            height: 100,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topCenter,
              children: [
                // Nombre del paradero arriba
                Positioned(
                  top: 0,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      nextStep.stopName!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        height: 1.2,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                // Pin de ubicación estilo Google Maps/RED (globo rojo)
                Positioned(
                  top: 35,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Globo del pin
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD84315), // Rojo corporativo RED
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.directions_bus_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                      // Punta del pin (triángulo hacia abajo)
                      CustomPaint(
                        size: const Size(12, 8),
                        painter: _PinTipPainter(color: const Color(0xFFD84315)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        _log('🚫 [MARKERS] Siguiente paso no es wait_bus: ${nextStep?.type}');
      }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARCADOR DE PARADERO DE ORIGEN durante WAIT_BUS
    // Mostrar el paradero donde estás esperando el bus
    // Usa la ubicación actual (currentStep.location) o posición GPS
    // ═══════════════════════════════════════════════════════════════
    if (currentStep?.type == 'wait_bus' && currentStep?.stopName != null) {
      // Usar la ubicación del paso wait_bus o la posición GPS actual
      final paraderoLocation = currentStep!.location ?? 
          (_currentPosition != null 
              ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
              : null);
      
      if (paraderoLocation != null) {
        _log('🚏 [MARKERS] Mostrando paradero de ORIGEN (wait_bus): ${currentStep.stopName} en $paraderoLocation');
        
        newMarkers.add(
          Marker(
            point: paraderoLocation,
            width: 160,
            height: 100,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topCenter,
              children: [
                // Nombre del paradero arriba
                Positioned(
                  top: 0,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      currentStep.stopName!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        height: 1.2,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                // Pin de ubicación estilo Google Maps/RED (globo rojo)
                Positioned(
                  top: 35,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Globo del pin con animación de pulso
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE30613), // Rojo RED más brillante
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFE30613).withValues(alpha: 0.4),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.directions_bus_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      // Punta del pin (triángulo hacia abajo)
                      CustomPaint(
                        size: const Size(12, 8),
                        painter: _PinTipPainter(color: const Color(0xFFE30613)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARCADOR DEL DESTINO FINAL
    // Solo mostrar cuando estemos en el ÚLTIMO paso de la navegación
    // ═══════════════════════════════════════════════════════════════
    final isLastStep = navigation.currentStepIndex >= navigation.steps.length - 1;
    if (isLastStep) {
      final lastStep = navigation.steps.last;
      if (lastStep.location != null) {
        _log('🏁 [MARKERS] ÚLTIMO PASO - Mostrando destino final en ${lastStep.location}');
        newMarkers.add(
          Marker(
            point: lastStep.location!,
            width: 150,
            height: 80,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                // Etiqueta "Destino"
                Positioned(
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'Destino',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
                // Pin de ubicación (flat design)
                Positioned(
                  bottom: 10,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E7D32), // Verde corporativo
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.location_on,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    } else {
      _log('🚫 [MARKERS] NO es el último paso - Destino final NO visible');
    }

    // Actualizar marcadores
    _log('🗺️ [MARKERS] ═══════════════════════════════════════════════════════');
    _log('🗺️ [MARKERS] TOTAL DE MARCADORES CREADOS: ${newMarkers.length}');
    _log('🗺️ [MARKERS] Paso actual: ${currentStep?.type} (${navigation.currentStepIndex + 1}/${navigation.steps.length})');
    _log('🗺️ [MARKERS] Es último paso: $isLastStep');
    _log('🗺️ [MARKERS] ═══════════════════════════════════════════════════════');
    _markers = newMarkers;
  }

  /// Retorna el icono y color apropiado para cada tipo de paso
  /// Comando de voz para controlar navegación integrada
  void _onIntegratedNavigationVoiceCommand(String command) async {
    final normalized = command.toLowerCase();

    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    final currentStep = activeNav?.currentStep;

    // ═══════════════════════════════════════════════════════════════
    // NUEVOS COMANDOS ESPECÍFICOS PARA NAVEGACIÓN EN BUS
    // ═══════════════════════════════════════════════════════════════
    
    // "¿A qué hora llega el bus?" - Durante wait_bus
    if ((normalized.contains('a qué hora llega') ||
         normalized.contains('cuándo llega') ||
         normalized.contains('qué hora llega el bus')) &&
        currentStep?.type == 'wait_bus') {
      
      final busRoute = currentStep?.busRoute ?? 'el bus';
      
      // Intentar obtener ETA desde BusArrivalsService
      final arrivals = BusArrivalsService.instance.lastArrivals;
      
      if (arrivals != null && arrivals.arrivals.isNotEmpty) {
        final firstArrival = arrivals.arrivals.first;
        final minutes = firstArrival.estimatedMinutes;
        
        String response;
        if (minutes <= 1) {
          response = 'El bus $busRoute está llegando ahora';
        } else if (minutes <= 3) {
          response = 'El bus $busRoute llega en $minutes minutos. Prepárate';
        } else {
          response = 'El bus $busRoute llegaría en aproximadamente $minutes minutos';
        }
        
        await TtsService.instance.speak(response, urgent: true);
        _showSuccessNotification(response);
      } else {
        await TtsService.instance.speak(
          'No tengo información de llegada del bus $busRoute en este momento',
          urgent: true
        );
      }
      return;
    }

    // "¿Cuántas paradas faltan?" - Durante ride_bus
    if ((normalized.contains('cuántas paradas') ||
         normalized.contains('cuántas faltan') ||
         normalized.contains('paradas restantes') ||
         normalized.contains('paradas quedan')) &&
        currentStep?.type == 'ride_bus') {
      
      final totalStops = currentStep?.totalStops ?? 0;
      final currentStopIndex = _currentSimulatedBusStopIndex >= 0 ? _currentSimulatedBusStopIndex : 0;
      final remainingStops = totalStops > currentStopIndex ? totalStops - currentStopIndex : 0;
      
      String response;
      if (remainingStops == 0) {
        response = 'Estás llegando a tu parada de destino';
      } else if (remainingStops == 1) {
        response = 'Falta 1 parada para llegar a tu destino';
      } else {
        response = 'Faltan $remainingStops paradas para llegar a tu destino';
      }
      
      await TtsService.instance.speak(response, urgent: true);
      _showSuccessNotification('Paradas restantes: $remainingStops');
      return;
    }

    // "¿Dónde estoy?" - Mejorado para incluir info de bus
    if (normalized.contains('dónde estoy') ||
        normalized.contains('dónde me encuentro') ||
        normalized.contains('ubicación actual') ||
        normalized.contains('en qué ruta') ||
        normalized.contains('qué bus')) {
      
      String response = '';
      
      if (currentStep?.type == 'wait_bus') {
        final busRoute = currentStep?.busRoute ?? '';
        final stopName = currentStep?.stopName ?? 'el paradero';
        response = 'Estás esperando el bus $busRoute en $stopName';
      } else if (currentStep?.type == 'ride_bus') {
        final busRoute = currentStep?.busRoute ?? '';
        final stopName = currentStep?.stopName ?? 'tu destino';
        final currentStopIndex = _currentSimulatedBusStopIndex >= 0 ? _currentSimulatedBusStopIndex : 0;
        final totalStops = currentStep?.totalStops ?? 0;
        final remainingStops = totalStops > currentStopIndex ? totalStops - currentStopIndex : 0;
        
        response = 'Estás viajando en el bus $busRoute hacia $stopName. Faltan $remainingStops paradas';
      } else if (currentStep?.type == 'walk') {
        response = 'Estás caminando. ${currentStep?.instruction ?? "Sigue las instrucciones de voz"}';
      } else if (activeNav != null) {
        response = 'Estás en navegación activa. ${currentStep?.instruction ?? ""}';
      } else {
        response = 'No hay navegación activa en este momento';
      }
      
      await TtsService.instance.speak(response, urgent: true);
      _showSuccessNotification(response);
      return;
    }

    // Comandos para leer instrucciones (originales)
    if (normalized.contains('todas las instrucciones') ||
        normalized.contains('resumen de ruta') ||
        normalized.contains('leer ruta completa')) {
      _readAllInstructions();
      return;
    }

    if (normalized.contains('siguiente paso') ||
        normalized.contains('próximo paso') ||
        normalized.contains('siguiente instrucción')) {
      _readNextInstruction();
      return;
    }

    if (normalized.contains('repetir') ||
        normalized.contains('otra vez') ||
        normalized.contains('qué debo hacer')) {
      _repeatCurrentInstruction();
      return;
    }

    // Comando para ocultar/mostrar panel visual (para acompañantes)
    if (normalized.contains('mostrar instrucciones') ||
        normalized.contains('ver instrucciones')) {
      setState(() {
        _showInstructionsPanel = true;
        _autoReadInstructions = false;
      });
      TtsService.instance.speak('Mostrando panel de instrucciones');
      return;
    }

    if (normalized.contains('ocultar instrucciones') ||
        normalized.contains('cerrar panel')) {
      setState(() {
        _showInstructionsPanel = false;
        _autoReadInstructions = true;
      });
      TtsService.instance.speak('Panel ocultado, usando modo audio');
      return;
    }

    if (normalized.contains('cancelar navegación') ||
        normalized.contains('detener navegación')) {
      IntegratedNavigationService.instance.cancelNavigation();
      clearGeometryCache(); // ✅ Limpiar caché del mixin
      setState(() {
        _markers.clear();
        _currentInstructions.clear();
        _showInstructionsPanel = false;
      });
      _showWarningNotification('Navegación cancelada');
      TtsService.instance.speak('Navegación cancelada');
      return;
    }

    // Si no es un comando de control, buscar destino y comenzar navegación
    final destination = _extractDestination(command);
    if (destination != null && destination.isNotEmpty) {
      // Buscar dirección usando el servicio de validación
      try {
        final suggestions = await AddressValidationService.instance
            .suggestAddresses(destination, limit: 1);

        if (suggestions.isEmpty) {
          _showWarningNotification('No se encontró la dirección: $destination');
          TtsService.instance.speak('No se encontró la dirección $destination');
          return;
        }

        final selected = suggestions.first;
        final destLat = (selected['lat'] as num).toDouble();
        final destLon = (selected['lon'] as num).toDouble();
        final selectedName = selected['display_name'] as String;

        // Iniciar navegación integrada con Moovit
        await _startIntegratedMoovitNavigation(selectedName, destLat, destLon);
      } catch (e) {
        _showErrorNotification('Error buscando dirección: $e');
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // MÉTODOS LEGACY ELIMINADOS
  // ═══════════════════════════════════════════════════════════════
  // ❌ _calculateRoute() - Obsoleto, ahora se usa IntegratedNavigationService
  // ❌ _displayRoute() - Obsoleto, todo viene de IntegratedNavigationService
  // ❌ _displayFallbackRoute() - Obsoleto, no se usa ruta de demostración

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

  void _showWalkingInstructions() {
    if (_currentInstructions.isEmpty) {
      TtsService.instance.speak('No hay instrucciones de caminata disponibles');
      return;
    }

    // Para usuarios no videntes: leer resumen en lugar de mostrar panel
    if (_autoReadInstructions) {
      _readAllInstructions();
    } else {
      // Solo para acompañantes videntes
      setState(() {
        _showInstructionsPanel = !_showInstructionsPanel;
      });

      if (_showInstructionsPanel) {
        TtsService.instance.speak(
          'Mostrando ${_currentInstructions.length} instrucciones de caminata',
        );
      } else {
        TtsService.instance.speak('Ocultando instrucciones');
      }
    }
  }

  void _readAllInstructions() {
    final total = _currentInstructions.length;
    TtsService.instance.speak(
      'Tienes $total pasos en tu ruta. Voy a leerlos.',
      urgent: true,
    );

    Future.delayed(const Duration(seconds: 2), () {
      for (int i = 0; i < _currentInstructions.length; i++) {
        Future.delayed(Duration(seconds: i * 4), () {
          TtsService.instance.speak(
            'Paso ${i + 1} de $total: ${_currentInstructions[i]}',
            urgent: false,
          );
        });
      }
    });
  }

  Widget _buildMicrophoneContent() {
    // UI SIMPLIFICADA: Solo mostrar estado del micrófono y brújula
    if (_isCalculatingRoute) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Animación de carga mejorada
          SizedBox(
            width: 40,
            height: 40,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.5,
                ),
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.route,
                    color: Colors.white,
                    size: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Procesando ruta...',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Lado izquierdo: Brújula
        if (_currentPosition?.heading != null)
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Transform.rotate(
                  angle: _currentPosition!.heading * 3.14159 / 180,
                  child: const Icon(
                    Icons.navigation,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${_currentPosition!.heading.toStringAsFixed(0)}°',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          )
        else
          const Expanded(child: SizedBox.shrink()),

        // Centro: Ícono del micrófono (grande y claro)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Icon(
            _isListening ? Icons.mic : Icons.mic_none,
            color: Colors.white,
            size: 40,
          ),
        ),

        // Lado derecho: Espacio para futura información
        const Expanded(child: SizedBox.shrink()),
      ],
    );
  }

  @override
  void dispose() {
    // ✅ TimerManagerMixin limpia automáticamente: feedback, confirmation, speechTimeout, walkSimulation, resultDebounce

    unawaited(TtsService.instance.releaseContext('map_navigation'));
    
    // Feature de monitoreo de bus deshabilitada
    // _stopBusArrivalMonitoring();

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
      backgroundColor: const Color(0xFFF5F6FF),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final double overlayBase = math.max(
            _overlayBaseOffset(context, min: 260),
            constraints.maxHeight * 0.26,
          );
          final double gap = _overlayGap(context);
          final double floatingSecondary = overlayBase + gap * 1.15;

          return Stack(
            children: [
              // Área del mapa con esquinas suavizadas
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(32),
                  ),
                  child: FlutterMap(
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
                      initialRotation: 0.0,
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
                      // onPositionChanged eliminado - el mapa siempre sigue al usuario
                      keepAlive: true,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.wayfindcl',
                        maxZoom: 18,
                        maxNativeZoom: 18,
                        retinaMode: false,
                        // Optimizaciones de rendimiento
                        tileDimension: 256,
                        panBuffer: 1, // Reduce tiles cargados fuera de pantalla
                      ),
                      // ✅ PRIORIDAD: Durante simulación, SOLO mostrar _simulationPolylines
                      // Esto evita conflictos entre navegación real y simulación de debug
                      if (_isSimulating && _simulationPolylines.isNotEmpty)
                        PolylineLayer(polylines: _simulationPolylines)
                      else if (!_isSimulating && navigationPolylines.isNotEmpty) 
                        PolylineLayer(polylines: navigationPolylines),
                      if (_markers.isNotEmpty) MarkerLayer(markers: _markers),
                    ],
                  ),
                ),
              ),

              // Encabezado con título e indicador IA
              Positioned(
                top: MediaQuery.of(context).padding.top + 12,
                left: 16,
                right: 16,
                child: Center(child: _buildHeaderChips(context)),
              ),

              // Botón de configuración (derecha)
              Positioned(
                right: 20,
                bottom: floatingSecondary,
                child: GestureDetector(
                  onTap: () => Navigator.pushNamed(context, '/settings'),
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF111827), Color(0xFF1F2937)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0F172A).withValues(alpha: 0.4),
                          blurRadius: 18,
                          offset: const Offset(0, 10),
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

              // Panel inferior modernizado
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildBottomPanel(context),
              ),

              // Sistema de notificaciones
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: _activeNotifications.map((notification) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 480),
                            child: AccessibleNotification(
                              key: ValueKey(notification.hashCode),
                              notification: notification,
                              onDismiss: () =>
                                  _dismissNotification(notification),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeaderChips(BuildContext context) {
    final bool loading = _npuLoading && !_npuChecked;
    final bool available = _npuAvailable;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Logo Red Movilidad (32x32)
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/icons.png',
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  // Fallback si no existe la imagen
                  return const Icon(
                    Icons.directions_bus,
                    color: Color(0xFFE30613),
                    size: 18,
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'WayFindCL',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(width: 12),
          _buildIaBadge(loading: loading, available: available),
        ],
      ),
    );
  }

  Widget _buildIaBadge({required bool loading, required bool available}) {
    final List<Color> colors;
    final String label;
    if (loading) {
      colors = [const Color(0xFFE2E8F0), const Color(0xFFCBD5F5)];
      label = 'IA';
    } else if (available) {
      colors = [const Color(0xFF00BCD4), const Color(0xFF0097A7)];
      label = 'IA';
    } else {
      colors = [const Color(0xFFE53935), const Color(0xFFD32F2F)];
      label = 'IA OFF';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: colors.last.withValues(alpha: 0.35),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            const SizedBox(width: 6),
          ] else ...[
            const Icon(Icons.bolt, size: 16, color: Colors.white),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomPanel(BuildContext context) {
    final bool isListening = _isListening;
    final bool isCalculating = _isCalculatingRoute;
    final activeNav = IntegratedNavigationService.instance.activeNavigation;
    
    // Mantener navegación activa visible incluso si isComplete == true
    // Esto permite que el usuario vea la ruta después de llegar al destino
    // y pueda iniciar una nueva navegación desde allí
    final bool hasActiveNav = activeNav != null;

    // INTERFAZ MINIMAL durante navegación activa
    if (hasActiveNav && !isCalculating) {
      return _buildMinimalNavigationPanel(context, isListening, activeNav);
    }

    // INTERFAZ COMPLETA cuando NO hay navegación
    return _buildFullBottomPanel(context, isListening, isCalculating);
  }

  /// Interfaz minimal durante navegación: solo micrófono + info de ruta
  Widget _buildMinimalNavigationPanel(BuildContext context, bool isListening, dynamic activeNav) {
    final currentStep = activeNav.currentStep;
    
    // PANEL para WALK: Mostrar instrucciones de calle
    if (currentStep?.type == 'walk' && 
        currentStep.streetInstructions != null &&
        currentStep.streetInstructions!.isNotEmpty) {
      
      final instructions = currentStep.streetInstructions!;
      
      // ✅ CRÍTICO: Calcular qué instrucción mostrar según posición GPS actual
      final currentInstructionIndex = _calculateCurrentInstructionIndex(
        instructions: instructions,
        currentStep: currentStep,
        activeNav: activeNav,
      );
      
      final currentInstruction = instructions[currentInstructionIndex];
      final progress = '${currentInstructionIndex + 1}/${instructions.length}';
      
      // ✅ Calcular distancia restante al destino del paso actual
      String distanceInfo = '';
      if (_currentPosition != null) {
        final geometry = _getCurrentStepGeometryCached();
        if (geometry.isNotEmpty) {
          final destination = geometry.last;
          final distanceMeters = Geolocator.distanceBetween(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
            destination.latitude,
            destination.longitude,
          );
          
          if (distanceMeters < 1000) {
            distanceInfo = '${distanceMeters.round()}m';
          } else {
            distanceInfo = '${(distanceMeters / 1000).toStringAsFixed(1)}km';
          }
        }
      }
      
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Panel de instrucción de calle
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFF8C42), Color(0xFFFF6B2C)],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFF8C42).withValues(alpha: 0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Fila superior: Icono + Título + Progreso
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.directions_walk,
                            color: Color(0xFFFF8C42),
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Caminando',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        // ✅ Mostrar progreso de instrucciones
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            progress,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Instrucción principal
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              // ✅ Icono dinámico según la instrucción
                              Icon(
                                _getInstructionIcon(currentInstruction),
                                color: Colors.white,
                                size: 28,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  currentInstruction,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          // ✅ Mostrar distancia restante si está disponible
                          if (distanceInfo.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                const Icon(
                                  Icons.location_on,
                                  color: Colors.white70,
                                  size: 18,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Faltan $distanceInfo al destino',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Fila de botones: Micrófono (principal) + Simular (desarrollo)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Botón de MICRÓFONO (PRINCIPAL - para usuarios)
                  GestureDetector(
                    onTap: isListening ? _stopListening : _startListening,
                    child: Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isListening ? const Color(0xFFFF8C42) : const Color(0xFF0F172A),
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 12,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Icon(
                        isListening ? Icons.mic : Icons.mic_none,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Botón SIMULAR pequeño (DESARROLLO)
                  GestureDetector(
                    onTap: _simulateArrivalAtStop,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF64748B).withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFF64748B),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.bug_report,
                            color: Color(0xFF94A3B8),
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Simular',
                            style: TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    
    // PANEL ESPECIAL para wait_bus: Mostrar información del bus esperado
    if (currentStep?.type == 'wait_bus') {
      final busRoute = currentStep.busRoute ?? '';
      final stopName = currentStep.stopName ?? 'Destino';
      
      // Obtener información de paradas del siguiente paso (ride_bus)
      int totalStops = 0;
      int remainingStops = 0;
      String destination = stopName;
      
      // Buscar el siguiente paso ride_bus para obtener destino y paradas
      final activeNav = IntegratedNavigationService.instance.activeNavigation;
      if (activeNav != null && activeNav.currentStepIndex < activeNav.steps.length - 1) {
        final nextStep = activeNav.steps[activeNav.currentStepIndex + 1];
        if (nextStep.type == 'ride_bus') {
          totalStops = nextStep.totalStops ?? 0;
          remainingStops = totalStops; // Al inicio, todas las paradas faltan
          destination = nextStep.stopName ?? stopName;
        }
      }
      
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Panel principal del bus con información
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFE30613), Color(0xFFB71C1C)],
                  ),
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFE30613).withValues(alpha: 0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // Fila superior: Número del bus y destino
                    Row(
                      children: [
                        // Icono y número del bus
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.directions_bus,
                                color: Color(0xFFE30613),
                                size: 24,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                busRoute,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Destino
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Hacia',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                destination,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Fila inferior: Progreso de paradas
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          // Parada inicial
                          Column(
                            children: [
                              const Text(
                                'Parada',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                '1',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                          // Separador
                          Container(
                            width: 1,
                            height: 30,
                            color: Colors.white30,
                          ),
                          // Total de paradas
                          Column(
                            children: [
                              const Text(
                                'Total',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$totalStops',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                          // Separador
                          Container(
                            width: 1,
                            height: 30,
                            color: Colors.white30,
                          ),
                          // Paradas restantes (todas al inicio)
                          Column(
                            children: [
                              const Text(
                                'Faltan',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$remainingStops',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Fila de botones: Micrófono (principal) + Simular (desarrollo, pequeño)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Botón de MICRÓFONO (PRINCIPAL - para usuarios)
                  GestureDetector(
                    onTap: isListening ? _stopListening : _startListening,
                    child: Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isListening ? const Color(0xFFEF4444) : const Color(0xFF0F172A),
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 12,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Icon(
                        isListening ? Icons.mic : Icons.mic_none,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Botón SIMULAR pequeño (DESARROLLO)
                  GestureDetector(
                    onTap: _simulateArrivalAtStop,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF64748B).withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFF64748B),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.bug_report,
                            color: Color(0xFF94A3B8),
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Simular',
                            style: TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    
    // PANEL ESPECIAL para ride_bus: Muestra progreso del viaje en bus
    if (currentStep?.type == 'ride_bus') {
      // Obtener información del bus
      final busRoute = currentStep.busRoute ?? '';
      final destinationName = currentStep.stopName ?? 'Destino';
      
      // ✅ USAR directamente las paradas del NavigationStep (ya vienen recortadas)
      final busStopsData = currentStep.busStops ?? [];
      final totalStops = busStopsData.length;
      
      // ✅ Obtener índice actual del servicio (ya está actualizado por GPS)
      int currentStopIndex;
      if (_isSimulating) {
        // En simulación: necesitamos calcular índice relativo
        final busLeg = activeNav.itinerary.legs.firstWhere(
          (leg) => leg.type == 'bus' && leg.isRedBus,
          orElse: () => throw Exception('No bus leg found'),
        );
        
        // Buscar origen en la lista global para calcular offset
        int globalOriginIndex = 0;
        if (activeNav.currentStepIndex > 0) {
          final previousStep = activeNav.steps[activeNav.currentStepIndex - 1];
          if (previousStep.type == 'wait_bus' && previousStep.location != null && busLeg.stops != null) {
            final allStops = busLeg.stops!;
            double minDistance = double.infinity;
            for (int i = 0; i < allStops.length; i++) {
              final distance = Geolocator.distanceBetween(
                previousStep.location!.latitude,
                previousStep.location!.longitude,
                allStops[i].location.latitude,
                allStops[i].location.longitude,
              );
              if (distance < minDistance) {
                minDistance = distance;
                globalOriginIndex = i;
              }
            }
          }
        }
        currentStopIndex = (_currentSimulatedBusStopIndex - globalOriginIndex).clamp(0, totalStops - 1) as int;
      } else {
        // GPS real: usar el índice del servicio directamente
        currentStopIndex = IntegratedNavigationService.instance.currentBusStopIndex;
        if (totalStops > 0) {
          currentStopIndex = currentStopIndex.clamp(0, totalStops - 1) as int;
        }
      }
      
      final remainingStops = totalStops > currentStopIndex ? totalStops - currentStopIndex - 1 : 0;
      
      // Obtener nombres de paradas
      final currentStopName = currentStopIndex < busStopsData.length
          ? busStopsData[currentStopIndex]['name'] as String
          : 'En tránsito';
      final nextStopName = (currentStopIndex + 1) < busStopsData.length
          ? busStopsData[currentStopIndex + 1]['name'] as String
          : 'Destino final';
      
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Panel principal del bus con información
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFE30613), Color(0xFFB71C1C)],
                  ),
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFE30613).withValues(alpha: 0.3),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // Fila superior: Número del bus y destino
                    Row(
                      children: [
                        // Icono y número del bus
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.directions_bus,
                                color: Color(0xFFE30613),
                                size: 24,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                busRoute,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Destino del bus
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Hacia',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                destinationName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Fila inferior: Progreso de paradas
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          // Parada actual
                          Column(
                            children: [
                              const Text(
                                'Parada',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${currentStopIndex + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                          // Separador
                          Container(
                            width: 1,
                            height: 30,
                            color: Colors.white30,
                          ),
                          // Total de paradas
                          Column(
                            children: [
                              const Text(
                                'Total',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$totalStops',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                          // Separador
                          Container(
                            width: 1,
                            height: 30,
                            color: Colors.white30,
                          ),
                          // Paradas restantes
                          Column(
                            children: [
                              const Text(
                                'Faltan',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$remainingStops',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Panel con información de paradas actual y próxima
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Parada actual
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Parada actual',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    Text(
                                      currentStopName,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Próxima parada
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Próxima parada',
                                      style: TextStyle(
                                        color: Colors.white60,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    Text(
                                      nextStopName,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Botón de micrófono flotante
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: isListening ? _stopListening : _startListening,
                    child: Container(
                      width: 70,
                      height: 70,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isListening ? const Color(0xFFEF4444) : const Color(0xFF0F172A),
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 15,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Icon(
                        isListening ? Icons.mic : Icons.mic_none,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Botón de simulación (discreto)
                  TextButton.icon(
                    onPressed: _simulateArrivalAtStop,
                    icon: const Icon(Icons.bug_report, size: 16),
                    label: Text(
                      _getSimulationButtonLabel(),
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF64748B),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    
    // PANEL NORMAL para otros casos
    // Calcular tiempo y distancia de forma segura
    final int durationMin = activeNav.estimatedDuration; // Ya está en minutos
    double distanceKm = 0.0;
    for (var leg in activeNav.itinerary.legs) {
      distanceKm += leg.distanceKm;
    }
    
    // Determinar el tipo de actividad actual (walk o bus)
    final isWalking = currentStep?.type == 'walk';
    final isBusRelated = currentStep?.type == 'wait_bus' || currentStep?.type == 'ride_bus';

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), // Panel cerca del borde inferior
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Panel minimal con micrófono
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Lado izquierdo: Tiempo con ícono contextual
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          isWalking ? Icons.directions_walk : isBusRelated ? Icons.directions_bus : Icons.access_time,
                          size: 20,
                          color: const Color(0xFF64748B),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${durationMin}min',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Centro: Botón de micrófono
                  GestureDetector(
                    onTap: isListening ? _stopListening : _startListening,
                    child: Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isListening ? const Color(0xFFEF4444) : const Color(0xFF0F172A),
                          width: 3,
                        ),
                      ),
                      child: Icon(
                        isListening ? Icons.mic : Icons.mic_none,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                  // Lado derecho: Distancia
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.straighten, size: 18, color: Color(0xFF64748B)),
                        const SizedBox(width: 6),
                        Text(
                          '${distanceKm.toStringAsFixed(1)}km',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // Botón debug para desarrolladores (discreto)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _simulateArrivalAtStop,
                icon: const Icon(Icons.bug_report, size: 16),
                label: const Text(
                  'Simular',
                  style: TextStyle(fontSize: 12),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF64748B),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Interfaz completa cuando NO hay navegación activa
  Widget _buildFullBottomPanel(BuildContext context, bool isListening, bool isCalculating) {
    final List<Color> micGradient = isCalculating
        ? const [Color(0xFF2563EB), Color(0xFF1D4ED8)]
        : isListening
        ? const [Color(0xFFE53935), Color(0xFFB71C1C)]
        : const [Color(0xFF111827), Color(0xFF1F2937)];

    final Color micShadowColor = isCalculating
        ? const Color(0xFF1D4ED8)
        : isListening
        ? const Color(0xFFB71C1C)
        : Colors.black;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Colors.white, Color(0xFFF2F4F8)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_isProcessingCommand)
                      const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Procesando comando...',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFF2563EB),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 18),
                    Semantics(
                      label: isListening
                          ? 'Botón micrófono, escuchando'
                          : 'Botón micrófono, no escuchando',
                      hint: isListening
                          ? 'Toca para detener'
                          : 'Toca para iniciar',
                      button: true,
                      enabled: true,
                      child: GestureDetector(
                        onTap: _toggleMicrophone,
                        onLongPress: _showWalkingInstructions,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeInOut,
                          width: double.infinity,
                          height: 85,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: micGradient,
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: micShadowColor.withValues(alpha: 0.25),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: _buildMicrophoneContent(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
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
                              const SnackBar(
                                content: Text('Guardados (no implementado)'),
                              ),
                            );
                            break;
                          // Eliminado case 2: ContributeScreen (pantalla eliminada)
                          case 2:
                            Navigator.pushNamed(
                              context,
                              SettingsScreen.routeName,
                            );
                            break;
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Simplifica nombres de paraderos para TTS
  /// Convierte "PA1234 / Av. Providencia" en "Paradero" cuando es destino
  /// o simplemente remueve el código manteniendo la calle

  // ============================================================================
  // SIMULACIÓN REALISTA CON DESVIACIONES
  // ============================================================================

  /// Planifica una desviación aleatoria en la simulación de caminata
  /// Genera un punto de desviación y una ruta de regreso
  void _planSimulationDeviation(List<LatLng> originalGeometry) {
    if (!_simulationDeviationEnabled || originalGeometry.length < 20) {
      _simulationDeviationStep = -1;
      _simulationDeviationRoute = null;
      return;
    }

    final random = math.Random();
    
    // 40% de probabilidad de desviarse durante la simulación
    if (random.nextDouble() > 0.4) {
      _simulationDeviationStep = -1;
      _simulationDeviationRoute = null;
      return;
    }

    // Desviarse entre el 30% y 70% del recorrido
    final minIndex = (originalGeometry.length * 0.3).toInt();
    final maxIndex = (originalGeometry.length * 0.7).toInt();
    _simulationDeviationStep = minIndex + random.nextInt(maxIndex - minIndex);

    // Generar ruta de desviación (perpendicular a la ruta correcta)
    final deviationPoint = originalGeometry[_simulationDeviationStep];
    final nextPoint = _simulationDeviationStep < originalGeometry.length - 1
        ? originalGeometry[_simulationDeviationStep + 1]
        : originalGeometry[_simulationDeviationStep - 1];

    // Calcular vector perpendicular
    final dx = nextPoint.longitude - deviationPoint.longitude;
    final dy = nextPoint.latitude - deviationPoint.latitude;
    
    // Vector perpendicular (rotar 90 grados)
    final perpDx = -dy;
    final perpDy = dx;
    
    // Normalizar y escalar (desviación de 60-80 metros)
    final length = math.sqrt(perpDx * perpDx + perpDy * perpDy);
    final deviationDistance = 0.0006 + random.nextDouble() * 0.0002; // ~60-80m
    final normDx = (perpDx / length) * deviationDistance;
    final normDy = (perpDy / length) * deviationDistance;

    // Punto de máxima desviación
    final maxDeviationPoint = LatLng(
      deviationPoint.latitude + normDy,
      deviationPoint.longitude + normDx,
    );

    // Crear ruta de desviación: salida gradual (4 puntos) + regreso gradual (5 puntos)
    _simulationDeviationRoute = [
      // Salida gradual de la ruta
      LatLng(
        deviationPoint.latitude + normDy * 0.25,
        deviationPoint.longitude + normDx * 0.25,
      ),
      LatLng(
        deviationPoint.latitude + normDy * 0.5,
        deviationPoint.longitude + normDx * 0.5,
      ),
      LatLng(
        deviationPoint.latitude + normDy * 0.75,
        deviationPoint.longitude + normDx * 0.75,
      ),
      maxDeviationPoint,
      // Regreso gradual a la ruta
      LatLng(
        deviationPoint.latitude + normDy * 0.75,
        deviationPoint.longitude + normDx * 0.75,
      ),
      LatLng(
        deviationPoint.latitude + normDy * 0.5,
        deviationPoint.longitude + normDx * 0.5,
      ),
      LatLng(
        deviationPoint.latitude + normDy * 0.25,
        deviationPoint.longitude + normDx * 0.25,
      ),
      // Punto de regreso (siguiente en la ruta original)
      _simulationDeviationStep < originalGeometry.length - 5
          ? originalGeometry[_simulationDeviationStep + 5]
          : originalGeometry.last,
    ];

    _log('🎲 [SIMULACIÓN] Desviación planificada en punto $_simulationDeviationStep/${originalGeometry.length}');
    _log('   Distancia de desviación: ~${(deviationDistance * 111000).toInt()}m');
  }

  /// Obtiene el siguiente punto GPS para la simulación (con o sin desviación)
  LatLng _getNextSimulationPoint(List<LatLng> originalGeometry, int currentIndex) {
    // Si estamos en el punto de desviación, comenzar a seguir la ruta de desviación
    if (currentIndex == _simulationDeviationStep && _simulationDeviationRoute != null && !_isCurrentlyDeviated) {
      _isCurrentlyDeviated = true;
      _log('⚠️ [SIMULACIÓN] Iniciando desviación de ruta...');
      return _simulationDeviationRoute!.first;
    }

    // Si estamos desviados, seguir la ruta de desviación
    if (_isCurrentlyDeviated && _simulationDeviationRoute != null) {
      final deviationIndex = currentIndex - _simulationDeviationStep;
      
      if (deviationIndex < _simulationDeviationRoute!.length) {
        final deviationPoint = _simulationDeviationRoute![deviationIndex];
        
        // Último punto de desviación = regreso a la ruta
        if (deviationIndex == _simulationDeviationRoute!.length - 1) {
          _log('✅ [SIMULACIÓN] Regresando a la ruta correcta...');
          _isCurrentlyDeviated = false;
        }
        
        return deviationPoint;
      } else {
        // Terminar desviación y continuar con ruta original
        _isCurrentlyDeviated = false;
        final newIndex = _simulationDeviationStep + _simulationDeviationRoute!.length;
        return newIndex < originalGeometry.length 
            ? originalGeometry[newIndex]
            : originalGeometry.last;
      }
    }

    // Navegación normal por la ruta original
    return currentIndex < originalGeometry.length 
        ? originalGeometry[currentIndex]
        : originalGeometry.last;
  }

  /// Resetea el estado de desviación al iniciar nueva simulación
  void _resetSimulationDeviation() {
    _simulationDeviationStep = -1;
    _simulationDeviationRoute = null;
    _isCurrentlyDeviated = false;
  }
}

/// Widget optimizado para el marcador de ubicación del usuario
/// Diseño empresarial con flecha de navegación tipo GPS
class _UserLocationMarkerWidget extends StatelessWidget {
  const _UserLocationMarkerWidget();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Círculo de precisión (sutil)
        Container(
          width: 70,
          height: 70,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF1565C0).withValues(alpha: 0.1),
            border: Border.all(
              color: const Color(0xFF1565C0).withValues(alpha: 0.2),
              width: 1,
            ),
          ),
        ),
        // Triángulo/Flecha de navegación principal
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF1565C0), // Azul corporativo
            borderRadius: BorderRadius.circular(6),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: const Icon(
            Icons.navigation, // Triángulo de navegación
            color: Colors.white,
            size: 28,
          ),
        ),
      ],
    );
  }
}

/// Painter para dibujar la punta triangular del pin de ubicación
class _PinTipPainter extends CustomPainter {
  final Color color;

  _PinTipPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = ui.Path()
      ..moveTo(size.width / 2, size.height) // Punta del triángulo (abajo centro)
      ..lineTo(0, 0) // Esquina superior izquierda
      ..lineTo(size.width, 0) // Esquina superior derecha
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
