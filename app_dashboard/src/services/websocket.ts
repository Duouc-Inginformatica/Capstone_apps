import { addLog, apiStatusStore, metricsStore, scrapingStatusStore } from '../stores';

const WS_URL = 'ws://localhost:8080/ws/debug';
let ws: WebSocket | null = null;
let reconnectAttempts = 0;

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
    reconnectAttempts = 0; // Reset reconnect attempts on successful connection
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
      message: `Desconectado del servidor. Reconectando... (intento ${reconnectAttempts + 1})`,
    });
    
    // Exponential backoff for reconnection
    const delay = Math.min(30000, Math.pow(2, reconnectAttempts) * 1000);
    setTimeout(() => {
      reconnectAttempts++;
      connectWebSocket();
    }, delay);
  };
}

export function disconnectWebSocket() {
  if (ws) {
    ws.onclose = null; // Prevent reconnection logic from firing
    ws.close();
    ws = null;
    console.log('WebSocket desconectado.');
  }
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
      metricsStore.set(data.metrics);
      break;

    case 'api_status':
      apiStatusStore.set(data.status);
      break;

    case 'scraping_status':
      scrapingStatusStore.set(data.status);
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
