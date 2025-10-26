# 📘 Guía de Uso - Nuevas Funcionalidades Desbloqueadas

## 🎯 Funcionalidades Ahora Disponibles

Esta guía muestra cómo usar las 3 funcionalidades que fueron desbloqueadas con la **MEJORA #1**.

---

## 1️⃣ Búsqueda de Paraderos por Nombre

### **Uso Básico:**

```dart
import 'package:wayfindcl/services/navigation/integrated_navigation_service.dart';

// Buscar paraderos que contengan "Alameda"
final service = IntegratedNavigationService.instance;
final stops = await service.searchStopsByName("Alameda");

// Resultado:
// [
//   RedBusStop(name: "Alameda / Estado", lat: -33.4489, lon: -70.6693, code: "PA123"),
//   RedBusStop(name: "Alameda / San Diego", lat: -33.4372, lon: -70.6506, code: "PA456"),
//   ...
// ]

// Mostrar en UI
for (final stop in stops) {
  print('${stop.name} (${stop.code})');
  print('  Ubicación: ${stop.latitude}, ${stop.longitude}');
}
```

### **Ejemplo Completo en Widget:**

```dart
class StopSearchWidget extends StatefulWidget {
  @override
  _StopSearchWidgetState createState() => _StopSearchWidgetState();
}

class _StopSearchWidgetState extends State<StopSearchWidget> {
  final _controller = TextEditingController();
  List<RedBusStop> _results = [];
  bool _isLoading = false;

  Future<void> _searchStops(String query) async {
    if (query.length < 3) return; // Mínimo 3 caracteres
    
    setState(() => _isLoading = true);
    
    final service = IntegratedNavigationService.instance;
    final stops = await service.searchStopsByName(query);
    
    setState(() {
      _results = stops;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: _controller,
          decoration: InputDecoration(
            labelText: 'Buscar paradero',
            suffixIcon: _isLoading
                ? CircularProgressIndicator()
                : Icon(Icons.search),
          ),
          onChanged: _searchStops,
        ),
        
        Expanded(
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, index) {
              final stop = _results[index];
              return ListTile(
                leading: Icon(Icons.directions_bus),
                title: Text(stop.name),
                subtitle: Text('Código: ${stop.code ?? "N/A"}'),
                trailing: Text(
                  '${stop.latitude.toStringAsFixed(4)}, ${stop.longitude.toStringAsFixed(4)}'
                ),
                onTap: () {
                  // Navegar al paradero o mostrar en mapa
                  Navigator.pop(context, stop);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
```

---

## 2️⃣ Consultar Rutas que Pasan por un Paradero

### **Uso Básico:**

```dart
// Obtener todas las rutas que pasan por el paradero "PA123"
final service = IntegratedNavigationService.instance;
final routes = await service.getRoutesByStop("PA123");

// Resultado:
// ["506", "210", "408", "C01"]

// Mostrar en UI
print('Rutas que pasan por este paradero:');
for (final route in routes) {
  print('  • $route');
}
```

### **Ejemplo: Mostrar Info Detallada del Paradero:**

```dart
class StopDetailScreen extends StatefulWidget {
  final RedBusStop stop;
  
  StopDetailScreen({required this.stop});

  @override
  _StopDetailScreenState createState() => _StopDetailScreenState();
}

class _StopDetailScreenState extends State<StopDetailScreen> {
  List<String> _routes = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    final service = IntegratedNavigationService.instance;
    final routes = await service.getRoutesByStop(widget.stop.code ?? '');
    
    setState(() {
      _routes = routes;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.stop.name),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.stop.name,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                SizedBox(height: 8),
                Text('Código: ${widget.stop.code ?? "N/A"}'),
                Text(
                  'Ubicación: ${widget.stop.latitude.toStringAsFixed(4)}, '
                  '${widget.stop.longitude.toStringAsFixed(4)}'
                ),
              ],
            ),
          ),
          
          Divider(),
          
          Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Rutas que pasan:',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          
          if (_isLoading)
            Center(child: CircularProgressIndicator())
          else if (_routes.isEmpty)
            Padding(
              padding: EdgeInsets.all(16),
              child: Text('No hay rutas disponibles'),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: _routes.length,
                itemBuilder: (context, index) {
                  final route = _routes[index];
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(route),
                    ),
                    title: Text('Ruta $route'),
                    trailing: Icon(Icons.arrow_forward_ios),
                    onTap: () {
                      // Mostrar detalles de la ruta
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
```

