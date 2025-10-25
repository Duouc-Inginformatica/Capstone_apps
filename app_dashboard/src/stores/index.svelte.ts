
// Types
export interface LogEntry {
  id: string;
  timestamp: number;
  source: 'backend' | 'frontend' | 'graphhopper' | 'scraping';
  level: 'debug' | 'info' | 'warn' | 'error';
  message: string;
  metadata?: Record<string, any>;
}

export interface Metric {
  name: string;
  value: number | string;
  unit?: string;
  trend?: 'up' | 'down' | 'stable';
}

export interface ApiStatusData {
  backend: {
    status: 'online' | 'offline' | 'degraded';
    responseTime: number;
    uptime: number;
    version: string;
  };
  graphhopper: {
    status: 'online' | 'offline' | 'degraded';
    responseTime: number;
  };
  database: {
    status: 'online' | 'offline' | 'degraded';
    connections: number;
    maxConnections: number;
  };
}

export interface ScrapingStatus {
  moovit: {
    lastRun: number;
    status: 'idle' | 'running' | 'error';
    itemsProcessed: number;
    errors: number;
  };
  redCL: {
    lastRun: number;
    status: 'idle' | 'running' | 'error';
    itemsProcessed: number;
    errors: number;
  };
}

// Reactive stores using Svelte 5 - exported as plain objects that will be made reactive in components
export let logsStore: LogEntry[] = $state([]);
export let metricsStore: Metric[] = $state([
  { name: 'CPU Usage', value: 0, unit: '%', trend: 'stable' },
  { name: 'Memory', value: 0, unit: 'MB', trend: 'stable' },
  { name: 'Active Users', value: 0, trend: 'stable' },
  { name: 'API Requests/min', value: 0, trend: 'stable' },
]);
export let apiStatusStore: ApiStatusData = $state({
  backend: {
    status: 'offline',
    responseTime: 0,
    uptime: 0,
    version: '1.0.0',
  },
  graphhopper: {
    status: 'offline',
    responseTime: 0,
  },
  database: {
    status: 'offline',
    connections: 0,
    maxConnections: 100,
  },
});
export let scrapingStatusStore: ScrapingStatus = $state({
  moovit: {
    lastRun: 0,
    status: 'idle',
    itemsProcessed: 0,
    errors: 0,
  },
  redCL: {
    lastRun: 0,
    status: 'idle',
    itemsProcessed: 0,
    errors: 0,
  },
});

// Helper para agregar un log
export function addLog(log: Omit<LogEntry, 'id' | 'timestamp'>) {
  const newLog: LogEntry = {
    ...log,
    id: crypto.randomUUID(),
    timestamp: Date.now(),
  };
  
  logsStore.unshift(newLog);
  if (logsStore.length > 1000) {
    logsStore.length = 1000;
  }
}

// Helper para limpiar logs
export function clearLogs() {
  logsStore.length = 0;
}
