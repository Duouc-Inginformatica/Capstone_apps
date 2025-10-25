<script lang="ts">
  import { onMount } from 'svelte';
  import Icon from '@iconify/svelte';

  interface GTFSFeedInfo {
    id: number;
    sourceUrl: string;
    feedVersion: string;
    importedAt: string;
    stopsCount: number;
    routesCount: number;
    tripsCount: number;
    timesCount: number;
  }

  interface Coverage {
    minLat: number;
    maxLat: number;
    minLon: number;
    maxLon: number;
    center: {
      lat: number;
      lon: number;
    };
  }

  interface GTFSStats {
    lastSync: GTFSFeedInfo | null;
    stops: number;
    routes: number;
    trips: number;
    stopTimes: number;
    activeRoutes: number;
    totalDistance: number;
    coverage: Coverage | null;
    cachedAt: string;
  }

  let stats = $state<GTFSStats>({
    lastSync: null,
    stops: 0,
    routes: 0,
    trips: 0,
    stopTimes: 0,
    activeRoutes: 0,
    totalDistance: 0,
    coverage: null,
    cachedAt: new Date().toISOString(),
  });

  let loading = $state(true);
  let error = $state<string | null>(null);

  async function fetchGTFSStats() {
    try {
      loading = true;
      error = null;
      const response = await fetch('http://localhost:8080/api/stats/gtfs');
      
      if (!response.ok) {
        throw new Error('Error al obtener estadísticas GTFS');
      }
      
      const data = await response.json();
      stats = data;
    } catch (err) {
      error = err instanceof Error ? err.message : 'Error desconocido';
      console.error('Error fetching GTFS stats:', err);
    } finally {
      loading = false;
    }
  }

  function formatDate(dateString: string): string {
    const date = new Date(dateString);
    return date.toLocaleString('es-CL', {
      day: '2-digit',
      month: '2-digit',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  }

  function formatNumber(num: number): string {
    return num.toLocaleString('es-CL');
  }

  function getTimeSince(dateString: string): string {
    const date = new Date(dateString);
    const now = new Date();
    const diff = now.getTime() - date.getTime();
    
    const seconds = Math.floor(diff / 1000);
    const minutes = Math.floor(seconds / 60);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);
    
    if (days > 0) return `Hace ${days} día${days > 1 ? 's' : ''}`;
    if (hours > 0) return `Hace ${hours} hora${hours > 1 ? 's' : ''}`;
    if (minutes > 0) return `Hace ${minutes} minuto${minutes > 1 ? 's' : ''}`;
    return 'Hace unos segundos';
  }

  onMount(() => {
    fetchGTFSStats();
    
    // Actualizar cada 30 segundos
    const interval = setInterval(fetchGTFSStats, 30000);
    return () => clearInterval(interval);
  });
</script>

<div class="neomorphic p-6 rounded-2xl">
  <!-- Header -->
  <div class="flex items-center justify-between mb-6">
    <div class="flex items-center gap-3">
      <div class="relative">
        <div class="absolute inset-0 bg-gradient-to-r from-blue-400 to-cyan-400 rounded-xl blur-md opacity-75"></div>
        <div class="relative neomorphic-inset p-3 rounded-xl">
          <Icon icon="lucide:database" class="w-6 h-6 text-cyan-300" />
        </div>
      </div>
      <div>
        <h3 class="text-xl font-bold gradient-text">Sistema GTFS</h3>
        <p class="text-sm text-muted-foreground">Datos de Transporte Público</p>
        {#if stats.cachedAt}
          <p class="text-xs text-gray-500 mt-0.5">
            Actualizado: {getTimeSince(stats.cachedAt)}
          </p>
        {/if}
      </div>
    </div>
    
    <div class="flex items-center gap-2">
      <a
        href="https://www.dtpm.cl/index.php/gtfs-vigente"
        target="_blank"
        rel="noopener noreferrer"
        class="neomorphic-inset px-4 py-2 rounded-xl flex items-center gap-2 card-hover group"
        title="Descargar datos GTFS vigente desde DTPM"
      >
        <Icon
          icon="lucide:download"
          class="w-4 h-4 text-emerald-400 group-hover:scale-110 transition-transform"
        />
        <span class="text-sm text-muted-foreground">Datos DTPM</span>
      </a>
      
      <button
        onclick={fetchGTFSStats}
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

  {#if loading && !stats.lastSync}
    <div class="flex items-center justify-center py-12">
      <Icon icon="lucide:loader-2" class="w-8 h-8 text-primary animate-spin" />
    </div>
  {:else if error}
    <div class="neomorphic-inset p-4 rounded-xl text-center">
      <Icon icon="lucide:alert-triangle" class="w-8 h-8 text-red-400 mx-auto mb-2" />
      <p class="text-red-400 text-sm">{error}</p>
    </div>
  {:else}
    <!-- Último Sync Info -->
    {#if stats.lastSync}
      <div class="neomorphic-inset p-4 rounded-xl mb-6 bg-gradient-to-br from-background/30 to-background/10">
        <div class="flex items-start justify-between">
          <div class="flex-1">
            <div class="flex items-center gap-2 mb-2">
              <Icon icon="lucide:calendar-check" class="w-5 h-5 text-emerald-400" />
              <h4 class="font-semibold text-white">Último Feed Sincronizado</h4>
            </div>
            
            <div class="grid grid-cols-2 gap-3 mt-3">
              <div>
                <p class="text-xs text-muted-foreground mb-1">Versión</p>
                <p class="text-sm font-mono text-cyan-300">{stats.lastSync.feedVersion}</p>
              </div>
              
              <div>
                <p class="text-xs text-muted-foreground mb-1">Importado</p>
                <p class="text-sm text-white">{getTimeSince(stats.lastSync.importedAt)}</p>
                <p class="text-xs text-gray-400 font-mono">{formatDate(stats.lastSync.importedAt)}</p>
              </div>
            </div>
            
            <div class="mt-3 pt-3 border-t border-white/5">
              <p class="text-xs text-muted-foreground mb-2">Archivo fuente:</p>
              <p class="text-xs text-blue-400 font-mono truncate">{stats.lastSync.sourceUrl}</p>
            </div>
          </div>
        </div>
      </div>
    {/if}

    <!-- Métricas Grid -->
    <div class="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
      <!-- Paradas -->
      <div class="neomorphic-inset p-4 rounded-xl card-hover group">
        <div class="flex items-center gap-3 mb-2">
          <div class="relative">
            <div class="absolute inset-0 bg-gradient-to-r from-purple-400 to-purple-500 rounded-lg blur opacity-50 group-hover:opacity-75 transition-opacity"></div>
            <div class="relative neomorphic-inset p-2 rounded-lg">
              <Icon icon="lucide:map-pin" class="w-4 h-4 text-purple-300" />
            </div>
          </div>
          <p class="text-xs text-muted-foreground font-medium">Paradas</p>
        </div>
        <p class="text-2xl font-bold text-white ml-11">{formatNumber(stats.stops)}</p>
        {#if stats.lastSync}
          <p class="text-xs text-gray-400 mt-1 ml-11">Feed actual: {formatNumber(stats.lastSync.stopsCount)}</p>
        {/if}
      </div>

      <!-- Rutas -->
      <div class="neomorphic-inset p-4 rounded-xl card-hover group">
        <div class="flex items-center gap-3 mb-2">
          <div class="relative">
            <div class="absolute inset-0 bg-gradient-to-r from-blue-400 to-blue-500 rounded-lg blur opacity-50 group-hover:opacity-75 transition-opacity"></div>
            <div class="relative neomorphic-inset p-2 rounded-lg">
              <Icon icon="lucide:route" class="w-4 h-4 text-blue-300" />
            </div>
          </div>
          <p class="text-xs text-muted-foreground font-medium">Rutas</p>
        </div>
        <p class="text-2xl font-bold text-white ml-11">{formatNumber(stats.routes)}</p>
        {#if stats.lastSync}
          <p class="text-xs text-emerald-400 mt-1 ml-11">{formatNumber(stats.activeRoutes)} activas</p>
        {/if}
      </div>

      <!-- Viajes -->
      <div class="neomorphic-inset p-4 rounded-xl card-hover group">
        <div class="flex items-center gap-3 mb-2">
          <div class="relative">
            <div class="absolute inset-0 bg-gradient-to-r from-cyan-400 to-cyan-500 rounded-lg blur opacity-50 group-hover:opacity-75 transition-opacity"></div>
            <div class="relative neomorphic-inset p-2 rounded-lg">
              <Icon icon="lucide:bus" class="w-4 h-4 text-cyan-300" />
            </div>
          </div>
          <p class="text-xs text-muted-foreground font-medium">Viajes</p>
        </div>
        <p class="text-2xl font-bold text-white ml-11">{formatNumber(stats.trips)}</p>
        {#if stats.lastSync}
          <p class="text-xs text-gray-400 mt-1 ml-11">Feed actual: {formatNumber(stats.lastSync.tripsCount)}</p>
        {/if}
      </div>

      <!-- Horarios -->
      <div class="neomorphic-inset p-4 rounded-xl card-hover group">
        <div class="flex items-center gap-3 mb-2">
          <div class="relative">
            <div class="absolute inset-0 bg-gradient-to-r from-amber-400 to-amber-500 rounded-lg blur opacity-50 group-hover:opacity-75 transition-opacity"></div>
            <div class="relative neomorphic-inset p-2 rounded-lg">
              <Icon icon="lucide:clock" class="w-4 h-4 text-amber-300" />
            </div>
          </div>
          <p class="text-xs text-muted-foreground font-medium">Horarios</p>
        </div>
        <p class="text-2xl font-bold text-white ml-11">{formatNumber(stats.stopTimes)}</p>
        {#if stats.lastSync}
          <p class="text-xs text-gray-400 mt-1 ml-11">Feed actual: {formatNumber(stats.lastSync.timesCount)}</p>
        {/if}
      </div>
    </div>

    <!-- Cobertura -->
    {#if stats.coverage}
      <div class="neomorphic-inset p-4 rounded-xl">
        <div class="flex items-center gap-2 mb-3">
          <Icon icon="lucide:map" class="w-5 h-5 text-emerald-400" />
          <h4 class="font-semibold text-white">Cobertura Geográfica</h4>
        </div>
        
        <div class="grid grid-cols-2 gap-4">
          <div>
            <p class="text-xs text-muted-foreground mb-2">Centro</p>
            <p class="text-sm font-mono text-cyan-300">
              {stats.coverage.center.lat.toFixed(4)}°, {stats.coverage.center.lon.toFixed(4)}°
            </p>
          </div>
          
          <div>
            <p class="text-xs text-muted-foreground mb-2">Área aprox.</p>
            <p class="text-sm font-mono text-amber-300">
              ~{stats.totalDistance.toFixed(0)} km
            </p>
          </div>
          
          <div>
            <p class="text-xs text-muted-foreground mb-2">Latitud</p>
            <p class="text-sm font-mono text-gray-300">
              {stats.coverage.minLat.toFixed(4)}° - {stats.coverage.maxLat.toFixed(4)}°
            </p>
          </div>
          
          <div>
            <p class="text-xs text-muted-foreground mb-2">Longitud</p>
            <p class="text-sm font-mono text-gray-300">
              {stats.coverage.minLon.toFixed(4)}° - {stats.coverage.maxLon.toFixed(4)}°
            </p>
          </div>
        </div>
      </div>
    {/if}
  {/if}
</div>
