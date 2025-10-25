<script lang="ts">
  import { apiStatusStore } from '../stores/index.svelte';
  import Icon from '@iconify/svelte';

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

<div class="border-b border-white/5 px-6 py-3 bg-gradient-to-r from-background/80 to-background/50 backdrop-blur-xl">
  <div class="flex items-center gap-4">
    <!-- Backend Status -->
    <div class="neomorphic-inset px-4 py-2 rounded-full flex items-center gap-2.5 card-hover">
      <div class="relative">
        <div class="absolute inset-0 bg-gradient-to-r {getStatusColor(apiStatusStore.backend.status)} rounded-full blur-md opacity-75"></div>
        <Icon
          icon="{getStatusIcon(apiStatusStore.backend.status)}"
          class="relative w-4 h-4 {getStatusTextColor(apiStatusStore.backend.status)} {apiStatusStore.backend.status === 'online' ? 'pulse-soft' : ''}"
        />
      </div>
      <div class="flex items-center gap-2">
        <span class="text-xs text-muted-foreground font-medium">Backend</span>
        <span class="text-xs {getStatusTextColor(apiStatusStore.backend.status)} font-semibold capitalize">{apiStatusStore.backend.status}</span>
        {#if apiStatusStore.backend.status === 'online'}
          <span class="text-xs text-gray-400 font-mono">{apiStatusStore.backend.responseTime}ms</span>
        {/if}
      </div>
    </div>

    <!-- GraphHopper Status -->
    <div class="neomorphic-inset px-4 py-2 rounded-full flex items-center gap-2.5 card-hover">
      <div class="relative">
        <div class="absolute inset-0 bg-gradient-to-r {getStatusColor(apiStatusStore.graphhopper.status)} rounded-full blur-md opacity-75"></div>
        <Icon
          icon="{getStatusIcon(apiStatusStore.graphhopper.status)}"
          class="relative w-4 h-4 {getStatusTextColor(apiStatusStore.graphhopper.status)} {apiStatusStore.graphhopper.status === 'online' ? 'pulse-soft' : ''}"
        />
      </div>
      <div class="flex items-center gap-2">
        <span class="text-xs text-muted-foreground font-medium">GraphHopper</span>
        <span class="text-xs {getStatusTextColor(apiStatusStore.graphhopper.status)} font-semibold capitalize">{apiStatusStore.graphhopper.status}</span>
        {#if apiStatusStore.graphhopper.status === 'online'}
          <span class="text-xs text-gray-400 font-mono">{apiStatusStore.graphhopper.responseTime}ms</span>
        {/if}
      </div>
    </div>

    <!-- Database Status -->
    <div class="neomorphic-inset px-4 py-2 rounded-full flex items-center gap-2.5 card-hover">
      <div class="relative">
        <div class="absolute inset-0 bg-gradient-to-r {getStatusColor(apiStatusStore.database.status)} rounded-full blur-md opacity-75"></div>
        <Icon
          icon="{getStatusIcon(apiStatusStore.database.status)}"
          class="relative w-4 h-4 {getStatusTextColor(apiStatusStore.database.status)} {apiStatusStore.database.status === 'online' ? 'pulse-soft' : ''}"
        />
      </div>
      <div class="flex items-center gap-2">
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
</div>
