<script lang="ts">
  import Icon from '@iconify/svelte';
  import { scrapingStatusStore } from '../stores';
  
  $: moovit = $scrapingStatusStore.moovit;
  $: redCL = $scrapingStatusStore.redCL;
  
  function getStatusIcon(status: string) {
    switch (status) {
      case 'idle': return 'lucide:check-circle';
      case 'running': return 'lucide:loader';
      case 'error': return 'lucide:alert-circle';
      default: return 'lucide:check-circle';
    }
  }
  
  function getStatusColor(status: string) {
    switch (status) {
      case 'idle': return 'text-green-400';
      case 'running': return 'text-blue-400 animate-spin';
      case 'error': return 'text-red-400';
      default: return 'text-gray-400';
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

<div class="bg-black/40 backdrop-blur-xl border border-white/10 rounded-lg overflow-hidden shadow-2xl">
  <div class="px-4 py-3 border-b border-white/10 bg-gradient-to-r from-gray-900/50 to-transparent">
    <div class="flex items-center gap-2">
      <Icon icon="lucide:globe" class="w-5 h-5 text-primary" />
      <h2 class="text-lg font-semibold text-white">Scraping</h2>
    </div>
  </div>
  
  <div class="p-4 space-y-3">
    <!-- Moovit -->
    <div class="p-3 bg-secondary/30 rounded-lg border border-border">
      <div class="flex items-center justify-between mb-2">
        <span class="text-sm font-medium text-foreground">Moovit</span>
        <Icon 
          icon={getStatusIcon(moovit.status)} 
          class="w-4 h-4 {getStatusColor(moovit.status)}"
        />
      </div>
      <div class="space-y-1 text-xs text-muted-foreground">
        <div class="flex justify-between">
          <span>Estado:</span>
          <span class="text-foreground font-medium capitalize">{moovit.status}</span>
        </div>
        <div class="flex justify-between">
          <span>Última ejecución:</span>
          <span class="text-foreground">{formatLastRun(moovit.lastRun)}</span>
        </div>
        {#if moovit.itemsProcessed > 0}
          <div class="flex justify-between">
            <span>Procesados:</span>
            <span class="text-foreground">{moovit.itemsProcessed}</span>
          </div>
        {/if}
        {#if moovit.errors > 0}
          <div class="flex justify-between">
            <span>Errores:</span>
            <span class="text-red-400">{moovit.errors}</span>
          </div>
        {/if}
      </div>
    </div>
    
    <!-- Red CL -->
    <div class="p-3 bg-secondary/30 rounded-lg border border-border">
      <div class="flex items-center justify-between mb-2">
        <span class="text-sm font-medium text-foreground">Red CL</span>
        <Icon 
          icon={getStatusIcon(redCL.status)} 
          class="w-4 h-4 {getStatusColor(redCL.status)}"
        />
      </div>
      <div class="space-y-1 text-xs text-muted-foreground">
        <div class="flex justify-between">
          <span>Estado:</span>
          <span class="text-foreground font-medium capitalize">{redCL.status}</span>
        </div>
        <div class="flex justify-between">
          <span>Última ejecución:</span>
          <span class="text-foreground">{formatLastRun(redCL.lastRun)}</span>
        </div>
        {#if redCL.itemsProcessed > 0}
          <div class="flex justify-between">
            <span>Procesados:</span>
            <span class="text-foreground">{redCL.itemsProcessed}</span>
          </div>
        {/if}
        {#if redCL.errors > 0}
          <div class="flex justify-between">
            <span>Errores:</span>
            <span class="text-red-400">{redCL.errors}</span>
          </div>
        {/if}
      </div>
    </div>
  </div>
</div>
