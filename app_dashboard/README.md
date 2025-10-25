# WayFindCL Debug Dashboard

Dashboard de debugging en tiempo real para WayFindCL, construido con **Svelte 5**, **Vite 7**, **Tailwind CSS 4** y **Bits UI**.

## 🚀 Características

- 📊 **Logs en Tiempo Real**: Visualización de logs de backend, frontend, GraphHopper y scraping
- 📈 **Métricas del Sistema**: CPU, memoria, usuarios activos, requests/min
- 🔌 **Estado de APIs**: Monitoreo de backend, GraphHopper y base de datos
- 🌐 **Estado de Scraping**: Seguimiento de Moovit y Red CL
- 🎨 **Diseño Moderno**: Basado en los colores de Red Mobilidad (#E30613)
- ⚡ **WebSocket**: Comunicación en tiempo real con el backend

## 🛠️ Stack Tecnológico

- **Svelte 5** (con runes: `$state`, `$derived`, `$effect`)
- **Vite 7** (build tool ultra-rápido)
- **Tailwind CSS 4** (estilado moderno)
- **Bits UI 2.x** (componentes accesibles headless)
- **Lucide Svelte** (iconos modernos)
- **WebSocket** (comunicación en tiempo real)
- **TypeScript** (type safety)

## 📦 Instalación

```bash
# Instalar dependencias con Bun
bun install

# O con npm
npm install
```

## 🚦 Uso

### Desarrollo

```bash
# Iniciar servidor de desarrollo (http://localhost:3000)
bun dev

# O con npm
npm run dev
```

### Producción

```bash
# Build para producción
bun run build

# Preview del build
bun run preview
```

## ⚙️ Configuración

### Variables de Entorno

El dashboard se conecta al backend a través de WebSocket. Por defecto:

- **WebSocket URL**: `ws://localhost:8080/ws/debug`
- **Dashboard Port**: `3000`

### Backend Integration

Para habilitar el dashboard, asegúrate de que el backend tenga:

```properties
# En app_backend/.env
LUNCH_WEB_DEBUG_DASHBOARD=true
```

## 📡 Protocolo WebSocket

El dashboard recibe mensajes del backend con el siguiente formato:

### Log Message
```json
{
  "type": "log",
  "source": "backend" | "frontend" | "graphhopper" | "scraping",
  "level": "debug" | "info" | "warn" | "error",
  "message": "Mensaje del log",
  "metadata": { /* datos adicionales */ }
}
```

### Metrics Update
```json
{
  "type": "metrics",
  "metrics": [
    { "name": "CPU Usage", "value": 45, "unit": "%", "trend": "up" },
    { "name": "Memory", "value": 512, "unit": "MB", "trend": "stable" }
  ]
}
```

### API Status Update
```json
{
  "type": "api_status",
  "status": {
    "backend": { 
      "status": "online",
      "responseTime": 25,
      "uptime": 3600,
      "version": "1.0.0"
    },
    "graphhopper": {
      "status": "online",
      "responseTime": 150
    },
    "database": {
      "status": "online",
      "connections": 5,
      "maxConnections": 100
    }
  }
}
```

### Scraping Status Update
```json
{
  "type": "scraping_status",
  "status": {
    "moovit": {
      "lastRun": 1729785600000,
      "status": "idle",
      "itemsProcessed": 150,
      "errors": 0
    },
    "redCL": {
      "lastRun": 1729785600000,
      "status": "running",
      "itemsProcessed": 75,
      "errors": 2
    }
  }
}
```

## 🎨 Personalización

### Colores

Los colores están basados en Red Mobilidad y se pueden personalizar en `tailwind.config.js`:

```javascript
colors: {
  red: {
    600: '#E30613', // Color principal de Red Mobilidad
  },
  primary: 'hsl(355 86% 46%)', // #E30613
}
```

### Componentes

Todos los componentes están en `src/components/`:

- `Header.svelte` - Encabezado del dashboard
- `StatusBar.svelte` - Barra de estado de APIs
- `LogsPanel.svelte` - Panel de logs en tiempo real
- `MetricsPanel.svelte` - Panel de métricas del sistema
- `ApiStatus.svelte` - Estado detallado de APIs
- `ScrapingStatus.svelte` - Estado de procesos de scraping

## 📂 Estructura del Proyecto

```
app_dashboard/
├── src/
│   ├── components/          # Componentes Svelte
│   │   ├── Header.svelte
│   │   ├── StatusBar.svelte
│   │   ├── LogsPanel.svelte
│   │   ├── MetricsPanel.svelte
│   │   ├── ApiStatus.svelte
│   │   └── ScrapingStatus.svelte
│   ├── lib/
│   │   └── utils.ts         # Utilidades (cn, etc.)
│   ├── services/
│   │   └── websocket.ts     # Cliente WebSocket
│   ├── stores/
│   │   └── index.ts         # Stores de Svelte
│   ├── App.svelte           # Componente principal
│   ├── app.css              # Estilos globales
│   └── main.ts              # Entry point
├── index.html
├── package.json
├── tailwind.config.js
├── vite.config.ts
└── tsconfig.json
```

## 🔧 Scripts Disponibles

- `bun dev` - Inicia el servidor de desarrollo
- `bun run build` - Crea el build de producción
- `bun run preview` - Preview del build de producción
- `bun run check` - Verifica tipos con svelte-check

## 📝 TODO

- [ ] Implementar endpoint WebSocket en el backend Go
- [ ] Agregar filtros avanzados de logs
- [ ] Implementar gráficos de métricas con Chart.js
- [ ] Agregar exportación de logs a CSV/JSON
- [ ] Implementar autenticación para el dashboard
- [ ] Agregar notificaciones de errores críticos
- [ ] Implementar dark/light mode toggle

## 🤝 Integración con Backend

Ver `app_backend/internal/handlers/debug_websocket.go` para la implementación del servidor WebSocket.

## 📄 Licencia

Parte del proyecto WayFindCL - Capstone 2025
