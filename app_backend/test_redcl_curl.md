# 🧪 Ejemplos de Prueba - Scraper Red.cl

## Prerequisitos
Servidor corriendo en `http://localhost:8080`

```bash
go run ./cmd/server/main.go
```

---

## 📍 Ejemplo 1: Consultar paradero PC615 (Providencia)

### PowerShell
```powershell
curl "http://localhost:8080/api/bus-arrivals/PC615"
```

### CMD
```cmd
curl "http://localhost:8080/api/bus-arrivals/PC615"
```

### Git Bash / Linux / Mac
```bash
curl "http://localhost:8080/api/bus-arrivals/PC615"
```

### Con formato JSON (usando `jq`)
```bash
curl -s "http://localhost:8080/api/bus-arrivals/PC615" | jq '.'
```

### Respuesta esperada
```json
{
  "stop_code": "PC615",
  "stop_name": "Av. Providencia / Santa Beatriz",
  "arrivals": [
    {
      "route_number": "C01",
      "direction": "Hacia Metro Francisco Bilbao",
      "distance_km": 1.6,
      "estimated_minutes": 5,
      "estimated_time": "",
      "status": "Muy cerca"
    },
    {
      "route_number": "C13",
      "direction": "Hacia Cantagallo",
      "distance_km": 9.2,
      "estimated_minutes": 25,
      "status": "Distante"
    }
  ],
  "last_updated": "2025-10-25T15:30:00Z"
}
```

---

## 📍 Ejemplo 2: Consultar paradero PA421 (Las Condes)

```bash
curl "http://localhost:8080/api/bus-arrivals/PA421"
```

---

## 📍 Ejemplo 3: Consultar paradero PI407 (Estación Metro)

```bash
curl "http://localhost:8080/api/bus-arrivals/PI407"
```

---

## 📍 Ejemplo 4: Consultar paradero PB108 (Bellavista)

```bash
curl "http://localhost:8080/api/bus-arrivals/PB108"
```

---

## 📍 Ejemplo 5: Consultar paradero PJ501 (Plaza de Armas)

```bash
curl "http://localhost:8080/api/bus-arrivals/PJ501"
```

---

## ⚠️ Ejemplo 6: Paradero inválido (manejo de errores)

```bash
curl "http://localhost:8080/api/bus-arrivals/XXXXX"
```

### Respuesta esperada (404)
```json
{
  "error": "No arrivals found",
  "stop_code": "XXXXX",
  "message": "No hay buses próximos para este paradero o el código es inválido"
}
```

---

## 🔍 Ejemplo 7: Ver solo los números de ruta

### PowerShell
```powershell
(curl "http://localhost:8080/api/bus-arrivals/PC615" | ConvertFrom-Json).arrivals | Select-Object route_number, estimated_minutes, status
```

### Bash con `jq`
```bash
curl -s "http://localhost:8080/api/bus-arrivals/PC615" | jq '.arrivals[] | {route: .route_number, minutes: .estimated_minutes, status: .status}'
```

---

## 🚀 Ejemplo 8: Múltiples consultas en paralelo

### PowerShell
```powershell
$stops = @("PC615", "PA421", "PI407")
$stops | ForEach-Object -Parallel {
    $response = Invoke-RestMethod "http://localhost:8080/api/bus-arrivals/$_"
    Write-Host "Paradero $_: $($response.arrivals.Count) buses"
}
```

### Bash
```bash
for stop in PC615 PA421 PI407; do
  echo "Consultando $stop..."
  curl -s "http://localhost:8080/api/bus-arrivals/$stop" | jq -r '"\(.stop_code): \(.arrivals | length) buses"'
done
```

---

## 📊 Ejemplo 9: Guardar respuesta en archivo

```bash
curl "http://localhost:8080/api/bus-arrivals/PC615" -o pc615_arrivals.json
```

---

## 🔄 Ejemplo 10: Consulta con timeout

```bash
curl --max-time 45 "http://localhost:8080/api/bus-arrivals/PC615"
```

---

## 🛠️ Troubleshooting

### Error: "executable file not found in %PATH%"
**Solución**: Instalar Google Chrome o configurar la ruta en el scraper.

### Error: "connection refused"
**Solución**: Verificar que el servidor esté corriendo:
```bash
netstat -ano | findstr :8080    # Windows
lsof -i :8080                   # Linux/Mac
```

### Error: "timeout"
**Solución**: Aumentar timeout en el scraper (actualmente 30s).

---

## 📝 Notas

- El scraper usa ChromeDP para obtener datos dinámicos de Red.cl
- Los tiempos estimados son proporcionados por Red.cl en tiempo real
- El código del paradero debe ser válido (formato: 2 letras + 3-4 números)
- La respuesta incluye nombre del paradero desde GTFS si está disponible

---

## 🎯 Casos de Uso

### 1. Aplicación móvil de accesibilidad
```javascript
fetch('http://localhost:8080/api/bus-arrivals/PC615')
  .then(res => res.json())
  .then(data => {
    const nextBus = data.arrivals[0];
    speakText(`El próximo bus ${nextBus.route_number} llega en ${nextBus.estimated_minutes} minutos`);
  });
```

### 2. Dashboard de tiempos de espera
```python
import requests

stops = ["PC615", "PA421", "PI407"]
for stop in stops:
    response = requests.get(f"http://localhost:8080/api/bus-arrivals/{stop}")
    data = response.json()
    print(f"{stop}: {len(data['arrivals'])} buses próximos")
```

### 3. Notificaciones automáticas
```bash
# Consultar cada 5 minutos
while true; do
  arrivals=$(curl -s "http://localhost:8080/api/bus-arrivals/PC615" | jq '.arrivals[0].estimated_minutes')
  if [ "$arrivals" -lt 3 ]; then
    echo "¡Tu bus llega en $arrivals minutos!"
  fi
  sleep 300
done
```
