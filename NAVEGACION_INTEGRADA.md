# 🚌 Sistema de Navegación Integrada - Moovit + GTFS

## 📋 Descripción General

Sistema completo de navegación accesible para personas no videntes que combina:
- **Scraping de Moovit** para obtener rutas recomendadas
- **Datos GTFS** para información precisa de paraderos
- **Navegación GPS en tiempo real**
- **Guía por voz TTS** paso a paso

## 🔄 Flujo Completo de Navegación

```
1. Usuario (no vidente) → "Ir a Plaza Egaña"
2. App detecta ubicación GPS actual
3. Backend consulta Moovit → Obtiene ruta recomendada
4. Backend consulta GTFS → Identifica paraderos exactos
5. App inicia navegación guiada
6. Usuario llega al paradero → Alerta de llegada
7. Usuario espera bus Red 426
8. Usuario aborda y viaja
9. Usuario llega a destino → Confirmación final
```

## 📡 Arquitectura del Sistema

###Backend (Go)

**Endpoints Implementados:**

```
GET /api/red/routes/common
- Lista rutas Red comunes

GET /api/red/route/:routeNumber
- Información de ruta específica (ej: 426, 406, 422)

POST /api/red/itinerary
- Obtiene itinerario completo desde Moovit
Body: {
  "origin_lat": -33.437,
  "origin_lon": -70.650,
  "dest_lat": -33.454,
  "dest_lon": -70.617
}

GET /api/red/route/:routeNumber/stops
- Paradas de una ruta Red específica

GET /api/red/route/:routeNumber/geometry
- Geometría para dibujar en mapa

GET /api/stops?lat=-33.437&lon=-70.650&radius=500
- Paraderos cercanos desde GTFS
```

### Flutter App

**Servicios Implementados:**

```dart
// 1. RedBusService - Scraping de Moovit
RedBusService.instance.getRedBusItinerary(...)

// 2. IntegratedNavigationService - Navegación completa
IntegratedNavigationService.instance.startNavigation(...)

// 3. TtsService - Guía por voz
TtsService.instance.speak("Instrucción...")
```

## 🎯 Ejemplo de Uso Completo

### Código en Flutter (map_screen.dart)

```dart
// Cuando el usuario dice "Ir a Quinta Normal"
Future<void> _navigateToDestination(String destinationName, double destLat, double destLon) async {
  if (_currentPosition == null) {
    TtsService.instance.speak('No se pudo obtener tu ubicación');
    return;
  }

  // Anunciar inicio
  TtsService.instance.speak('Buscando ruta hacia $destinationName');

  try {
    // Iniciar navegación integrada
    final navigation = await IntegratedNavigationService.instance.startNavigation(
      originLat: _currentPosition!.latitude,
      originLon: _currentPosition!.longitude,
      destLat: destLat,
      destLon: destLon,
      destinationName: destinationName,
    );

    // Configurar callbacks
    IntegratedNavigationService.instance.onStepChanged = (step) {
      setState(() {
        // Actualizar UI con el paso actual
      });
      print('Paso actual: ${step.instruction}');
    };

    IntegratedNavigationService.instance.onArrivalAtStop = (stopId) {
      print('Llegaste al paradero: $stopId');
      // Vibración de confirmación
      Vibration.vibrate(duration: 500);
    };

    IntegratedNavigationService.instance.onDestinationReached = () {
      print('¡Destino alcanzado!');
      _showSuccessNotification('Has llegado a tu destino');
      Vibration.vibrate(duration: 1000);
    };

    // Dibujar ruta en el mapa
    setState(() {
      _polylines = [
        Polyline(
          points: navigation.routeGeometry,
          color: Colors.red, // Color característico de buses Red
          strokeWidth: 5.0,
        ),
      ];

      // Agregar marcadores de paraderos
      _markers = navigation.steps
          .where((s) => s.location != null)
          .map((s) => Marker(
                point: s.location!,
                child: Icon(
                  s.type == 'wait_bus' ? Icons.directions_bus : Icons.location_on,
                  color: Colors.orange,
                  size: 30,
                ),
              ))
          .toList();
    });

  } catch (e) {
    TtsService.instance.speak('Error al calcular la ruta: $e');
  }
}

// Comando de voz para repetir instrucción
void _onVoiceCommand(String command) {
  if (command.contains('repetir') || command.contains('qué debo hacer')) {
    IntegratedNavigationService.instance.repeatCurrentInstruction();
  } else if (command.contains('cancelar navegación')) {
    IntegratedNavigationService.instance.cancelNavigation();
  }
}
```

## 📱 Experiencia del Usuario (Persona No Vidente)

### Paso 1: Inicio de Sesión
```
Usuario: "Iniciar sesión"
App: "Ingresa tu nombre de usuario"
Usuario: "juan123"
App: "Ingresa tu contraseña"
Usuario: "mi_clave_segura"
App: "Sesión iniciada correctamente. Bienvenido Juan"
```

