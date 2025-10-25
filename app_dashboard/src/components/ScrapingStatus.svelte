<script lang="ts">
  import Icon from '@iconify/svelte';
  import { scrapingStatusStore } from '../stores/index.svelte';

  function getStatusIcon(status: string) {
    switch (status) {
      case 'idle': return 'lucide:check-circle-2';
      case 'running': return 'lucide:loader-2';
      case 'error': return 'lucide:alert-triangle';
      default: return 'lucide:circle';
    }
  }

  function getStatusColor(status: string) {
    switch (status) {
      case 'idle': return 'text-gray-400';
      case 'running': return 'text-emerald-400 animate-spin';
      case 'error': return 'text-red-400';
      default: return 'text-gray-400';
    }
  }
  
  function getStatusGlow(status: string) {
    switch (status) {
      case 'idle': return 'shadow-gray-400/30';
      case 'running': return 'shadow-emerald-400/30';
      case 'error': return 'shadow-red-400/30';
      default: return 'shadow-gray-400/30';
    }
  }

  function formatLastRun(timestamp: number) {
    if (timestamp === 0) return 'Nunca';
    const now = Date.now();
    const diff = now - timestamp;
    const minutes = Math.floor(diff / 60000);
    if (minutes < 1) return 'Hace un momento';
    if (minutes < 60) return `Hace ${minutes}m`;
    const hours = Math.floor(minutes / 60);
    return `Hace ${hours}h ${minutes % 60}m`;
  }
</script>

<div class="bg-gray-800/50 backdrop-blur-sm border border-gray-700/50 rounded-lg overflow-hidden hover:border-gray-600/50 transition-all duration-300">
  <div class="px-6 py-4 border-b border-gray-700/30">
    <div class="flex items-center gap-3">
      <div class="p-2 rounded-lg bg-gray-700/50">
        <Icon icon="lucide:globe" class="w-5 h-5 text-gray-300" />
      </div>
      <h2 class="text-lg font-semibold text-white">Web Scraping</h2>
    </div>
  </div>

  <div class="p-4 space-y-3">
    <!-- Moovit -->
    <div class="bg-gray-900/50 rounded-lg p-4 border border-gray-700/30 hover:border-gray-600/50 transition-all duration-300">
      <div class="relative">
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-3">
            <div class="p-2 rounded-lg bg-gray-700/50">
              <Icon icon="lucide:bus" class="w-5 h-5 text-gray-300" />
            </div>
            <span class="text-sm font-semibold text-white">Moovit</span>
          </div>
          <Icon
            icon={getStatusIcon(scrapingStatusStore.moovit.status)}
            class="w-5 h-5 {getStatusColor(scrapingStatusStore.moovit.status)}"
          />
        </div>
        
        <div class="space-y-2 text-xs">
          <div class="flex justify-between items-center bg-gray-800/50 rounded-lg px-3 py-2 border border-gray-700/20">
            <span class="text-gray-400">Estado</span>
            <span class="text-white font-medium capitalize">{scrapingStatusStore.moovit.status}</span>
          </div>
          <div class="flex justify-between items-center bg-gray-800/50 rounded-lg px-3 py-2 border border-gray-700/20">
            <span class="text-gray-400">Última ejecución</span>
            <span class="text-gray-300 font-medium">{formatLastRun(scrapingStatusStore.moovit.lastRun)}</span>
          </div>
          {#if scrapingStatusStore.moovit.itemsProcessed > 0}
            <div class="flex justify-between items-center bg-gray-800/50 rounded-lg px-3 py-2 border border-gray-700/20">
              <span class="text-gray-400">Procesados</span>
              <span class="text-white font-medium font-mono">{scrapingStatusStore.moovit.itemsProcessed.toLocaleString()}</span>
            </div>
          {/if}
          {#if scrapingStatusStore.moovit.errors > 0}
            <div class="flex justify-between items-center bg-gray-800/50 rounded-lg px-3 py-2 border border-gray-700/20">
              <span class="text-gray-400">Errores</span>
              <span class="text-red-400 font-medium font-mono">{scrapingStatusStore.moovit.errors}</span>
            </div>
          {/if}
        </div>
      </div>
    </div>

    <!-- Red CL -->
    <div class="bg-gray-900/50 rounded-lg p-4 border border-gray-700/30 hover:border-gray-600/50 transition-all duration-300">
      <div class="relative">
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-3">
            <div class="p-2 rounded-lg bg-gray-700/50">
              <Icon icon="lucide:train-front" class="w-5 h-5 text-gray-300" />
            </div>
            <span class="text-sm font-semibold text-white">Red CL</span>
          </div>
          <Icon
            icon={getStatusIcon(scrapingStatusStore.redCL.status)}
            class="w-5 h-5 {getStatusColor(scrapingStatusStore.redCL.status)}"
          />
        </div>
        
        <div class="space-y-2 text-xs">
          <div class="flex justify-between items-center bg-gray-800/50 rounded-lg px-3 py-2 border border-gray-700/20">
            <span class="text-gray-400">Estado</span>
            <span class="text-white font-medium capitalize">{scrapingStatusStore.redCL.status}</span>
          </div>
          <div class="flex justify-between items-center bg-gray-800/50 rounded-lg px-3 py-2 border border-gray-700/20">
            <span class="text-gray-400">Última ejecución</span>
            <span class="text-gray-300 font-medium">{formatLastRun(scrapingStatusStore.redCL.lastRun)}</span>
          </div>
          {#if scrapingStatusStore.redCL.itemsProcessed > 0}
            <div class="flex justify-between items-center bg-gray-800/50 rounded-lg px-3 py-2 border border-gray-700/20">
              <span class="text-gray-400">Procesados</span>
              <span class="text-white font-medium font-mono">{scrapingStatusStore.redCL.itemsProcessed.toLocaleString()}</span>
            </div>
          {/if}
          {#if scrapingStatusStore.redCL.errors > 0}
            <div class="flex justify-between items-center bg-gray-800/50 rounded-lg px-3 py-2 border border-gray-700/20">
              <span class="text-gray-400">Errores</span>
              <span class="text-red-400 font-medium font-mono">{scrapingStatusStore.redCL.errors}</span>
            </div>
          {/if}
        </div>
      </div>
    </div>
  </div>
</div>
