import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../widgets/map/accessible_notification.dart';

/// Estado centralizado del MapScreen
/// 
/// Reemplaza 50+ variables de estado dispersas por una clase estructurada
/// Facilita testing, debugging y gestión de estado
class MapState {
  // =========================================================================
  // UBICACIÓN Y POSICIONAMIENTO
  // =========================================================================
  final Position? currentPosition;
  final LatLng? pendingCenter;
  final double? pendingRotation;
  final double? pendingZoom;
  final bool isMapReady;

  // =========================================================================
  // VOZ Y RECONOCIMIENTO
  // =========================================================================
  final bool isListening;
  final String lastWords;
  final bool speechEnabled;
  final String pendingWords;
  final bool isProcessingCommand;
  final List<String> recognitionHistory;

  // =========================================================================
  // NPU Y HARDWARE
  // =========================================================================
  final bool npuAvailable;
  final bool npuLoading;
  final bool npuChecked;

  // =========================================================================
  // NAVEGACIÓN Y RUTA
  // =========================================================================
  final bool hasActiveTrip;
  final bool isTrackingRoute;
  final bool isCalculatingRoute;
  final bool showInstructionsPanel;
  final List<String> currentInstructions;
  final int currentInstructionStep;
  final int instructionFocusIndex;
  final bool autoReadInstructions;

  // =========================================================================
  // CONFIRMACIONES Y DIÁLOGOS
  // =========================================================================
  final String? pendingConfirmationDestination;
  final bool waitingBoardingConfirmation;

  // =========================================================================
  // SIMULACIÓN Y DEBUG
  // =========================================================================
  final bool isSimulating;
  final int currentSimulatedBusStopIndex;
  final bool busRouteShown;

  // =========================================================================
  // NOTIFICACIONES
  // =========================================================================
  final List<NotificationData> activeNotifications;
  final List<String> messageHistory;

  // =========================================================================
  // MAPA - MARCADORES Y GEOMETRÍA
  // =========================================================================
  final List<Marker> markers;
  final List<Polyline> polylines;
  final List<LatLng> cachedStepGeometry;
  final int cachedStepIndex;

  const MapState({
    // Ubicación
    this.currentPosition,
    this.pendingCenter,
    this.pendingRotation,
    this.pendingZoom,
    this.isMapReady = false,

    // Voz
    this.isListening = false,
    this.lastWords = '',
    this.speechEnabled = false,
    this.pendingWords = '',
    this.isProcessingCommand = false,
    this.recognitionHistory = const [],

    // NPU
    this.npuAvailable = false,
    this.npuLoading = false,
    this.npuChecked = false,

    // Navegación
    this.hasActiveTrip = false,
    this.isTrackingRoute = false,
    this.isCalculatingRoute = false,
    this.showInstructionsPanel = false,
    this.currentInstructions = const [],
    this.currentInstructionStep = 0,
    this.instructionFocusIndex = 0,
    this.autoReadInstructions = true,

    // Confirmaciones
    this.pendingConfirmationDestination,
    this.waitingBoardingConfirmation = false,

    // Simulación
    this.isSimulating = false,
    this.currentSimulatedBusStopIndex = -1,
    this.busRouteShown = false,

    // Notificaciones
    this.activeNotifications = const [],
    this.messageHistory = const [],

    // Mapa
    this.markers = const [],
    this.polylines = const [],
    this.cachedStepGeometry = const [],
    this.cachedStepIndex = -1,
  });

