# 🎤 Ejemplo de Uso - Navegación con Moovit

## 📱 Comandos de Voz Disponibles

### 🚌 Navegación con Buses Red (Scraping de Moovit)

El usuario puede solicitar navegación usando buses Red de dos formas:

#### **Forma 1: Comando explícito de Red**
```
Usuario: "Ruta Red a Quinta Normal"
Usuario: "Navegación Red a Plaza Egaña"  
Usuario: "Bus Red al Costanera Center"
```

#### **Forma 2: Navegación estándar** (usa GTFS + rutas existentes)
```
Usuario: "Ir a Plaza de Armas"
Usuario: "Quiero ir al Mall Plaza Vespucio"
Usuario: "Llevarme a la Universidad de Chile"
```

---

## 🎯 Flujo Completo de Navegación con Moovit

### Ejemplo Real: Ir a Quinta Normal desde Lo Prado

```
👤 Usuario: "Ruta Red a Quinta Normal"

🤖 App: "Buscando ruta hacia Quinta Normal usando Red"
      [La app consulta Moovit web scraping]
      
🤖 App: "Ruta encontrada. Duración estimada: 17 minutos"
      "Tomarás 3 buses: 426, 406, 422"
      "Primera instrucción: Camina 420 metros hacia el paradero PJ178"

📍 [El usuario comienza a caminar]

🤖 App: [A 100m] "Te estás acercando al paradero"

🤖 App: [A 50m] "Has llegado al paradero PJ178 - Parada 1 / Consultorio Santa Anita"
      "Buses disponibles: 426, 406, 422"
      "Espera el bus Red 426"

📍 [El usuario espera en el paradero]

🤖 App: [Llega bus 406] 
      "Ese no es tu bus. Espera el bus 426"

🤖 App: [Llega bus 426]
      "Ese es tu bus. Puedes abordar el Red 426"

📍 [Usuario aborda el bus]

🤖 App: "Viaja en el bus Red 426 durante 13 minutos"
      "11 paradas restantes"

🤖 App: [Cerca de destino]
      "Próxima parada: Parada 6 - Quinta Normal"
      "Prepárate para bajar"

🤖 App: [En el paradero de bajada]
      "Bájate aquí. Has llegado a Parada 6"
      "Camina 11 paradas hacia tu destino"

📍 [Usuario camina hacia destino final]

🤖 App: [A 50m del destino]
      "¡Felicitaciones! Has llegado a Quinta Normal"
      [Vibración de éxito]
```

---

## 🎮 Comandos Durante la Navegación

### Repetir Instrucción
```
Usuario: "Repetir"
Usuario: "Qué debo hacer"

🤖 App: "Camina 420 metros hacia el paradero PJ178"
```

### Siguiente Paso
```
Usuario: "Siguiente paso"

🤖 App: "Continúa siguiendo las instrucciones actuales"
```

### Cancelar Navegación
```
Usuario: "Cancelar navegación"
Usuario: "Detener navegación"

🤖 App: "Navegación cancelada"
      [Limpia la ruta del mapa]
```

---

## 🗺️ Visualización en el Mapa

Durante la navegación, el mapa muestra:

### Líneas de Ruta
- **Roja gruesa** (#E30613, 5px): Ruta completa de buses Red
- Incluye todas las caminatas + viajes en bus

### Marcadores
- 🚶 **Azul**: Puntos de caminata
- 🚌 **Naranja**: Paraderos de espera de bus
- 🚗 **Rojo**: Segmentos de viaje en bus
- 🔄 **Morado**: Puntos de transferencia entre buses
- ✅ **Verde**: Destino final

---

## ⚙️ Configuración Técnica

### Backend
El backend usa scraping HTTP directo (sin dependencias externas):

```go
// internal/moovit/scraper.go
func (s *MoovitScraper) GetRedBusItinerary(ctx context.Context, req ItineraryRequest) (*RouteItinerary, error) {
    // Scrapea https://moovitapp.com/
    // Parsea HTML con regex
    // Extrae rutas Red (426, 406, 422, etc.)
    // Genera itinerario con paradas y tiempos
}
```

### Frontend Flutter
El frontend coordina 3 servicios:

```dart
// 1. RedBusService - Comunicación con backend
final itinerary = await RedBusService.instance.getRedBusItinerary(...);

// 2. IntegratedNavigationService - Orquestación completa
final navigation = await IntegratedNavigationService.instance.startNavigation(...);

// 3. TtsService - Guía por voz
TtsService.instance.speak("Instrucción...");
```

---

## 🔍 Diferencias entre Navegación Estándar vs Red

| Característica | Navegación Estándar | Navegación Red (Moovit) |
|----------------|---------------------|-------------------------|
| **Fuente de datos** | GTFS local + OTP | Moovit web scraping |
| **Tipos de bus** | Todos (Transantiago) | Solo buses Red |
| **Comando de voz** | "Ir a..." | "Ruta Red a..." |
| **Tiempo real** | Limitado | Estimaciones de Moovit |
| **Opciones de ruta** | Múltiples algoritmos | Recomendación de Moovit |
| **Conexión requerida** | Sí (API local) | Sí (scraping web) |

---

## 📊 Datos de Ejemplo

Según las imágenes proporcionadas, el sistema maneja rutas como:

**Origen:** Julio Escudero, Lo Prado  
**Destino:** Quinta Normal, Santiago  
**Duración:** 17 minutos  
**Buses Red:** 426, 406, 422  
**Paradero inicial:** PJ178 - Parada 1  
**Paradero destino:** Pa1 - Parada 6  

---

## 🚀 Próximas Mejoras

1. **Caché de rutas comunes** - Guardar rutas frecuentes offline
2. **Tiempo real de buses** - Integrar GPS de Red
3. **Detección automática de abordaje** - Usar acelerómetro
4. **Alertas inteligentes de bajada** - Contar paradas automáticamente
5. **Múltiples idiomas** - Soporte para inglés, etc.

---

## 📝 Notas Importantes

- ✅ El scraping es **solo lectura** de información pública
- ✅ Los datos GTFS son **oficiales** de DTPM
- ✅ La navegación GPS requiere **permisos siempre activos**
- ✅ El TTS debe estar en **español** (es-CL o es-ES)
- ✅ La precisión GPS debe ser **HIGH** para navegación urbana
- ⚠️ Se recomienda **batería > 20%** para navegación completa

---

## 🐛 Solución de Problemas

### Error: "No se encontraron rutas"
**Solución:**
1. Verificar conexión a internet
2. Comprobar que el backend esté ejecutándose en `http://localhost:8080`
3. Revisar logs del scraper: `docker logs capstone-backend`

### Error: "No se detecta llegada al paradero"
**Solución:**
1. Aumentar `ARRIVAL_THRESHOLD_METERS` en `integrated_navigation_service.dart`
2. Verificar permisos de ubicación (debe ser "Siempre")
3. Asegurarse de tener señal GPS clara (salir al exterior)

### Error: "TTS no funciona"
**Solución:**
1. Verificar idioma del dispositivo (debe ser español)
2. Instalar motor TTS de Google en Android Settings
3. Otorgar permisos de audio a la app

---

## 📞 Soporte

Para reportar problemas:
1. Crear issue en GitHub con:
   - Logs completos (`flutter run --verbose`)
   - Ubicación aproximada del problema
   - Comando de voz que causó el error
   - Screenshots si es posible

---

**Desarrollado para personas no videntes** 👥  
**Powered by Moovit scraping + GTFS + GPS + TTS** 🚀
