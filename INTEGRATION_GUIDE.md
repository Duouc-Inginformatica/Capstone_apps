# 🚀 Guía de Integración: TTS Mejorado + ONNX NPU

## Objetivo

Integrar el sistema TTS mejorado y la infraestructura ONNX en tu aplicación Flutter para aprovechar las mejoras de accesibilidad y aceleración por NPU.

---

## 📋 Requisitos Previos

- Flutter 3.35.4 o superior
- Dart 3.9.2 o superior
- Android: API nivel 27+ (para NNAPI)
- iOS: iOS 13+ (para CoreML)
- Dispositivo con NPU (ej: Motorola moto g53 5G)

---

## Paso 1: Actualizar Dependencias (Opcional - ONNX)

Si deseas usar ONNX Runtime para aceleración NPU real:

```yaml
# pubspec.yaml
dependencies:
  flutter:
    sdk: flutter
  
  # Dependencias existentes
  flutter_tts: ^4.0.2
  path_provider: ^2.1.1
  
  # NUEVA: ONNX Runtime (descomentar cuando esté listo)
  # onnxruntime: ^1.15.0
  # O alternativamente:
  # onnxruntime_flutter: ^0.1.0
```

Luego ejecutar:
```bash
flutter pub get
```

---

## Paso 2: Importar Servicios en tu Código

```dart
// En cualquier archivo donde necesites TTS
import 'package:tu_app/services/device/tts_service.dart';

// Si vas a usar ONNX
import 'package:tu_app/services/ml/onnx_service.dart';
```

---

## Paso 3: Inicializar Servicios

### Opción A: En main.dart (Recomendado)

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Inicializar TTS al inicio de la app
  await TtsService.instance.initialize();
  
  // Aplicar perfil de accesibilidad por defecto
  await TtsService.instance.applyAudioProfile(AudioProfile.accessibility);
  
  // Inicializar ONNX (opcional)
  // await OnnxService.instance.initialize();
  
  runApp(MyApp());
}
```

### Opción B: En initState() de tu widget

```dart
class MapScreen extends StatefulWidget {
  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  @override
  void initState() {
    super.initState();
    _initializeServices();
  }
  
  Future<void> _initializeServices() async {
    await TtsService.instance.initialize();
    await TtsService.instance.applyAudioProfile(AudioProfile.accessibility);
  }
  
  // ... resto del código
}
```

---

## Paso 4: Reemplazar Llamadas Antiguas a TTS

### Antes (TTS básico):

```dart
// Código antiguo
await TtsService.instance.speak('Gira a la izquierda');
```

### Después (TTS mejorado):

```dart
// Nuevo código con prioridades
await TtsService.instance.speak(
  'Gira a la izquierda',
  priority: TtsPriority.high,  // ⬅️ NUEVO: Prioridad alta
);

// O usar el método dedicado para navegación
await TtsService.instance.announceNavigation('Gira a la izquierda');
```

---

## Paso 5: Implementar Sistema de Prioridades en Navegación

### En integrated_navigation_service.dart

```dart
// ANTES: Todas las instrucciones tenían la misma prioridad
Future<void> _announceInstruction(String text) async {
  await TtsService.instance.speak(text);
}

// DESPUÉS: Instrucciones con prioridad según importancia
Future<void> _announceInstruction(String text, {bool isCritical = false}) async {
  await TtsService.instance.speak(
    text,
    priority: isCritical ? TtsPriority.critical : TtsPriority.high,
    urgent: isCritical,
  );
}

// Uso:
_announceInstruction('Continúa recto'); // Prioridad alta
_announceInstruction('¡Cruce peligroso!', isCritical: true); // Prioridad crítica
```

### En turn-by-turn instructions:

```dart
void _announceStreetInstructionsIfNeeded(NavigationStep step, double distanceRemaining) {
  // ... código existente ...
  
  final instruction = step.streetInstructions[safeIndex];
  
  // CAMBIAR ESTO:
  // await TtsService.instance.speak(instruction);
  
  // POR ESTO:
  await TtsService.instance.speak(
    instruction,
    priority: TtsPriority.high,  // Instrucciones de navegación siempre alta prioridad
  );
}
```

---

## Paso 6: Agregar Gestión de Contextos

### En map_screen.dart

```dart
class _MapScreenState extends State<MapScreen> {
  @override
  void initState() {
    super.initState();
    // Establecer contexto cuando entre a la pantalla
    TtsService.instance.setActiveContext('map');
  }
  
  @override
  void dispose() {
    // Liberar contexto cuando salga de la pantalla
    TtsService.instance.releaseContext('map');
    super.dispose();
  }
  
