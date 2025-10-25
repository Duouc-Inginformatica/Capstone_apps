<script lang="ts">
  import { apiStatusStore } from '../stores';
  import Icon from '@iconify/svelte';
  
  $: backend = $apiStatusStore.backend;
  $: graphhopper = $apiStatusStore.graphhopper;
  $: database = $apiStatusStore.database;
  
  function getStatusColor(status: string) {
    switch (status) {
      case 'online': return 'bg-green-500';
      case 'degraded': return 'bg-yellow-500';
      case 'offline': return 'bg-red-500';
      default: return 'bg-gray-500';
    }
  }
</script>

<div class="border-b border-white/10 bg-black/30 backdrop-blur-lg px-6 py-2">
  <div class="flex items-center gap-6 text-sm">
    <!-- Backend Status -->
    <div class="flex items-center gap-2">
      <Icon 
        icon="lucide:circle"
        class="{getStatusColor(backend.status)} w-2 h-2 fill-current pulse-dot" 
      />
      <span class="text-gray-400">Backend:</span>
      <span class="text-white font-medium">{backend.status}</span>
      {#if backend.status === 'online'}
        <span class="text-gray-500 text-xs">({backend.responseTime}ms)</span>
      {/if}
    </div>
    
    <!-- GraphHopper Status -->
    <div class="flex items-center gap-2">
      <Icon 
        icon="lucide:circle"
        class="{getStatusColor(graphhopper.status)} w-2 h-2 fill-current pulse-dot" 
      />
      <span class="text-gray-400">GraphHopper:</span>
      <span class="text-white font-medium">{graphhopper.status}</span>
      {#if graphhopper.status === 'online'}
        <span class="text-gray-500 text-xs">({graphhopper.responseTime}ms)</span>
      {/if}
    </div>
    
    <!-- Database Status -->
    <div class="flex items-center gap-2">
      <Icon 
        icon="lucide:circle"
        class="{getStatusColor(database.status)} w-2 h-2 fill-current pulse-dot" 
      />
      <span class="text-gray-400">Database:</span>
      <span class="text-white font-medium">{database.status}</span>
      {#if database.status === 'online'}
        <span class="text-gray-500 text-xs">
          ({database.connections}/{database.maxConnections} connections)
        </span>
      {/if}
    </div>
  </div>
</div>
