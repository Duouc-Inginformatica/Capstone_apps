<script lang="ts">
  import { apiStatusStore } from '../stores/index.svelte';
  import Icon from '@iconify/svelte';
  
  function getStatusColor(status: string) {
    switch (status) {
      case 'online': return 'text-emerald-400';
      case 'degraded': return 'text-amber-400';
      case 'offline': return 'text-rose-400';
      default: return 'text-gray-400';
    }
  }
  
  function getStatusGlow(status: string) {
    switch (status) {
      case 'online': return 'shadow-emerald-500/50';
      case 'degraded': return 'shadow-amber-500/50';
      case 'offline': return 'shadow-rose-500/50';
      default: return 'shadow-gray-500/30';
    }
  }
  
  function getStatusGradient(status: string) {
    switch (status) {
      case 'online': return 'from-emerald-500 to-green-500';
      case 'degraded': return 'from-amber-500 to-yellow-500';
      case 'offline': return 'from-rose-500 to-red-500';
      default: return 'from-gray-500 to-slate-500';
    }
  }
  
  function formatUptime(seconds: number) {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    return `${hours}h ${minutes}m`;
  }
</script>

<div class="neomorphic overflow-hidden">
  <div class="px-6 py-4 border-b border-white/5 bg-gradient-to-r from-background/30 via-background/20 to-transparent">
    <div class="flex items-center gap-3">
      <div class="p-2 rounded-xl bg-gradient-to-br from-cyan-500/20 to-blue-500/20 shadow-lg">
        <Icon icon="lucide:server" class="w-5 h-5 text-cyan-400" />
      </div>
      <h2 class="text-lg font-bold gradient-text">Estado de APIs</h2>
    </div>
  </div>
  
  <div class="p-4 space-y-3">
    <!-- Backend -->
    <div class="neomorphic-inset rounded-2xl p-4 card-hover relative overflow-hidden group">
      <div class="absolute inset-0 bg-gradient-to-br from-primary/10 to-secondary/10 opacity-0 group-hover:opacity-100 transition-opacity"></div>
      
      <div class="relative">
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-3">
            <div class="p-2 rounded-xl bg-gradient-to-br from-primary/20 to-secondary/20">
              <Icon icon="lucide:server" class="w-5 h-5 text-primary" />
            </div>
            <span class="text-sm font-bold text-white">Backend Server</span>
          </div>
          <div class="relative">
            <div class="absolute inset-0 bg-gradient-to-r {getStatusGradient(apiStatusStore.backend.status)} rounded-full blur-md {getStatusGlow(apiStatusStore.backend.status)} pulse-soft"></div>
            <Icon icon="lucide:circle" class="relative w-3 h-3 {getStatusColor(apiStatusStore.backend.status)} fill-current" />
          </div>
        </div>
        
        <div class="space-y-2 text-xs">
          <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
            <span class="text-muted-foreground">Estado</span>
            <span class="text-white font-semibold capitalize">{apiStatusStore.backend.status}</span>
          </div>
          {#if apiStatusStore.backend.status === 'online'}
            <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
              <span class="text-muted-foreground">Respuesta</span>
              <span class="text-primary font-mono font-bold">{apiStatusStore.backend.responseTime}ms</span>
            </div>
            <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
              <span class="text-muted-foreground">Uptime</span>
              <span class="text-emerald-400 font-semibold">{formatUptime(apiStatusStore.backend.uptime)}</span>
            </div>
            <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
              <span class="text-muted-foreground">Version</span>
              <span class="text-white font-mono">{apiStatusStore.backend.version}</span>
            </div>
          {/if}
        </div>
      </div>
    </div>
    
    <!-- GraphHopper -->
    <div class="neomorphic-inset rounded-2xl p-4 card-hover relative overflow-hidden group">
      <div class="absolute inset-0 bg-gradient-to-br from-cyan-500/10 to-blue-500/10 opacity-0 group-hover:opacity-100 transition-opacity"></div>
      
      <div class="relative">
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-3">
            <div class="p-2 rounded-xl bg-gradient-to-br from-cyan-500/20 to-blue-500/20">
              <Icon icon="lucide:map-pin" class="w-5 h-5 text-cyan-400" />
            </div>
            <span class="text-sm font-bold text-white">GraphHopper</span>
          </div>
          <div class="relative">
            <div class="absolute inset-0 bg-gradient-to-r {getStatusGradient(apiStatusStore.graphhopper.status)} rounded-full blur-md {getStatusGlow(apiStatusStore.graphhopper.status)} pulse-soft"></div>
            <Icon icon="lucide:circle" class="relative w-3 h-3 {getStatusColor(apiStatusStore.graphhopper.status)} fill-current" />
          </div>
        </div>
        
        <div class="space-y-2 text-xs">
          <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
            <span class="text-muted-foreground">Estado</span>
            <span class="text-white font-semibold capitalize">{apiStatusStore.graphhopper.status}</span>
          </div>
          {#if apiStatusStore.graphhopper.status === 'online'}
            <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
              <span class="text-muted-foreground">Respuesta</span>
              <span class="text-cyan-400 font-mono font-bold">{apiStatusStore.graphhopper.responseTime}ms</span>
            </div>
          {/if}
        </div>
      </div>
    </div>
    
    <!-- Database -->
    <div class="neomorphic-inset rounded-2xl p-4 card-hover relative overflow-hidden group">
      <div class="absolute inset-0 bg-gradient-to-br from-purple-500/10 to-pink-500/10 opacity-0 group-hover:opacity-100 transition-opacity"></div>
      
      <div class="relative">
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-3">
            <div class="p-2 rounded-xl bg-gradient-to-br from-purple-500/20 to-pink-500/20">
              <Icon icon="lucide:database" class="w-5 h-5 text-purple-400" />
            </div>
            <span class="text-sm font-bold text-white">PostgreSQL</span>
          </div>
          <div class="relative">
            <div class="absolute inset-0 bg-gradient-to-r {getStatusGradient(apiStatusStore.database.status)} rounded-full blur-md {getStatusGlow(apiStatusStore.database.status)} pulse-soft"></div>
            <Icon icon="lucide:circle" class="relative w-3 h-3 {getStatusColor(apiStatusStore.database.status)} fill-current" />
          </div>
        </div>
        
        <div class="space-y-2 text-xs">
          <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
            <span class="text-muted-foreground">Estado</span>
            <span class="text-white font-semibold capitalize">{apiStatusStore.database.status}</span>
          </div>
          {#if apiStatusStore.database.status === 'online'}
            <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
              <span class="text-muted-foreground">Conexiones</span>
              <span class="text-purple-400 font-mono font-bold">
                {apiStatusStore.database.connections}/{apiStatusStore.database.maxConnections}
              </span>
            </div>
            <div class="neomorphic-inset rounded-lg px-3 py-2">
              <div class="flex justify-between items-center mb-2">
                <span class="text-muted-foreground">Pool Usage</span>
                <span class="text-primary font-semibold">
                  {Math.round((apiStatusStore.database.connections / apiStatusStore.database.maxConnections) * 100)}%
                </span>
              </div>
              <div class="relative w-full h-2 neomorphic-inset rounded-full overflow-hidden">
                <div 
                  class="absolute top-0 left-0 h-full bg-gradient-to-r from-purple-500 to-pink-500 rounded-full transition-all duration-500 shadow-lg shadow-purple-500/50" 
                  style="width: {(apiStatusStore.database.connections / apiStatusStore.database.maxConnections) * 100}%"
                ></div>
              </div>
            </div>
          {/if}
        </div>
      </div>
    </div>
  </div>
</div>
