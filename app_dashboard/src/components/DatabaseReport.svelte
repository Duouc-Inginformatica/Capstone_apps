<script lang="ts">
  import { onMount, tick } from 'svelte';
  import Icon from '@iconify/svelte';
  import * as echarts from 'echarts';
  import mermaid from 'mermaid';

  interface TableStats {
    tableName: string;
    rowCount: number;
    sizeKB: number;
    indexSizeKB: number;
    lastInsert?: string;
  }

  interface TableField {
    name: string;
    type: string;
    isPK: boolean;
    isFK: boolean;
    fkReference?: string;
  }

  // Definir estructura de campos para cada tabla (CORREGIDO)
  const tableStructures: Record<string, TableField[]> = {
    'users': [
      { name: 'user_id', type: 'INT', isPK: true, isFK: false },
      { name: 'email', type: 'VARCHAR', isPK: false, isFK: false },
      { name: 'name', type: 'VARCHAR', isPK: false, isFK: false },
      { name: 'created_at', type: 'TIMESTAMP', isPK: false, isFK: false },
    ],
    'trip_history': [
      { name: 'trip_id', type: 'INT', isPK: true, isFK: false },
      { name: 'user_id', type: 'INT', isPK: false, isFK: true, fkReference: 'users' },
      { name: 'origin', type: 'VARCHAR', isPK: false, isFK: false },
      { name: 'destination', type: 'VARCHAR', isPK: false, isFK: false },
      { name: 'created_at', type: 'TIMESTAMP', isPK: false, isFK: false },
    ],
    'gtfs_stops': [
      { name: 'stop_id', type: 'VARCHAR', isPK: true, isFK: false },
      { name: 'stop_name', type: 'VARCHAR', isPK: false, isFK: false },
      { name: 'stop_lat', type: 'DECIMAL', isPK: false, isFK: false },
      { name: 'stop_lon', type: 'DECIMAL', isPK: false, isFK: false },
    ],
    'gtfs_routes': [
      { name: 'route_id', type: 'VARCHAR', isPK: true, isFK: false },
      { name: 'route_short_name', type: 'VARCHAR', isPK: false, isFK: false },
      { name: 'route_long_name', type: 'VARCHAR', isPK: false, isFK: false },
      { name: 'route_type', type: 'INT', isPK: false, isFK: false },
    ],
    'gtfs_trips': [
      { name: 'trip_id', type: 'VARCHAR', isPK: true, isFK: false },
      { name: 'route_id', type: 'VARCHAR', isPK: false, isFK: true, fkReference: 'gtfs_routes' },
      { name: 'service_id', type: 'VARCHAR', isPK: false, isFK: false },
      { name: 'trip_headsign', type: 'VARCHAR', isPK: false, isFK: false },
    ],
    'gtfs_stop_times': [
      { name: 'id', type: 'INT', isPK: true, isFK: false },
      { name: 'trip_id', type: 'VARCHAR', isPK: false, isFK: true, fkReference: 'gtfs_trips' },
      { name: 'stop_id', type: 'VARCHAR', isPK: false, isFK: true, fkReference: 'gtfs_stops' },
      { name: 'arrival_time', type: 'TIME', isPK: false, isFK: false },
      { name: 'departure_time', type: 'TIME', isPK: false, isFK: false },
    ],
    'incidents': [
      { name: 'incident_id', type: 'INT', isPK: true, isFK: false },
      { name: 'stop_id', type: 'VARCHAR', isPK: false, isFK: true, fkReference: 'gtfs_stops' },
      { name: 'description', type: 'TEXT', isPK: false, isFK: false },
      { name: 'created_at', type: 'TIMESTAMP', isPK: false, isFK: false },
    ],
    'location_shares': [
      { name: 'share_id', type: 'INT', isPK: true, isFK: false },
      { name: 'user_id', type: 'INT', isPK: false, isFK: true, fkReference: 'users' },
      { name: 'latitude', type: 'DECIMAL', isPK: false, isFK: false },
      { name: 'longitude', type: 'DECIMAL', isPK: false, isFK: false },
      { name: 'shared_at', type: 'TIMESTAMP', isPK: false, isFK: false },
    ],
    'bus_arrivals': [
      { name: 'arrival_id', type: 'INT', isPK: true, isFK: false },
      { name: 'stop_id', type: 'VARCHAR', isPK: false, isFK: true, fkReference: 'gtfs_stops' },
      { name: 'route_id', type: 'VARCHAR', isPK: false, isFK: true, fkReference: 'gtfs_routes' },
      { name: 'trip_id', type: 'VARCHAR', isPK: false, isFK: true, fkReference: 'gtfs_trips' },
      { name: 'arrival_time', type: 'TIMESTAMP', isPK: false, isFK: false },
    ],
  };

  interface ConnectionStats {
    active: number;
    idle: number;
    maxOpen: number;
    waitCount: number;
    waitDuration: number;
  }

  interface GrowthPoint {
    date: string;
    rowCount: number;
    sizeMB: number;
  }

  interface DatabaseReport {
    totalTables: number;
    totalRows: number;
    totalSizeMB: number;
    tables: TableStats[];
    connectionStats: ConnectionStats;
    growthTrend: GrowthPoint[];
  }

  let report = $state<DatabaseReport | null>(null);
  let loading = $state(true);
  let chartContainer = $state<HTMLDivElement | undefined>(undefined);
  let mermaidContainer = $state<HTMLDivElement | undefined>(undefined);
  let chart: echarts.ECharts | null = null;
  let lastUpdate = $state<Date>(new Date());
  let showTablesChart = $state(false);

  // Efecto para inicializar el chart cuando el contenedor está disponible
  $effect(() => {
    console.log('[DatabaseReport $effect] showTablesChart:', showTablesChart, 'chartContainer:', !!chartContainer, 'chart:', !!chart, 'tables:', report?.tables?.length);
    
    if (showTablesChart && chartContainer && !chart && report?.tables && report.tables.length > 0) {
      console.log('[DatabaseReport $effect] Inicializando chart con', report.tables.length, 'tablas...');
      try {
        chart = echarts.init(chartContainer);
        console.log('[DatabaseReport $effect] Chart inicializado:', !!chart);
        updateTablesChart(report.tables);
        setTimeout(() => {
          if (chart) {
            console.log('[DatabaseReport $effect] Resizing chart...');
            chart.resize();
          }
        }, 100);
      } catch (err) {
        console.error('[DatabaseReport $effect] Error inicializando chart:', err);
      }
    }
  });

  async function fetchDatabaseReport() {
    try {
      loading = true;
      console.log('[DatabaseReport] Fetching data...');
      const response = await fetch('http://localhost:8080/api/stats/database');
      
      if (!response.ok) {
        throw new Error('Error al obtener reporte de base de datos');
      }
      
      const data = await response.json();
      console.log('[DatabaseReport] Data received:', data);
      console.log('[DatabaseReport] Tables count:', data.tables?.length);
      console.log('[DatabaseReport] Total rows:', data.totalRows);
      console.log('[DatabaseReport] Total size MB:', data.totalSizeMB);
      report = data;
      lastUpdate = new Date();
      
      // Actualizar gráfico si está visible
      if (chart && showTablesChart && data.tables) {
        console.log('[DatabaseReport] Updating chart with', data.tables.length, 'tables');
        updateTablesChart(data.tables);
      }
    } catch (err) {
      console.error('[DatabaseReport] Error fetching database report:', err);
    } finally {
      loading = false;
    }
  }

  async function toggleTablesChart() {
    console.log('toggleTablesChart called, current state:', showTablesChart);
    
    if (showTablesChart && chart) {
      // Limpiar el chart cuando se cierra el modelo
      console.log('Disposing chart...');
      chart.dispose();
      chart = null;
    }
    
    // Alternar el estado
    showTablesChart = !showTablesChart;
    
    console.log('New showTablesChart state:', showTablesChart);
    
    // Renderizar Mermaid después de que el DOM se actualice
    if (showTablesChart) {
      await tick();
      renderMermaidDiagram();
    }
  }

  async function renderMermaidDiagram() {
    if (!mermaidContainer) return;
    
    // Limpiar el contenedor primero
    mermaidContainer.innerHTML = '';
    
    // Crear el elemento pre>code con la sintaxis Mermaid
    const pre = document.createElement('pre');
    pre.className = 'mermaid';
    
    // Generar diagrama ER en sintaxis Mermaid (CORREGIDO con tipos coherentes)
    pre.textContent = `
erDiagram
    users ||--o{ trip_history : "has"
    users ||--o{ location_shares : "shares"
    gtfs_routes ||--o{ gtfs_trips : "contains"
    gtfs_trips ||--o{ gtfs_stop_times : "schedules"
    gtfs_stops ||--o{ gtfs_stop_times : "serves"
    gtfs_stops ||--o{ bus_arrivals : "receives"
    gtfs_stops ||--o{ incidents : "reports"
    gtfs_trips ||--o{ bus_arrivals : "belongs_to"
    
    users {
        int user_id PK "Identificador único de usuario"
        varchar email "Email del usuario"
        varchar name "Nombre del usuario"
        timestamp created_at "Fecha de creación"
    }
    
    trip_history {
        int trip_id PK "ID del viaje"
        int user_id FK "Usuario que realizó el viaje"
        varchar origin "Origen del viaje"
        varchar destination "Destino del viaje"
        timestamp created_at "Fecha del viaje"
    }
    
    location_shares {
        int share_id PK "ID de compartir ubicación"
        int user_id FK "Usuario compartiendo"
        decimal latitude "Latitud GPS"
        decimal longitude "Longitud GPS"
        timestamp shared_at "Momento compartido"
    }
    
    gtfs_stops {
        varchar stop_id PK "ID de parada GTFS"
        varchar stop_name "Nombre de la parada"
        decimal stop_lat "Latitud de parada"
        decimal stop_lon "Longitud de parada"
    }
    
    gtfs_routes {
        varchar route_id PK "ID de ruta GTFS"
        varchar route_short_name "Nombre corto ej 101"
        varchar route_long_name "Nombre completo"
        int route_type "Tipo de transporte"
    }
    
    gtfs_trips {
        varchar trip_id PK "ID de viaje programado"
        varchar route_id FK "Ruta a la que pertenece"
        varchar service_id "Calendario de servicio"
        varchar trip_headsign "Destino del viaje"
    }
    
    gtfs_stop_times {
        int id PK "ID autoincremental"
        varchar trip_id FK "Viaje al que pertenece"
        varchar stop_id FK "Parada en la ruta"
        time arrival_time "Hora de llegada"
        time departure_time "Hora de salida"
    }
    
    incidents {
        int incident_id PK "ID del incidente"
        varchar stop_id FK "Parada donde ocurrió"
        text description "Descripción del incidente"
        timestamp created_at "Momento del reporte"
    }
    
    bus_arrivals {
        int arrival_id PK "ID de llegada"
        varchar stop_id FK "Parada de llegada"
        varchar route_id FK "Ruta del bus"
        varchar trip_id FK "Viaje específico"
        timestamp arrival_time "Hora estimada de llegada"
    }
`;
    
    mermaidContainer.appendChild(pre);
    
    try {
      console.log('[Mermaid] Rendering diagram...');
      await mermaid.run({
        nodes: [pre],
      });
      console.log('[Mermaid] Diagram rendered successfully!');
    } catch (error) {
      console.error('[Mermaid] Error rendering diagram:', error);
    }
  }

  function updateTablesChart(tables: TableStats[]) {
    console.log('updateTablesChart called with', tables.length, 'tables');
    console.log('chart exists:', !!chart);
    console.log('chartContainer exists:', !!chartContainer);
    
    if (!chart || !chartContainer) {
      console.error('Chart or container not available');
      return;
    }
    
    // Ordenar tablas por tamaño (TODAS, no solo top 15)
    const sortedTables = [...tables]
      .sort((a, b) => b.sizeKB - a.sizeKB);
    
    console.log('Sorted tables:', sortedTables.map(t => t.tableName));
    
    // Verificar si hay tablas con tamaño
    const totalSize = sortedTables.reduce((sum, t) => sum + t.sizeKB, 0);
    console.log('[DatabaseReport] Total size of tables:', totalSize, 'KB');
    
    if (totalSize === 0) {
      console.warn('[DatabaseReport] All tables have 0 size! Cannot render treemap.');
      // Usar rowCount como fallback si no hay datos de tamaño
      sortedTables.forEach(t => {
        if (t.sizeKB === 0 && t.rowCount > 0) {
          // Estimar 1KB por fila como fallback
          t.sizeKB = t.rowCount;
        }
      });
      console.log('[DatabaseReport] Using rowCount as size fallback');
    }
    
    // Crear nodos para el diagrama ER
    const nodes: any[] = [];
    const links: any[] = [];
    
    // Definir relaciones conocidas entre tablas
    const relationships = [
      { from: 'gtfs_trips', to: 'gtfs_routes', label: 'route_id' },
      { from: 'gtfs_stop_times', to: 'gtfs_trips', label: 'trip_id' },
      { from: 'gtfs_stop_times', to: 'gtfs_stops', label: 'stop_id' },
      { from: 'trip_history', to: 'users', label: 'user_id' },
      { from: 'location_shares', to: 'users', label: 'user_id' },
      { from: 'bus_arrivals', to: 'gtfs_stops', label: 'stop_id' },
    ];
    
    // Crear nodos con posiciones
    sortedTables.forEach((table, index) => {
      const row = Math.floor(index / 3);
      const col = index % 3;
      
      nodes.push({
        name: table.tableName,
        value: table.rowCount,
        x: 150 + col * 250,
        y: 80 + row * 180,
        symbolSize: 80,
        itemStyle: {
          color: getTableColor(index),
          borderColor: '#1a1a2e',
          borderWidth: 2,
        },
        label: {
          show: true,
          formatter: () => {
            const sizeMB = (table.sizeKB / 1024).toFixed(1);
            const rowsK = table.rowCount > 1000 
              ? `${(table.rowCount / 1000).toFixed(1)}k` 
              : table.rowCount.toString();
            return `{name|${table.tableName}}\n{rows|${rowsK} filas}\n{size|${sizeMB} MB}`;
          },
          rich: {
            name: {
              fontSize: 12,
              fontWeight: 'bold',
              color: '#fff',
              lineHeight: 18,
            },
            rows: {
              fontSize: 10,
              color: '#34d399',
              lineHeight: 16,
            },
            size: {
              fontSize: 9,
              color: '#60a5fa',
              lineHeight: 14,
            },
          },
        },
      });
    });
    
    // Crear enlaces basados en relaciones
    relationships.forEach(rel => {
      const sourceIndex = sortedTables.findIndex(t => t.tableName === rel.from);
      const targetIndex = sortedTables.findIndex(t => t.tableName === rel.to);
      
      if (sourceIndex >= 0 && targetIndex >= 0) {
        links.push({
          source: sourceIndex,
          target: targetIndex,
          label: {
            show: true,
            formatter: rel.label,
            fontSize: 9,
            color: '#999',
          },
          lineStyle: {
            color: '#444',
            width: 2,
            curveness: 0.2,
          },
        });
      }
    });

    chart.setOption({
      backgroundColor: 'transparent',
      tooltip: {
        trigger: 'item',
        backgroundColor: 'rgba(20, 20, 30, 0.95)',
        borderColor: 'rgba(180, 180, 190, 0.3)',
        borderWidth: 1,
        textStyle: {
          color: '#ffffff',
        },
        formatter: (params: any) => {
          if (params.dataType === 'node') {
            const table = sortedTables[params.dataIndex];
            return `
              <div style="padding: 10px;">
                <div style="font-weight: bold; margin-bottom: 8px; color: ${getTableColor(params.dataIndex)}; font-size: 14px;">
                  ${table.tableName}
                </div>
                <div style="display: grid; gap: 6px;">
                  <div style="display: flex; justify-content: space-between; gap: 20px;">
                    <span style="color: #999;">Tamaño:</span> 
                    <span style="color: #fff; font-weight: bold;">${(table.sizeKB / 1024).toFixed(2)} MB</span>
                  </div>
                  <div style="display: flex; justify-content: space-between; gap: 20px;">
                    <span style="color: #999;">Registros:</span> 
                    <span style="color: #fff; font-weight: bold;">${table.rowCount.toLocaleString()}</span>
                  </div>
                  <div style="display: flex; justify-content: space-between; gap: 20px;">
                    <span style="color: #999;">Índices:</span> 
                    <span style="color: #34d399;">${(table.indexSizeKB / 1024).toFixed(2)} MB</span>
                  </div>
                </div>
              </div>
            `;
          }
          return params.name;
        },
      },
      series: [
        {
          type: 'graph',
          layout: 'none',
          data: nodes,
          links: links,
          roam: true,
          zoom: 0.8,
          label: {
            show: true,
            position: 'inside',
          },
          emphasis: {
            focus: 'adjacency',
            itemStyle: {
              shadowBlur: 15,
              shadowColor: 'rgba(96, 165, 250, 0.6)',
              borderWidth: 3,
            },
            label: {
              fontSize: 13,
            },
          },
        },
      ],
    });
    
    console.log('[DatabaseReport] setOption executed successfully');
    console.log('[DatabaseReport] Nodes:', nodes.length, 'Links:', links.length);
  }

  function getTableColor(index: number): string {
    const colors = [
      '#3b82f6', '#8b5cf6', '#ec4899', '#f59e0b', '#10b981',
      '#06b6d4', '#6366f1', '#a855f7', '#f43f5e', '#eab308',
      '#14b8a6', '#0ea5e9', '#7c3aed', '#db2777', '#d97706',
    ];
    return colors[index % colors.length];
  }

  // Renderizar una tabla con sus campos
  function renderTable(table: TableStats, x: number, y: number, color: string): { height: number } {
    const fields = tableStructures[table.tableName] || [];
    const fieldHeight = 18;
    const headerHeight = 35;
    const padding = 5;
    const totalHeight = headerHeight + (fields.length * fieldHeight) + padding * 2;
    
    return { height: totalHeight };
  }

  function formatNumber(num: number): string {
    return num.toLocaleString('es-CL');
  }

  function formatSize(kb: number): string {
    if (kb > 1024) {
      return `${(kb / 1024).toFixed(2)} MB`;
    }
    return `${kb.toFixed(2)} KB`;
  }

  function getTimeSince(date: Date): string {
    const now = new Date();
    const diff = now.getTime() - date.getTime();
    
    const seconds = Math.floor(diff / 1000);
    const minutes = Math.floor(seconds / 60);
    const hours = Math.floor(minutes / 60);
    
    if (hours > 0) return `Hace ${hours} hora${hours > 1 ? 's' : ''}`;
    if (minutes > 0) return `Hace ${minutes} minuto${minutes > 1 ? 's' : ''}`;
    return 'Hace unos segundos';
  }

  onMount(() => {
    // Inicializar Mermaid con configuración completa
    mermaid.initialize({
      startOnLoad: false, // Cambiado a false para control manual
      theme: 'dark',
      themeVariables: {
        darkMode: true,
        background: '#0f0f1a',
        primaryColor: '#3b82f6',
        primaryTextColor: '#ffffff',
        primaryBorderColor: '#60a5fa',
        lineColor: '#60a5fa',
        secondaryColor: '#8b5cf6',
        tertiaryColor: '#ec4899',
        fontSize: '14px',
        fontFamily: 'Inter, system-ui, sans-serif',
      },
      er: {
        useMaxWidth: true,
        fontSize: 14,
        layoutDirection: 'TB',
      },
      flowchart: {
        useMaxWidth: true,
      },
    });
    
    console.log('[DatabaseReport] Mermaid initialized');
    
    fetchDatabaseReport();
    
    // Actualizar cada 60 segundos
    const interval = setInterval(fetchDatabaseReport, 60000);
    
    return () => {
      clearInterval(interval);
      if (chart) {
        chart.dispose();
      }
    };
  });
