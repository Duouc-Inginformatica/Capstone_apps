import { addLog, apiStatusStore, metricsStore, scrapingStatusStore } from '../stores/index.svelte';

const WS_URL = 'ws://localhost:8080/ws/debug';
const STATUS_URL = 'http://localhost:8080/api/status';
let ws: WebSocket | null = null;
let reconnectAttempts = 0;
let mockDataInterval: number | null = null;
let statusInterval: number | null = null;

// Función para obtener el estado del sistema
async function fetchSystemStatus() {
  try {
    const response = await fetch(STATUS_URL);
    if (response.ok) {
      const status = await response.json();
      apiStatusStore.backend = status.backend;
      apiStatusStore.graphhopper = status.graphhopper;
      apiStatusStore.database = status.database;
    }
  } catch (error) {
    // Si falla, marcar como offline
    apiStatusStore.backend.status = 'offline';
    apiStatusStore.graphhopper.status = 'offline';
    apiStatusStore.database.status = 'offline';
  }
}

// Iniciar polling de status
function startStatusPolling() {
  if (statusInterval) return;
  
  // Consultar inmediatamente
  fetchSystemStatus();
  
  // Luego cada 5 segundos
  statusInterval = window.setInterval(fetchSystemStatus, 5000);
}

// Detener polling de status
function stopStatusPolling() {
  if (statusInterval) {
    clearInterval(statusInterval);
    statusInterval = null;
  }
}

export function connectWebSocket() {
  if (ws && ws.readyState === WebSocket.OPEN) {
    console.log('WebSocket already connected.');
    return;
  }

  ws = new WebSocket(WS_URL);

  ws.onopen = () => {
    console.log('✅ WebSocket conectado al backend');
    addLog({
      source: 'frontend',
      level: 'info',
      message: 'Dashboard conectado al servidor de debug',
    });
    reconnectAttempts = 0;
    stopMockData(); // Detener datos de prueba si se conecta
    startStatusPolling(); // Iniciar polling de status
  };

  ws.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data);
      handleWebSocketMessage(data);
    } catch (error) {
      console.error('Error parsing WebSocket message:', error);
    }
  };

  ws.onerror = (error) => {
    console.error('❌ WebSocket error:', error);
    addLog({
      source: 'frontend',
      level: 'error',
      message: 'Error de conexión con el servidor de debug',
    });
  };

  ws.onclose = () => {
    console.log('🔌 WebSocket desconectado. Intentando reconectar...');
    addLog({
      source: 'frontend',
      level: 'warn',
      message: `Desconectado del servidor. Reconectando en 3 segundos...`,
    });
    
    // Marcar backend como offline
    apiStatusStore.backend.status = 'offline';
    apiStatusStore.graphhopper.status = 'offline';
    apiStatusStore.database.status = 'offline';
    
    // Intentar reconectar cada 3 segundos
    reconnectAttempts++;
    setTimeout(() => {
      if (reconnectAttempts < 10) { // Máximo 10 intentos
        connectWebSocket();
      } else {
        addLog({
          source: 'frontend',
          level: 'error',
          message: 'No se pudo conectar al backend después de 10 intentos',
        });
      }
    }, 3000);
  };
}

export function disconnectWebSocket() {
  if (ws) {
    ws.onclose = null;
    ws.close();
    ws = null;
    console.log('WebSocket desconectado.');
  }
  stopMockData();
  stopStatusPolling();
}

function handleWebSocketMessage(data: any) {
  switch (data.type) {
    case 'log':
      addLog({
        source: data.source || 'backend',
        level: data.level || 'info',
        message: data.message,
        metadata: data.metadata,
      });
      break;

    case 'metrics':
      metricsStore.length = 0;
      metricsStore.push(...data.metrics);
      break;

    case 'api_status':
      Object.assign(apiStatusStore, data.status);
      break;

    case 'scraping_status':
      scrapingStatusStore.moovit = data.status.moovit;
      scrapingStatusStore.redCL = data.status.redCL;
      break;

    default:
      console.warn('Unknown message type:', data.type);
  }
}

// Función para enviar mensajes al backend
export function sendCommand(command: string, params?: any) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'command', command, params }));
  } else {
    console.error('WebSocket not connected. Cannot send command.');
  }
}

// Mock data para desarrollo cuando el backend no está disponible
function startMockData() {
  if (mockDataInterval) return;
  
  // Actualizar métricas con datos simulados
  apiStatusStore.backend.status = 'degraded';
  apiStatusStore.backend.responseTime = 45;
  apiStatusStore.backend.uptime = 3600;
  apiStatusStore.graphhopper.status = 'online';
  apiStatusStore.graphhopper.responseTime = 23;
  apiStatusStore.database.status = 'online';
  apiStatusStore.database.connections = 12;
  
  mockDataInterval = window.setInterval(() => {
    // Simular métricas cambiantes
    metricsStore[0].value = Math.floor(Math.random() * 100); // CPU
    metricsStore[1].value = Math.floor(Math.random() * 1024); // Memory
    metricsStore[2].value = Math.floor(Math.random() * 50); // Users
    metricsStore[3].value = Math.floor(Math.random() * 200); // Requests
    
    // Actualizar tendencias
    metricsStore[0].trend = Math.random() > 0.5 ? 'up' : 'down';
    metricsStore[1].trend = Math.random() > 0.5 ? 'up' : 'stable';
    
    // Agregar logs simulados ocasionalmente
    if (Math.random() > 0.7) {
      const sources: Array<'backend' | 'frontend' | 'graphhopper' | 'scraping'> = ['backend', 'frontend', 'graphhopper', 'scraping'];
      const levels: Array<'debug' | 'info' | 'warn' | 'error'> = ['debug', 'info', 'warn', 'error'];
      const messages = [
        'Procesando solicitud de ruta',
        'Cache actualizado correctamente',
        'Nuevo usuario conectado',
        'Consulta a base de datos completada',
        'Scraping de datos en progreso',
        'API request recibida',
      ];
      
      addLog({
        source: sources[Math.floor(Math.random() * sources.length)],
        level: levels[Math.floor(Math.random() * levels.length)],
        message: messages[Math.floor(Math.random() * messages.length)],
      });
    }
  }, 2000);
  
  addLog({
    source: 'frontend',
    level: 'info',
    message: '🎭 Modo demostración activado - Datos simulados',
  });
}

function stopMockData() {
  if (mockDataInterval) {
    clearInterval(mockDataInterval);
    mockDataInterval = null;
  }
}
