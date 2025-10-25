import { writable } from 'svelte/store';

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

// Stores using Svelte 5 compatible syntax
export const logsStore = writable<LogEntry[]>([]);
export const metricsStore = writable<Metric[]>([
  { name: 'CPU Usage', value: 0, unit: '%', trend: 'stable' },
  { name: 'Memory', value: 0, unit: 'MB', trend: 'stable' },
  { name: 'Active Users', value: 0, trend: 'stable' },
  { name: 'API Requests/min', value: 0, trend: 'stable' },
]);
export const apiStatusStore = writable<ApiStatusData>({
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
export const scrapingStatusStore = writable<ScrapingStatus>({
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
  
  logsStore.update(logs => {
    const updated = [newLog, ...logs];
    // Mantener solo los últimos 1000 logs
    return updated.slice(0, 1000);
  });
}

// Helper para limpiar logs
export function clearLogs() {
  logsStore.set([]);
}