  // Al iniciar navegación
  void _startNavigation() {
    TtsService.instance.setActiveContext('navigation');
    
    // Anunciar inicio
    TtsService.instance.speak(
      'Navegación iniciada',
      context: 'navigation',
      priority: TtsPriority.high,
    );
  }
  
  // Al terminar navegación
  void _stopNavigation() {
    TtsService.instance.speak(
      'Navegación terminada',
      context: 'navigation',
      priority: TtsPriority.normal,
    );
    
    TtsService.instance.releaseContext('navigation');
    TtsService.instance.setActiveContext('map');
  }
}
```

---

## Paso 7: Implementar Perfiles de Usuario

Permitir al usuario elegir su perfil de audio preferido:

```dart
// En settings_screen.dart o similar

class AudioSettingsScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Configuración de Audio')),
      body: ListView(
        children: [
          ListTile(
            title: Text('Accesibilidad'),
            subtitle: Text('Lento y claro (recomendado para personas ciegas)'),
            onTap: () async {
              await TtsService.instance.applyAudioProfile(AudioProfile.accessibility);
              TtsService.instance.speak('Perfil de accesibilidad activado');
            },
          ),
          ListTile(
            title: Text('Normal'),
            subtitle: Text('Velocidad estándar'),
            onTap: () async {
              await TtsService.instance.applyAudioProfile(AudioProfile.normal);
              TtsService.instance.speak('Perfil normal activado');
            },
          ),
          ListTile(
            title: Text('Rápido'),
            subtitle: Text('Para usuarios experimentados'),
            onTap: () async {
              await TtsService.instance.applyAudioProfile(AudioProfile.fast);
              TtsService.instance.speak('Perfil rápido activado');
            },
          ),
          ListTile(
            title: Text('Silencioso'),
            subtitle: Text('Volumen bajo'),
            onTap: () async {
              await TtsService.instance.applyAudioProfile(AudioProfile.quiet);
              TtsService.instance.speak('Perfil silencioso activado');
            },
          ),
          Divider(),
          // Controles manuales
          ListTile(
            title: Text('Control Manual'),
            subtitle: Text('Ajustar velocidad, tono y volumen'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ManualAudioControlScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

class ManualAudioControlScreen extends StatefulWidget {
  @override
  _ManualAudioControlScreenState createState() => _ManualAudioControlScreenState();
}

class _ManualAudioControlScreenState extends State<ManualAudioControlScreen> {
  double _rate = 0.45;
  double _pitch = 0.95;
  double _volume = 1.0;
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Control Manual de Audio')),
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Velocidad: ${_rate.toStringAsFixed(2)}'),
            Slider(
              value: _rate,
              min: 0.1,
              max: 1.0,
              onChanged: (value) async {
                setState(() => _rate = value);
                await TtsService.instance.setRate(value);
              },
            ),
            SizedBox(height: 16),
            Text('Tono: ${_pitch.toStringAsFixed(2)}'),
            Slider(
              value: _pitch,
              min: 0.5,
              max: 2.0,
              onChanged: (value) async {
                setState(() => _pitch = value);
                await TtsService.instance.setPitch(value);
              },
            ),
            SizedBox(height: 16),
            Text('Volumen: ${_volume.toStringAsFixed(2)}'),
            Slider(
              value: _volume,
              min: 0.0,
              max: 1.0,
              onChanged: (value) async {
                setState(() => _volume = value);
                await TtsService.instance.setVolume(value);
              },
            ),
            SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                TtsService.instance.speak('Esta es una prueba de audio');
              },
              child: Text('Probar Audio'),
            ),
          ],
        ),
      ),
    );
  }
}
```

---

## Paso 8: Integrar ONNX (Cuando esté listo)

### Cargar modelo Piper para TTS offline:

```dart
// En un servicio dedicado o en initState()
Future<void> _loadPiperModel() async {
  try {
    await OnnxService.instance.initialize();
    
    await OnnxService.instance.loadModelFromAssets(
      modelName: 'piper_es_davefx_medium',
      assetPath: 'assets/models/piper_es_davefx_medium.onnx',
    );
    
    developer.log('✅ Modelo Piper cargado para TTS offline');
  } catch (e) {
    developer.log('❌ Error cargando modelo Piper: $e');
  }
}
```

### Usar TTS offline con Piper:

```dart
// Implementación futura (requiere integración completa de ONNX Runtime)
Future<void> speakWithPiper(String text) async {
  final audioBytes = await OnnxService.instance.runInference(
    modelName: 'piper_es_davefx_medium',
    input: text,
    useCache: true,
  );
  
  // Reproducir audio generado
  // await audioPlayer.playBytes(audioBytes);
}
```

---

## Paso 9: Monitorear y Debuggear

### Agregar logs en desarrollo:

```dart
// En modo debug, mostrar estadísticas
if (kDebugMode) {
  final stats = TtsService.instance.getStats();
  developer.log('📊 TTS Stats: $stats');
  
  if (TtsService.instance.hasCriticalMessages) {
    developer.log('⚠️ Hay mensajes críticos en cola');
  }
}
```

### Widget de debug (opcional):

```dart
class TtsDebugWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      onPressed: () {
        final stats = TtsService.instance.getStats();
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: Text('TTS Debug'),
            content: SingleChildScrollView(
              child: Text(stats.toString()),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  TtsService.instance.clearQueue();
                  Navigator.pop(context);
                },
                child: Text('Limpiar Cola'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Cerrar'),
              ),
            ],
          ),
        );
      },
      child: Icon(Icons.bug_report),
    );
  }
}
```

---

## Paso 10: Probar en Dispositivo Real

### Checklist de pruebas:

- [ ] TTS se inicializa correctamente
- [ ] Mensajes con prioridad `critical` interrumpen otros
- [ ] Mensajes duplicados se ignoran (< 3 segundos)
- [ ] Perfil `accessibility` es lento y claro
- [ ] Contextos filtran mensajes correctamente
- [ ] Historial guarda últimos 20 mensajes
- [ ] `repeatLast()` funciona
- [ ] Cola respeta prioridades (critical > high > normal > low)
- [ ] Voces neuronales se seleccionan si están disponibles
- [ ] ONNX detecta NPU del dispositivo (logs)

### Comandos útiles:

```bash
# Ver logs en tiempo real
flutter logs