---

## 3️⃣ Detección de Buses en Tiempo Real

### **Uso Básico:**

```dart
// Este método se llama automáticamente durante la navegación
// cuando el usuario está cerca de un paradero de bus

// Internamente hace:
final service = IntegratedNavigationService.instance;
final step = navigationStep; // Paso actual de navegación
final userLocation = currentUserPosition;

await service._detectNearbyBuses(step, userLocation);

// Si hay buses próximos (< 5 minutos), el sistema:
// 1. Registra en logs: "🚌 Bus 506 llegará en 3 minutos"
// 2. Anuncia por TTS: "El bus 506 llegará en 3 minutos."
// 3. Dispara callback: onBusDetected?.call("506")
```

### **Ejemplo: Escuchar Detecciones de Buses:**

```dart
class NavigationScreen extends StatefulWidget {
  @override
  _NavigationScreenState createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  final service = IntegratedNavigationService.instance;
  String? _nextBus;
  int? _nextBusETA;

  @override
  void initState() {
    super.initState();
    
    // Configurar callback para detectar buses
    service.onBusDetected = (routeNumber) {
      setState(() {
        _nextBus = routeNumber;
      });
      
      // Mostrar notificación
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Bus $routeNumber se acerca'),
          duration: Duration(seconds: 5),
          backgroundColor: Colors.green,
        ),
      );
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Navegación')),
      body: Column(
        children: [
          // ... resto del UI de navegación ...
          
          if (_nextBus != null)
            Container(
              padding: EdgeInsets.all(16),
              color: Colors.green.shade100,
              child: Row(
                children: [
                  Icon(Icons.directions_bus, color: Colors.green),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Bus $_nextBus llegará pronto',
                      style: TextStyle(
                        color: Colors.green.shade900,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    service.onBusDetected = null;
    super.dispose();
  }
}
```

---

## 🔧 Uso de Métricas de Caché

### **Consultar Estado del Caché:**

```dart
import 'package:wayfindcl/services/backend/api_client.dart';

// Obtener métricas del caché
final metrics = RouteCache.instance.getMetrics();

print('📊 Estadísticas de Caché:');
print('  Hits: ${metrics['hits']}');
print('  Misses: ${metrics['misses']}');
print('  Hit Rate: ${metrics['hit_rate'].toStringAsFixed(1)}%');
print('  Rutas almacenadas: ${metrics['cached_routes']} / ${metrics['max_size']}');

// Top 5 rutas más usadas
final topRoutes = metrics['top_routes'] as List;
print('\n🏆 Top 5 Rutas Más Usadas:');
for (int i = 0; i < topRoutes.length; i++) {
  final route = topRoutes[i];
  print('  ${i + 1}. ${route['route']} - ${route['access_count']} accesos');
}
```

### **Ejemplo: Widget de Estadísticas:**

```dart
class CacheStatsWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final metrics = RouteCache.instance.getMetrics();
    final hitRate = metrics['hit_rate'] as double;
    final cachedRoutes = metrics['cached_routes'] as int;
    final maxSize = metrics['max_size'] as int;
    
    return Card(
      margin: EdgeInsets.all(16),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Estadísticas de Caché',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SizedBox(height: 16),
            
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Eficiencia:'),
                Text(
                  '${hitRate.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: hitRate >= 70 ? Colors.green : Colors.orange,
                  ),
                ),
              ],
            ),
            
            SizedBox(height: 8),
            
            LinearProgressIndicator(
              value: hitRate / 100,
              backgroundColor: Colors.grey.shade300,
              color: hitRate >= 70 ? Colors.green : Colors.orange,
            ),
            
            SizedBox(height: 16),
            
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Rutas almacenadas:'),
                Text(
                  '$cachedRoutes / $maxSize',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            
            SizedBox(height: 8),
            
            LinearProgressIndicator(
              value: cachedRoutes / maxSize,
              backgroundColor: Colors.grey.shade300,
            ),
            
            SizedBox(height: 16),
            
            Text(
              'Rutas más frecuentes:',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            
            SizedBox(height: 8),
            
            ...((metrics['top_routes'] as List).take(3).map((route) {
              final count = route['access_count'];
              return Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.star, size: 16, color: Colors.amber),
                    SizedBox(width: 8),
                    Text('$count accesos'),
                  ],
                ),
              );
            })),
            
            SizedBox(height: 16),
            
            ElevatedButton.icon(
              onPressed: () async {
                await RouteCache.instance.clearCache();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Caché limpiado')),
                );
              },
              icon: Icon(Icons.delete),
              label: Text('Limpiar Caché'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

---

## 🚀 Mejores Prácticas

### **1. Búsqueda de Paraderos:**

```dart
// ✅ BIEN: Esperar 3+ caracteres antes de buscar
if (query.length >= 3) {
  final stops = await service.searchStopsByName(query);
}

