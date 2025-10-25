<script lang="ts">
  import { apiStatusStore } from '../stores';
  import Icon from '@iconify/svelte';
  
  $: backend = $apiStatusStore.backend;
  $: graphhopper = $apiStatusStore.graphhopper;
  $: database = $apiStatusStore.database;
  
  function getStatusColor(status: string) {
    switch (status) {
      case 'online': return 'text-green-400 fill-green-400';
      case 'degraded': return 'text-yellow-400 fill-yellow-400';
      case 'offline': return 'text-red-400 fill-red-400';
      default: return 'text-gray-400 fill-gray-400';
    }
  }
  
  function formatUptime(seconds: number) {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    return `${hours}h ${minutes}m`;
  }
</script>

<div class="bg-black/40 backdrop-blur-xl border border-white/10 rounded-lg overflow-hidden shadow-2xl">
  <div class="px-4 py-3 border-b border-white/10 bg-gradient-to-r from-gray-900/50 to-transparent">
    <div class="flex items-center gap-2">
      <Icon icon="lucide:server" class="w-5 h-5 text-primary" />
      <h2 class="text-lg font-semibold text-white">Estado de APIs</h2>
    </div>
  </div>
  
  <div class="p-4 space-y-3">
    <!-- Backend -->
    <div class="p-3 bg-white/5 backdrop-blur-sm rounded-lg border border-white/10">
      <div class="flex items-center justify-between mb-2">
        <div class="flex items-center gap-2">
          <Icon icon="lucide:server" class="w-4 h-4 text-primary" />
          <span class="text-sm font-medium text-foreground">Backend</span>
        </div>
        <Icon icon="lucide:circle" class="w-3 h-3 {getStatusColor(backend.status)} pulse-dot" />
      </div>
      <div class="space-y-1 text-xs text-muted-foreground">
        <div class="flex justify-between">
          <span>Estado:</span>
          <span class="text-foreground font-medium">{backend.status}</span>
        </div>
        {#if backend.status === 'online'}
          <div class="flex justify-between">
            <span>Respuesta:</span>
            <span class="text-foreground">{backend.responseTime}ms</span>
          </div>
          <div class="flex justify-between">
            <span>Uptime:</span>
            <span class="text-foreground">{formatUptime(backend.uptime)}</span>
          </div>
          <div class="flex justify-between">
            <span>Version:</span>
            <span class="text-foreground">{backend.version}</span>
          </div>
        {/if}
      </div>
    </div>
    
    <!-- GraphHopper -->
    <div class="p-3 bg-secondary/30 rounded-lg border border-border">
      <div class="flex items-center justify-between mb-2">
        <div class="flex items-center gap-2">
          <Icon icon="lucide:map-pin" class="w-4 h-4 text-cyan-400" />
          <span class="text-sm font-medium text-foreground">GraphHopper</span>
        </div>
        <Icon icon="lucide:circle" class="w-3 h-3 {getStatusColor(graphhopper.status)} pulse-dot" />
      </div>
      <div class="space-y-1 text-xs text-muted-foreground">
        <div class="flex justify-between">
          <span>Estado:</span>
          <span class="text-foreground font-medium">{graphhopper.status}</span>
        </div>
        {#if graphhopper.status === 'online'}
          <div class="flex justify-between">
            <span>Respuesta:</span>
            <span class="text-foreground">{graphhopper.responseTime}ms</span>
          </div>
        {/if}
      </div>
    </div>
    
    <!-- Database -->
    <div class="p-3 bg-secondary/30 rounded-lg border border-border">
      <div class="flex items-center justify-between mb-2">
        <div class="flex items-center gap-2">
          <Icon icon="lucide:database" class="w-4 h-4 text-purple-400" />
          <span class="text-sm font-medium text-foreground">Database</span>
        </div>
        <Icon icon="lucide:circle" class="w-3 h-3 {getStatusColor(database.status)} pulse-dot" />
      </div>
      <div class="space-y-1 text-xs text-muted-foreground">
        <div class="flex justify-between">
          <span>Estado:</span>
          <span class="text-foreground font-medium">{database.status}</span>
        </div>
        {#if database.status === 'online'}
          <div class="flex justify-between">
            <span>Conexiones:</span>
            <span class="text-foreground">
              {database.connections}/{database.maxConnections}
            </span>
          </div>
          <div class="mt-2">
            <div class="w-full bg-secondary rounded-full h-1.5">
              <div 
                class="bg-primary h-1.5 rounded-full transition-all" 
                style="width: {(database.connections / database.maxConnections) * 100}%"
              ></div>
            </div>
          </div>
        {/if}
      </div>
    </div>
  </div>
</div>