# Buscar logs de TTS
flutter logs | grep "TTS"

# Buscar logs de ONNX
flutter logs | grep "ONNX"
```

---

## 🎯 Resultado Esperado

Después de seguir esta guía, tu app tendrá:

✅ **TTS Mejorado**
- Sistema de prioridades inteligente
- Prevención de duplicados
- Perfiles de audio optimizados
- Gestión de contextos
- Historial extendido
- Mejor accesibilidad

✅ **Infraestructura ONNX**
- Servicio listo para cargar modelos
- Detección de NPU/GPU
- Caché de resultados
- Gestión automática de recursos
- Preparado para ML on-device

---

## 🐛 Troubleshooting

### Problema: TTS no habla

**Solución:**
```dart
// Verificar inicialización
if (!TtsService.instance._initialized) {
  await TtsService.instance.initialize();
}

// Verificar contexto
developer.log('Contexto activo: ${TtsService.instance._activeContext}');
```

### Problema: Mensajes no se escuchan

**Posibles causas:**
1. Contexto diferente al activo
2. Mensaje duplicado reciente
3. Prioridad muy baja mientras hay mensajes de alta prioridad

**Solución:**
```dart
// Forzar mensaje crítico
await TtsService.instance.speak(
  'Mensaje importante',
  priority: TtsPriority.critical,
  urgent: true,
);
```

### Problema: ONNX no carga modelos

**Verificar:**
1. Modelos existen en `assets/models/`
2. Están declarados en `pubspec.yaml`:
   ```yaml
   flutter:
     assets:
       - assets/models/
   ```
3. ONNX Runtime está instalado (si usas inferencia real)

---

## 📚 Recursos Adicionales

- [TTS_ONNX_IMPROVEMENTS.md](./TTS_ONNX_IMPROVEMENTS.md) - Documentación completa
- [tts_onnx_examples.dart](./app/lib/examples/tts_onnx_examples.dart) - Ejemplos de código
- [TtsService](./app/lib/services/device/tts_service.dart) - Código fuente TTS
- [OnnxService](./app/lib/services/ml/onnx_service.dart) - Código fuente ONNX

---

## ✅ Checklist Final

- [ ] Dependencias actualizadas
- [ ] Servicios inicializados en main.dart
- [ ] Perfil de accesibilidad aplicado por defecto
- [ ] Prioridades agregadas a llamadas TTS existentes
- [ ] Contextos implementados en screens
- [ ] Configuración de audio accesible desde settings
- [ ] ONNX Service preparado (opcional)
- [ ] Logs de debug habilitados
- [ ] Probado en dispositivo real
- [ ] Documentación leída

---

**¡Felicitaciones!** 🎉 Tu app ahora tiene un sistema TTS de clase mundial optimizado para accesibilidad y está lista para aprovechar aceleración NPU con ONNX.