// ❌ MAL: Buscar con cada letra (sobrecarga)
onChanged: (query) => service.searchStopsByName(query),
```

### **2. Caché de Rutas:**

```dart
// ✅ BIEN: El caché se maneja automáticamente
final route = await apiClient.getPublicTransitRoute(...);
// Primera vez: consulta backend + guarda en caché
// Segunda vez: obtiene del caché (instantáneo)

// ❌ MAL: Forzar bypass del caché innecesariamente
final route = await apiClient.getPublicTransitRoute(
  ...,
  useCache: false, // Solo usar si REALMENTE necesitas datos frescos
);
```

### **3. Detección de Buses:**

```dart
// ✅ BIEN: Configurar callback una sola vez
@override
void initState() {
  super.initState();
  service.onBusDetected = _handleBusDetected;
}

@override
void dispose() {
  service.onBusDetected = null; // Limpiar
  super.dispose();
}

// ❌ MAL: No limpiar callbacks (memory leak)
service.onBusDetected = (route) { ... };
// Olvidar hacer: service.onBusDetected = null;
```

---

## 📊 Debugging

### **Ver Logs de Caché:**

```dart
// Los logs se generan automáticamente:

// Al cargar caché:
// ✅ [CACHE] Cargado: 23 rutas, Hit rate: 78.5%

// Al obtener ruta (HIT):
// ✅ [CACHE] HIT: -33.4489,-70.6693--33.4372,-70.6506 (12 accesos)

// Al obtener ruta (MISS):
// ❌ [CACHE] MISS: -33.4489,-70.6693--33.5123,-70.7234 (Total: 34 hits, 9 misses)

// Al limpiar rutas viejas:
// 🧹 [CACHE] Limpieza: eliminadas 3 rutas menos frecuentes

// Al limpiar todo:
// 🗑️ [CACHE] Limpiado completamente
```

### **Verificar Estado del Backend:**

```dart
// Verificar conectividad con el backend
final isConnected = await ApiClient.instance.testConnection();

if (!isConnected) {
  print('⚠️ Backend no disponible - usando modo offline');
  // Mostrar mensaje al usuario
}
```

---

## 🎯 Casos de Uso Completos

### **Caso 1: Planificador de Rutas Inteligente**

```dart
class RoutePlannerScreen extends StatefulWidget {
  @override
  _RoutePlannerScreenState createState() => _RoutePlannerScreenState();
}

class _RoutePlannerScreenState extends State<RoutePlannerScreen> {
  RedBusStop? _origin;
  RedBusStop? _destination;

  Future<void> _selectOrigin() async {
    final stop = await showSearch(
      context: context,
      delegate: StopSearchDelegate(),
    );
    
    if (stop != null) {
      setState(() => _origin = stop);
      
      // Obtener rutas que pasan por este paradero
      final routes = await IntegratedNavigationService.instance
          .getRoutesByStop(stop.code ?? '');
      
      print('Rutas disponibles en origen: $routes');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Planificar Ruta')),
      body: Column(
        children: [
          ListTile(
            leading: Icon(Icons.my_location),
            title: Text(_origin?.name ?? 'Seleccionar origen'),
            trailing: Icon(Icons.search),
            onTap: _selectOrigin,
          ),
          // ... similar para destino ...
        ],
      ),
    );
  }
}
```

---

**🎉 Ahora puedes aprovechar todas estas funcionalidades en tu app!**
