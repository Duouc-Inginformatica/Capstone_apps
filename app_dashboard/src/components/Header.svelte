<script lang="ts">
  import Icon from '@iconify/svelte';
  import { apiStatusStore } from '../stores/index.svelte';
  import { version } from '../../package.json';
  
  let currentTime = $state(new Date());
  
  $effect(() => {
    const interval = setInterval(() => {
      currentTime = new Date();
    }, 1000);
    
    return () => clearInterval(interval);
  });
  
  function formatTime(date: Date) {
    return date.toLocaleTimeString('es-CL', { 
      hour: '2-digit', 
      minute: '2-digit',
      second: '2-digit'
    });
  }
  
  function formatDate(date: Date) {
    return date.toLocaleDateString('es-CL', { 
      weekday: 'long',
      year: 'numeric',
      month: 'long',
      day: 'numeric'
    });
  }
  
  function getStatusColor(status: string) {
    switch (status) {
      case 'online': return 'from-emerald-400 to-green-500';
      case 'degraded': return 'from-amber-400 to-orange-500';
      case 'offline': return 'from-red-400 to-rose-500';
      default: return 'from-gray-400 to-gray-500';
    }
  }
  
  function getStatusTextColor(status: string) {
    switch (status) {
      case 'online': return 'text-emerald-300';
      case 'degraded': return 'text-amber-300';
      case 'offline': return 'text-red-300';
      default: return 'text-gray-300';
    }
  }
  
  function getStatusIcon(status: string) {
    switch (status) {
      case 'online': return 'lucide:check-circle-2';
      case 'degraded': return 'lucide:alert-triangle';
      case 'offline': return 'lucide:x-circle';
      default: return 'lucide:circle';
    }
  }
</script>

<header class="neomorphic border-b border-white/10 px-6 py-4">
  <div class="flex items-center justify-between gap-6">
    <!-- Logo y Título -->
    <div class="flex items-center gap-4">
      <div class="relative group">
        <div class="absolute inset-0 bg-gradient-to-br from-blue-400 to-purple-500 rounded-2xl blur-lg opacity-30 group-hover:opacity-50 transition-opacity"></div>
        <div class="relative w-12 h-12 bg-gradient-to-br from-gray-800 to-gray-900 rounded-2xl flex items-center justify-center shadow-lg p-1.5 neomorphic">
          <img src="/assets/icons.svg" alt="WayFindCL" class="w-full h-full object-contain" />
        </div>
      </div>
      <div>
        <h1 class="text-2xl font-bold gradient-text">
          WayFindCL Dashboard
        </h1>
        <p class="text-sm text-muted-foreground mt-0.5">
          Sistema de Monitoreo en Tiempo Real
        </p>
      </div>
    </div>
    
    <!-- Indicadores de Estado -->
    <div class="flex items-center gap-3 flex-1 justify-center">
      <!-- Backend Status -->
      <div class="neomorphic-inset px-3 py-1.5 rounded-full flex items-center gap-2 card-hover">
        <div class="relative">
          <div class="absolute inset-0 bg-gradient-to-r {getStatusColor(apiStatusStore.backend.status)} rounded-full blur-md opacity-75"></div>
          <Icon
            icon={getStatusIcon(apiStatusStore.backend.status)}
            class="relative w-3.5 h-3.5 {getStatusTextColor(apiStatusStore.backend.status)} {apiStatusStore.backend.status === 'online' ? 'pulse-soft' : ''}"
          />
        </div>
        <div class="flex items-center gap-1.5">
          <span class="text-xs text-muted-foreground font-medium">Backend</span>
          <span class="text-xs {getStatusTextColor(apiStatusStore.backend.status)} font-semibold capitalize">{apiStatusStore.backend.status}</span>
          {#if apiStatusStore.backend.status === 'online'}
            <span class="text-xs text-gray-400 font-mono">{apiStatusStore.backend.responseTime}ms</span>
          {/if}
        </div>
      </div>

      <!-- GraphHopper Status -->
      <div class="neomorphic-inset px-3 py-1.5 rounded-full flex items-center gap-2 card-hover">
        <div class="relative">
          <div class="absolute inset-0 bg-gradient-to-r {getStatusColor(apiStatusStore.graphhopper.status)} rounded-full blur-md opacity-75"></div>
          <Icon
            icon={getStatusIcon(apiStatusStore.graphhopper.status)}
            class="relative w-3.5 h-3.5 {getStatusTextColor(apiStatusStore.graphhopper.status)} {apiStatusStore.graphhopper.status === 'online' ? 'pulse-soft' : ''}"
          />
        </div>
        <div class="flex items-center gap-1.5">
          <span class="text-xs text-muted-foreground font-medium">GraphHopper</span>
          <span class="text-xs {getStatusTextColor(apiStatusStore.graphhopper.status)} font-semibold capitalize">{apiStatusStore.graphhopper.status}</span>
          {#if apiStatusStore.graphhopper.status === 'online'}
            <span class="text-xs text-gray-400 font-mono">{apiStatusStore.graphhopper.responseTime}ms</span>
          {/if}
        </div>
      </div>

      <!-- Database Status -->
      <div class="neomorphic-inset px-3 py-1.5 rounded-full flex items-center gap-2 card-hover">
        <div class="relative">
          <div class="absolute inset-0 bg-gradient-to-r {getStatusColor(apiStatusStore.database.status)} rounded-full blur-md opacity-75"></div>
          <Icon
            icon={getStatusIcon(apiStatusStore.database.status)}
            class="relative w-3.5 h-3.5 {getStatusTextColor(apiStatusStore.database.status)} {apiStatusStore.database.status === 'online' ? 'pulse-soft' : ''}"
          />
        </div>
        <div class="flex items-center gap-1.5">
          <span class="text-xs text-muted-foreground font-medium">Database</span>
          <span class="text-xs {getStatusTextColor(apiStatusStore.database.status)} font-semibold capitalize">{apiStatusStore.database.status}</span>
          {#if apiStatusStore.database.status === 'online'}
            <span class="text-xs text-gray-400 font-mono">
              {apiStatusStore.database.connections}/{apiStatusStore.database.maxConnections}
            </span>
          {/if}
        </div>
      </div>
    </div>
    
    <!-- Info y Controles -->
    <div class="flex items-center gap-4">
      <!-- Reloj -->
      <div class="neomorphic-inset px-4 py-2 rounded-xl">
        <div class="flex flex-col items-end">
          <div class="text-lg font-bold text-white font-mono">
            {formatTime(currentTime)}
          </div>
          <div class="text-xs text-muted-foreground capitalize">
            {formatDate(currentTime).split(',')[0]}
          </div>
        </div>
      </div>
      
      <!-- Version Badge -->
      <div class="neomorphic-inset px-3 py-2 rounded-lg">
        <div class="flex items-center gap-2">
          <Icon icon="lucide:code-2" class="w-4 h-4 text-gray-400" />
          <span class="text-sm font-medium text-white">v{version}</span>
        </div>
      </div>
    </div>
  </div>
</header>