  /// Crea una copia del estado con valores modificados
  MapState copyWith({
    Position? currentPosition,
    LatLng? pendingCenter,
    double? pendingRotation,
    double? pendingZoom,
    bool? isMapReady,
    bool? isListening,
    String? lastWords,
    bool? speechEnabled,
    String? pendingWords,
    bool? isProcessingCommand,
    List<String>? recognitionHistory,
    bool? npuAvailable,
    bool? npuLoading,
    bool? npuChecked,
    bool? hasActiveTrip,
    bool? isTrackingRoute,
    bool? isCalculatingRoute,
    bool? showInstructionsPanel,
    List<String>? currentInstructions,
    int? currentInstructionStep,
    int? instructionFocusIndex,
    bool? autoReadInstructions,
    String? pendingConfirmationDestination,
    bool? waitingBoardingConfirmation,
    bool? isSimulating,
    int? currentSimulatedBusStopIndex,
    bool? busRouteShown,
    List<NotificationData>? activeNotifications,
    List<String>? messageHistory,
    List<Marker>? markers,
    List<Polyline>? polylines,
    List<LatLng>? cachedStepGeometry,
    int? cachedStepIndex,
  }) {
    return MapState(
      currentPosition: currentPosition ?? this.currentPosition,
      pendingCenter: pendingCenter ?? this.pendingCenter,
      pendingRotation: pendingRotation ?? this.pendingRotation,
      pendingZoom: pendingZoom ?? this.pendingZoom,
      isMapReady: isMapReady ?? this.isMapReady,
      isListening: isListening ?? this.isListening,
      lastWords: lastWords ?? this.lastWords,
      speechEnabled: speechEnabled ?? this.speechEnabled,
      pendingWords: pendingWords ?? this.pendingWords,
      isProcessingCommand: isProcessingCommand ?? this.isProcessingCommand,
      recognitionHistory: recognitionHistory ?? this.recognitionHistory,
      npuAvailable: npuAvailable ?? this.npuAvailable,
      npuLoading: npuLoading ?? this.npuLoading,
      npuChecked: npuChecked ?? this.npuChecked,
      hasActiveTrip: hasActiveTrip ?? this.hasActiveTrip,
      isTrackingRoute: isTrackingRoute ?? this.isTrackingRoute,
      isCalculatingRoute: isCalculatingRoute ?? this.isCalculatingRoute,
      showInstructionsPanel: showInstructionsPanel ?? this.showInstructionsPanel,
      currentInstructions: currentInstructions ?? this.currentInstructions,
      currentInstructionStep: currentInstructionStep ?? this.currentInstructionStep,
      instructionFocusIndex: instructionFocusIndex ?? this.instructionFocusIndex,
      autoReadInstructions: autoReadInstructions ?? this.autoReadInstructions,
      pendingConfirmationDestination: pendingConfirmationDestination,
      waitingBoardingConfirmation: waitingBoardingConfirmation ?? this.waitingBoardingConfirmation,
      isSimulating: isSimulating ?? this.isSimulating,
      currentSimulatedBusStopIndex: currentSimulatedBusStopIndex ?? this.currentSimulatedBusStopIndex,
      busRouteShown: busRouteShown ?? this.busRouteShown,
      activeNotifications: activeNotifications ?? this.activeNotifications,
      messageHistory: messageHistory ?? this.messageHistory,
      markers: markers ?? this.markers,
      polylines: polylines ?? this.polylines,
      cachedStepGeometry: cachedStepGeometry ?? this.cachedStepGeometry,
      cachedStepIndex: cachedStepIndex ?? this.cachedStepIndex,
    );
  }

  /// Verifica si hay una ruta activa con instrucciones
  bool get hasInstructions => currentInstructions.isNotEmpty;

  /// Verifica si hay navegación en progreso
  bool get isNavigating => hasActiveTrip || isTrackingRoute;

  /// Verifica si está esperando confirmación del usuario
  bool get isPendingConfirmation => 
      pendingConfirmationDestination != null || waitingBoardingConfirmation;

  /// Obtiene la instrucción actual
  String? get currentInstruction {
    if (currentInstructions.isEmpty) return null;
    if (currentInstructionStep >= currentInstructions.length) return null;
    return currentInstructions[currentInstructionStep];
  }

  /// Verifica si hay más instrucciones después de la actual
  bool get hasNextInstruction {
    return currentInstructionStep < currentInstructions.length - 1;
  }

  /// Verifica si hay instrucciones anteriores
  bool get hasPreviousInstruction {
    return currentInstructionStep > 0;
  }

  /// Obtiene el progreso de las instrucciones (0.0 - 1.0)
  double get instructionProgress {
    if (currentInstructions.isEmpty) return 0.0;
    return (currentInstructionStep + 1) / currentInstructions.length;
  }

  /// Estado inicial del mapa
  static const MapState initial = MapState();

  @override
  String toString() {
    return 'MapState('
        'hasActiveTrip: $hasActiveTrip, '
        'isListening: $isListening, '
        'isNavigating: $isNavigating, '
        'instructions: ${currentInstructions.length}, '
        'step: $currentInstructionStep, '
        'markers: ${markers.length}, '
        'polylines: ${polylines.length}'
        ')';
  }

  /// Debug info para logging
  Map<String, dynamic> toDebugMap() {
    return {
      'location': {
        'hasPosition': currentPosition != null,
        'isMapReady': isMapReady,
      },
      'voice': {
        'isListening': isListening,
        'speechEnabled': speechEnabled,
        'isProcessing': isProcessingCommand,
      },
      'navigation': {
        'hasActiveTrip': hasActiveTrip,
        'isTracking': isTrackingRoute,
        'isCalculating': isCalculatingRoute,
        'instructionStep': '$currentInstructionStep/${currentInstructions.length}',
      },
      'map': {
        'markers': markers.length,
        'polylines': polylines.length,
      },
      'notifications': {
        'active': activeNotifications.length,
        'history': messageHistory.length,
      },
    };
  }
}
