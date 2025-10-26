# 🚌 Test del Scraper Red.cl - Simplificado

## Ejemplo de Respuesta

```bash
curl "http://localhost:8080/api/bus-arrivals/PC615"
```

### Output Esperado (Simplificado)
```json
{
  "stop_code": "PC615",
  "stop_name": "Avenida Las Condes / esq. La Cabaña",
  "arrivals": [
    {
      "route_number": "C01",
      "distance_km": 0.3
    },
    {
      "route_number": "C05",
      "distance_km": 1.2
    },
    {
      "route_number": "C13",
      "distance_km": 7.4
    },
    {
      "route_number": "409",
      "distance_km": 1.8
    }
  ],
  "last_updated": "2025-10-25T14:30:00Z"
}
```

## Cambios Aplicados

✅ **Eliminado**: `direction`, `estimated_minutes`, `estimated_time`, `status`  
✅ **Mantenido**: `route_number`, `distance_km`  
✅ **Mejora**: Eliminación de duplicados por combinación ruta + distancia  
✅ **Validación**: Solo entradas con ruta y distancia válidas

## Uso

Los tiempos y direcciones serán calculados por tu lógica de negocio basándose en:
- `distance_km`: Para estimar tiempo (ej: distancia / velocidad_promedio)
- Base de datos GTFS: Para obtener direcciones y paradas

---

**Nota**: El scraper ahora solo extrae datos brutos de Red.cl, dejando los cálculos y enriquecimiento a tu backend.
