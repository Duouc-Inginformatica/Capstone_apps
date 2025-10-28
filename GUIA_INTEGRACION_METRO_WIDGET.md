# Guía de Integración - MetroRoutePanelWidget

## Introducción

Este documento explica cómo integrar el nuevo widget `MetroRoutePanelWidget` en `map_screen.dart` para visualizar rutas con metro y trasbordos.

## Paso 1: Importar el Widget

Agregar al inicio de `map_screen.dart` (después de los otros imports):

```dart
import '../widgets/map/metro_route_panel.dart';
```

## Paso 2: Reemplazar Panel de Instrucciones

Buscar en `map_screen.dart` donde se construye el panel de instrucciones actual (aproximadamente línea 3833) y reemplazar con:

```dart
Widget _buildInstructionsPanel() {
  if (!_showInstructionsPanel || _navigationSteps.isEmpty) {
    return const SizedBox.shrink();
  }

  return Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: MetroRoutePanelWidget(
      steps: _navigationSteps,
      currentStepIndex: _currentStepIndex,
      onClose: () {
        setState(() {
          _showInstructionsPanel = false;
        });
        _ttsService.speak("Panel de instrucciones cerrado");
      },
      onStepTap: (index) {
        setState(() {
          _currentStepIndex = index;
        });
        final step = _navigationSteps[index];
        _speakInstruction(step.instruction);
        
        // Mover mapa al punto del paso (opcional)
        if (step.location != null) {
          _mapController.move(step.location!, 16.0);
        }
      },
      height: MediaQuery.of(context).size.height * 0.5, // 50% de la pantalla
    ),
  );
}
```

## Paso 3: Agregar Resumen Compacto (Opcional)

Para mostrar un resumen compacto cuando el panel está cerrado:

```dart
Widget _buildRouteSummary() {
  if (_navigationSteps.isEmpty || _showInstructionsPanel) {
    return const SizedBox.shrink();
  }

  return Positioned(
    top: 100, // Debajo del header
    left: 16,
    right: 16,
    child: MetroRouteSummaryWidget(
      steps: _navigationSteps,
      totalDuration: _getTotalDuration(),
    ),
  );
}

int _getTotalDuration() {
  return _navigationSteps.fold(0, (sum, step) => sum + step.estimatedDuration);
}
```

## Paso 4: Integrar en el Build Method

En el método `build()` de `_MapScreenState`, dentro del Stack:

```dart
@override
Widget build(BuildContext context) {
  return Scaffold(
    body: Stack(
      children: [
        // ... mapa y otros widgets existentes ...
        
        // AGREGAR: Resumen compacto de ruta
        _buildRouteSummary(),
        
        // REEMPLAZAR: Panel de instrucciones original con el nuevo
        _buildInstructionsPanel(),
        
        // ... otros widgets (botones, etc.) ...
      ],
    ),
  );
}
```

## Paso 5: Validar NavigationStep

El widget necesita que `NavigationStep` tenga estos campos:

- `type`: String ('walk', 'bus', 'metro', 'transfer', 'arrival')
- `instruction`: String
- `estimatedDuration`: int (minutos)
- `busRoute`: String? (para líneas de metro: 'L1', 'L2', etc.)
- `location`: LatLng?
- `isCompleted`: bool
- `totalStops`: int?
- `realDistanceMeters`: double?

## Paso 6: Conversión de Datos del Backend

Asegurarse de que al procesar la respuesta del backend, los TripLeg de tipo "metro" se conviertan correctamente:

