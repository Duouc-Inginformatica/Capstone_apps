<script lang="ts">
  import { apiStatusStore } from '../stores';
  import Icon from '@iconify/svelte';

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
        class="{getStatusColor(apiStatusStore.backend.status)} w-2 h-2 fill-current pulse-dot"
      />
      <span class="text-gray-400">Backend:</span>
      <span class="text-white font-medium">{apiStatusStore.backend.status}</span>
      {#if apiStatusStore.backend.status === 'online'}
        <span class="text-gray-500 text-xs">({apiStatusStore.backend.responseTime}ms)</span>
      {/if}
    </div>

    <!-- GraphHopper Status -->
    <div class="flex items-center gap-2">
      <Icon
        icon="lucide:circle"
        class="{getStatusColor(apiStatusStore.graphhopper.status)} w-2 h-2 fill-current pulse-dot"
      />
      <span class="text-gray-400">GraphHopper:</span>
      <span class="text-white font-medium">{apiStatusStore.graphhopper.status}</span>
      {#if apiStatusStore.graphhopper.status === 'online'}
        <span class="text-gray-500 text-xs">({apiStatusStore.graphhopper.responseTime}ms)</span>
      {/if}
    </div>

    <!-- Database Status -->
    <div class="flex items-center gap-2">
      <Icon
        icon="lucide:circle"
        class="{getStatusColor(apiStatusStore.database.status)} w-2 h-2 fill-current pulse-dot"
      />
      <span class="text-gray-400">Database:</span>
      <span class="text-white font-medium">{apiStatusStore.database.status}</span>
      {#if apiStatusStore.database.status === 'online'}
        <span class="text-gray-500 text-xs">
          ({apiStatusStore.database.connections}/{apiStatusStore.database.maxConnections} connections)
        </span>
      {/if}
    </div>
  </div>
</div>