</script>

<div class="neomorphic p-6 rounded-2xl">
  <!-- Header -->
  <div class="flex items-center justify-between mb-6">
    <div class="flex items-center gap-3">
      <div class="relative">
        <div class="absolute inset-0 bg-gradient-to-r from-purple-400 to-pink-400 rounded-xl blur-md opacity-75"></div>
        <div class="relative neomorphic-inset p-3 rounded-xl">
          <Icon icon="lucide:database" class="w-6 h-6 text-purple-300" />
        </div>
      </div>
      <div>
        <h3 class="text-xl font-bold gradient-text">Reporte de Base de Datos</h3>
        <p class="text-sm text-muted-foreground">Estadísticas y visualización</p>
        <p class="text-xs text-gray-500 mt-0.5">
          Actualizado: {getTimeSince(lastUpdate)}
        </p>
      </div>
    </div>
    
    <div class="flex items-center gap-2">
      <button
        onclick={toggleTablesChart}
        class="neomorphic-inset px-4 py-2 rounded-xl flex items-center gap-2 card-hover group"
      >
        <Icon
          icon={showTablesChart ? "lucide:eye-off" : "lucide:network"}
          class="w-4 h-4 text-blue-400 group-hover:scale-110 transition-transform"
        />
        <span class="text-sm text-muted-foreground">
          {showTablesChart ? 'Ocultar' : 'Ver'} Modelo
        </span>
      </button>
      
      <button
        onclick={fetchDatabaseReport}
        class="neomorphic-inset px-4 py-2 rounded-xl flex items-center gap-2 card-hover group"
      >
        <Icon
          icon="lucide:refresh-cw"
          class="w-4 h-4 text-gray-300 group-hover:rotate-180 transition-transform duration-500"
        />
        <span class="text-sm text-muted-foreground">Actualizar</span>
      </button>
    </div>
  </div>

  {#if loading && !report}
    <div class="flex items-center justify-center py-12">
      <Icon icon="lucide:loader-2" class="w-8 h-8 text-primary animate-spin" />
    </div>
  {:else if report}
    <!-- Métricas principales -->
    <div class="grid grid-cols-3 gap-4 mb-6">
      <div class="neomorphic-inset p-4 rounded-xl card-hover">
        <div class="flex items-center gap-2 mb-2">
          <Icon icon="lucide:table" class="w-4 h-4 text-blue-400" />
          <p class="text-xs text-muted-foreground">Tablas</p>
        </div>
        <p class="text-2xl font-bold text-white">{report.totalTables}</p>
      </div>
      
      <div class="neomorphic-inset p-4 rounded-xl card-hover">
        <div class="flex items-center gap-2 mb-2">
          <Icon icon="lucide:layers" class="w-4 h-4 text-emerald-400" />
          <p class="text-xs text-muted-foreground">Registros</p>
        </div>
        <p class="text-2xl font-bold text-white">{formatNumber(report.totalRows)}</p>
      </div>
      
      <div class="neomorphic-inset p-4 rounded-xl card-hover">
        <div class="flex items-center gap-2 mb-2">
          <Icon icon="lucide:hard-drive" class="w-4 h-4 text-amber-400" />
          <p class="text-xs text-muted-foreground">Tamaño</p>
        </div>
        <p class="text-2xl font-bold text-white">{report.totalSizeMB.toFixed(2)} MB</p>
      </div>
    </div>

    <!-- Gráfico de tablas (condicional) -->
    {#if showTablesChart && report}
      <div class="neomorphic-inset p-6 rounded-xl mb-6">
        <div class="flex items-center gap-2 mb-4">
          <Icon icon="lucide:database" class="w-5 h-5 text-blue-400" />
          <h4 class="font-semibold text-white">Estructura de Tablas</h4>
          <span class="text-xs text-gray-400 ml-auto">{report.tables.length} tablas</span>
        </div>
        
        <!-- Diagrama ER con Mermaid - Interactivo y Navegable -->
        <div class="w-full overflow-auto neomorphic-inset rounded-xl p-6 bg-gradient-to-br from-gray-900/50 to-gray-950/50">
          <div class="mermaid-wrapper">
            <div bind:this={mermaidContainer} class="mermaid-diagram"></div>
          </div>
          
          <!-- Controles de navegación -->
          <div class="mt-4 flex items-center justify-center gap-3 text-xs text-gray-400">
            <div class="flex items-center gap-2 px-3 py-1.5 bg-gray-800/50 rounded-lg">
              <Icon icon="lucide:mouse-pointer-2" class="w-3.5 h-3.5 text-blue-400" />
              <span>Haz clic y arrastra para mover</span>
            </div>
            <div class="flex items-center gap-2 px-3 py-1.5 bg-gray-800/50 rounded-lg">
              <Icon icon="lucide:zoom-in" class="w-3.5 h-3.5 text-emerald-400" />
              <span>Scroll para zoom</span>
            </div>
            <div class="flex items-center gap-2 px-3 py-1.5 bg-gray-800/50 rounded-lg">
              <Icon icon="lucide:hand" class="w-3.5 h-3.5 text-purple-400" />
              <span>Navega entre relaciones</span>
            </div>
          </div>
        </div>
      </div>
    {/if}

    <!-- Conexiones -->
    <div class="grid grid-cols-2 gap-4">
      <div class="neomorphic-inset p-4 rounded-xl">
        <div class="flex items-center gap-2 mb-3">
          <Icon icon="lucide:activity" class="w-5 h-5 text-emerald-400" />
          <h4 class="font-semibold text-white">Conexiones</h4>
        </div>
        <div class="space-y-2">
          <div class="flex justify-between">
            <span class="text-sm text-muted-foreground">Activas</span>
            <span class="text-sm font-mono text-emerald-400">{report.connectionStats.active}</span>
          </div>
          <div class="flex justify-between">
            <span class="text-sm text-muted-foreground">Inactivas</span>
            <span class="text-sm font-mono text-gray-400">{report.connectionStats.idle}</span>
          </div>
          <div class="flex justify-between">
            <span class="text-sm text-muted-foreground">Máximo</span>
            <span class="text-sm font-mono text-white">{report.connectionStats.maxOpen}</span>
          </div>
        </div>
      </div>
      
      <div class="neomorphic-inset p-4 rounded-xl">
        <div class="flex items-center gap-2 mb-3">
          <Icon icon="lucide:clock" class="w-5 h-5 text-blue-400" />
          <h4 class="font-semibold text-white">Performance</h4>
        </div>
        <div class="space-y-2">
          <div class="flex justify-between">
            <span class="text-sm text-muted-foreground">Wait Count</span>
            <span class="text-sm font-mono text-white">{formatNumber(report.connectionStats.waitCount)}</span>
          </div>
          <div class="flex justify-between">
            <span class="text-sm text-muted-foreground">Wait Time</span>
            <span class="text-sm font-mono text-amber-400">{(report.connectionStats.waitDuration / 1000).toFixed(2)} ms</span>
          </div>
        </div>
      </div>
    </div>
  {/if}
</div>

<style>
  /* Estilos personalizados para Mermaid ER Diagram */
  .mermaid-wrapper {
    width: 100%;
    min-height: 600px;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .mermaid-diagram {
    width: 100%;
    height: auto;
  }

  /* Personalizar elementos de Mermaid para mantener estilo neomórfico */
  :global(.mermaid-diagram svg) {
    max-width: 100%;
    height: auto;
    filter: drop-shadow(0 4px 20px rgba(59, 130, 246, 0.15));
  }

  /* Entidades (tablas) con estilo neomórfico */
  :global(.mermaid-diagram .er.entityBox) {
    fill: rgba(30, 30, 45, 0.95) !important;
    stroke: rgba(96, 165, 250, 0.6) !important;
    stroke-width: 2.5px !important;
    filter: drop-shadow(0 2px 8px rgba(0, 0, 0, 0.4));
    transition: all 0.3s ease;
  }

  :global(.mermaid-diagram .er.entityBox:hover) {
    fill: rgba(40, 40, 60, 1) !important;
    stroke: rgba(96, 165, 250, 1) !important;
    filter: drop-shadow(0 4px 16px rgba(59, 130, 246, 0.4));
    transform: translateY(-2px);
  }

  /* Nombres de tablas */
  :global(.mermaid-diagram .er.entityLabel) {
    fill: #ffffff !important;
    font-weight: 700 !important;
    font-size: 15px !important;
    font-family: 'Inter', system-ui, sans-serif !important;
  }

  /* Atributos (campos) */
  :global(.mermaid-diagram .er.attributeBoxOdd),
  :global(.mermaid-diagram .er.attributeBoxEven) {
    fill: rgba(255, 255, 255, 0.03) !important;
    stroke: rgba(255, 255, 255, 0.05) !important;
  }

  :global(.mermaid-diagram .er.attributeBoxOdd:hover),
  :global(.mermaid-diagram .er.attributeBoxEven:hover) {
    fill: rgba(96, 165, 250, 0.1) !important;
  }

  /* Texto de atributos */
  :global(.mermaid-diagram .er.entityLabel tspan) {
    fill: #e5e7eb !important;
    font-size: 12px !important;
  }

  /* Relaciones (líneas) */
  :global(.mermaid-diagram .er.relationshipLine) {
    stroke: rgba(96, 165, 250, 0.7) !important;
    stroke-width: 2.5px !important;
    filter: drop-shadow(0 0 4px rgba(96, 165, 250, 0.3));
  }

  :global(.mermaid-diagram .er.relationshipLine:hover) {
    stroke: rgba(139, 92, 246, 1) !important;
    stroke-width: 3.5px !important;
    filter: drop-shadow(0 0 8px rgba(139, 92, 246, 0.6));
  }

  /* Labels de relaciones */
  :global(.mermaid-diagram .er.relationshipLabel) {
    fill: #60a5fa !important;
    font-size: 11px !important;
    font-weight: 600 !important;
  }

  /* Markers (flechas) */
  :global(.mermaid-diagram marker) {
    fill: rgba(96, 165, 250, 0.8) !important;
  }

  /* Animación de entrada */
  .mermaid-diagram {
    animation: fadeInScale 0.6s ease-out;
  }

  @keyframes fadeInScale {
    from {
      opacity: 0;
      transform: scale(0.95);
    }
    to {
      opacity: 1;
      transform: scale(1);
    }
  }

  /* Interactividad mejorada */
  :global(.mermaid-diagram svg) {
    cursor: grab;
  }

  :global(.mermaid-diagram svg:active) {
    cursor: grabbing;
  }
</style>