```dart
List<NavigationStep> _convertBackendLegsToSteps(List<dynamic> legs) {
  return legs.map((leg) {
    final type = leg['type'] as String;
    final mode = leg['mode'] as String?;
    final routeNumber = leg['route_number'] as String?;
    
    // Detectar si es metro
    final isMetro = type == 'metro' || 
                    mode == 'Metro' ||
                    (routeNumber?.startsWith('L') == true && routeNumber!.length <= 3);
    
    return NavigationStep(
      type: isMetro ? 'metro' : type,
      instruction: leg['instruction'] as String,
      estimatedDuration: leg['duration_minutes'] as int? ?? 0,
      busRoute: routeNumber,
      location: leg['depart_stop'] != null
          ? LatLng(
              leg['depart_stop']['latitude'] as double,
              leg['depart_stop']['longitude'] as double,
            )
          : null,
      totalStops: leg['stop_count'] as int?,
      realDistanceMeters: (leg['distance_km'] as double?) != null
          ? (leg['distance_km'] as double) * 1000
          : null,
      isCompleted: false,
    );
  }).toList();
}
```

## Paso 7: Testing

### Escenario 1: Ruta con una línea de metro

```dart
final testSteps1 = [
  NavigationStep(
    type: 'walk',
    instruction: 'Camina hacia estación Los Heroes',
    estimatedDuration: 3,
    realDistanceMeters: 250,
  ),
  NavigationStep(
    type: 'metro',
    instruction: 'Toma Metro L1 hacia Baquedano',
    estimatedDuration: 8,
    busRoute: 'L1',
    totalStops: 8,
  ),
  NavigationStep(
    type: 'walk',
    instruction: 'Camina hacia tu destino',
    estimatedDuration: 2,
    realDistanceMeters: 180,
  ),
];
```

### Escenario 2: Ruta con transbordo de metro

```dart
final testSteps2 = [
  NavigationStep(
    type: 'walk',
    instruction: 'Camina hacia estación',
    estimatedDuration: 3,
  ),
  NavigationStep(
    type: 'metro',
    instruction: 'Toma Metro L2',
    estimatedDuration: 6,
    busRoute: 'L2',
    totalStops: 5,
  ),
  NavigationStep(
    type: 'transfer',
    instruction: 'Transbordo a Metro L5 en Baquedano',
    estimatedDuration: 2,
  ),
  NavigationStep(
    type: 'metro',
    instruction: 'Toma Metro L5',
    estimatedDuration: 10,
    busRoute: 'L5',
    totalStops: 12,
  ),
  NavigationStep(
    type: 'arrival',
    instruction: 'Has llegado a tu destino',
    estimatedDuration: 0,
  ),
];
```

### Escenario 3: Ruta multimodal (bus + metro + caminar)

```dart
final testSteps3 = [
  NavigationStep(type: 'walk', instruction: 'Camina al paradero', estimatedDuration: 2),
  NavigationStep(type: 'bus', instruction: 'Toma bus 506', estimatedDuration: 15, busRoute: '506'),
  NavigationStep(type: 'walk', instruction: 'Camina a estación metro', estimatedDuration: 3),
  NavigationStep(type: 'metro', instruction: 'Toma Metro L1', estimatedDuration: 12, busRoute: 'L1'),
  NavigationStep(type: 'walk', instruction: 'Camina a destino', estimatedDuration: 2),
  NavigationStep(type: 'arrival', instruction: 'Has llegado', estimatedDuration: 0),
];
```

## Notas Importantes

1. El widget detecta automáticamente si hay segmentos de metro
2. Los colores de las líneas son los oficiales del Metro de Santiago
3. El widget es completamente accesible (TalkBack/VoiceOver)
4. Se puede personalizar la altura con el parámetro `height`
5. El callback `onStepTap` es opcional pero recomendado para interactividad

## Troubleshooting

### Problema: No se muestran los badges de líneas de metro

**Solución:** Verificar que `busRoute` sea 'L1', 'L2', etc. (no '1', '2')

### Problema: Los colores no coinciden con el metro

**Solución:** Verificar que `busRoute` tenga formato exacto: 'L1', 'L2', 'L3', 'L4', 'L4A', 'L5', 'L6'

### Problema: El panel no se muestra

**Solución:** Verificar que `_showInstructionsPanel` sea true y `_navigationSteps` no esté vacío

### Problema: Los pasos no se marcan como completados

**Solución:** Actualizar `step.isCompleted` cuando el usuario avanza en la navegación