### Paso 2: Solicitar Navegación
```
Usuario: "Ir a Quinta Normal"
App: "Buscando ruta hacia Quinta Normal"
App: "Ruta encontrada. Duración estimada: 17 minutos"
App: "Tomarás 3 buses: 426, 406, 422"
App: "Primera instrucción: Camina 420 metros hacia el paradero PJ178"
```

### Paso 3: Caminata al Paradero
```
App: [A 100m] "Te estás acercando al paradero"
App: [A 50m] "Has llegado al paradero PJ178 - Consultorio Santa Anita"
App: "Buses disponibles: 426, 406, 422"
App: "Espera el bus Red 426"
```

### Paso 4: Espera del Bus
```
Usuario: [Llega bus 406]
Usuario: "¿Qué bus llegó?"
App: "Ese no es tu bus. Espera el bus 426"

Usuario: [Llega bus 426]
Usuario: "¿Es mi bus?"
App: "Sí, ese es tu bus. Puedes abordar el 426"
```

### Paso 5: Viaje en Bus
```
App: "Viaja en el bus Red 426 durante 13 minutos"
App: "11 paradas restantes"
App: [Cerca de destino] "Próxima parada: Parada 6 - Quinta Normal"
App: "Prepárate para bajar"
```

### Paso 6: Llegada
```
App: "Bájate aquí. Has llegado a Parada 6"
App: "Camina 11 paradas hacia tu destino"
App: [Final] "¡Felicitaciones! Has llegado a Quinta Normal"
```

## 🗺️ Visualización en el Mapa

La ruta se dibuja con:
- **Línea roja sólida** (#E30613) para buses Red
- **Línea gris punteada** para caminatas
- **Marcadores naranjas** 🚌 para paraderos de bus
- **Marcadores azules** 📍 para puntos de caminata
- **Marcador verde** ✅ para destino final

## 🔧 Configuración Técnica

### Variables de Entorno (Backend)
```env
# No requiere configuración adicional
# El scraping de Moovit usa solo HTTP público
```

### Dependencias Flutter
```yaml
dependencies:
  geolocator: ^10.0.0
  latlong2: ^0.9.0
  flutter_map: ^6.0.0
  flutter_tts: ^3.8.0
  vibration: ^1.8.3
```

### Dependencias Go
```
go get github.com/gofiber/fiber/v2
# No requiere dependencias adicionales para scraping
```

## 📊 Datos de Ejemplo (Imagen Proporcionada)

Según la imagen de referencia de Moovit:
- **Origen:** Julio Escudero, Lo Prado
- **Destino:** Quinta Normal, Santiago
- **Duración:** 17 minutos
- **Primera Caminata:** 420m en 6 minutos
- **Paradero:** PJ178 - Parada 1 / Consultorio Santa Anita
- **Buses:** 426 (La Dehesa), 406 (Cantagallo), 422 (La Reina) - hay desvío
- **Espera:** 1,3 minutos
- **Parada Destino:** Pa1-Parada 6 / (M) Quinta Normal
- **Segunda Caminata:** 11 paradas, 11 minutos

## 🎨 Colores de las Líneas de Bus Red

```dart
const Color RED_BUS_COLOR = Color(0xFFE30613); // Rojo característico
const Color WALK_COLOR = Color(0xFF757575);    // Gris para caminata
const Color METRO_COLOR = Color(0xFF0066CC);   // Azul para metro
```

## 🚀 Próximas Mejoras

1. **Tiempo Real de Buses:**
   - Integrar API de GPS de buses Red
   - Mostrar tiempo de llegada exacto
   - Alertar cuando el bus esté a 2 minutos

2. **Detección Automática de Abordaje:**
   - Usar acelerómetro para detectar movimiento del bus
   - Confirmar automáticamente cuando suba al bus

3. **Alertas de Bajada Inteligentes:**
   - Contar paradas automáticamente
   - Alertar 2 paradas antes del destino

4. **Modo Offline:**
   - Cachear rutas comunes
   - Funcionar sin conexión usando solo GPS

## 📝 Notas Importantes

- El scraping de Moovit es para **solo lectura** de información pública
- Los datos GTFS son oficiales de DTPM (Directorio de Transporte Público Metropolitano)
- La navegación GPS requiere permisos de ubicación siempre activos
- El TTS debe configurarse en idioma español (es-CL o es-ES)
- La precisión GPS debe ser HIGH para navegación urbana
- Se recomienda batería > 20% para navegación completa

## 🐛 Solución de Problemas

### "No se encontraron rutas"
- Verificar conexión a internet
- Comprobar que el backend está ejecutándose
- Revisar logs del scraper de Moovit

### "No se detecta llegada al paradero"
- Aumentar ARRIVAL_THRESHOLD_METERS si es necesario
- Verificar permisos de ubicación GPS
- Comprobar que el GPS tenga señal clara

### "TTS no funciona"
- Verificar idioma del dispositivo (debe ser español)
- Instalar motor TTS de Google en Android
- Otorgar permisos de audio

## 📞 Contacto y Soporte

Para reportar problemas o sugerencias:
- Crear issue en GitHub
- Documentar logs del error
- Incluir ubicación aproximada del problema
