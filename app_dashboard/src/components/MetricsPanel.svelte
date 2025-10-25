<script lang="ts">
  import Icon from '@iconify/svelte';
  import { metricsStore } from '../stores';
  
  function getTrendIcon(trend?: string) {
    switch (trend) {
      case 'up': return 'lucide:trending-up';
      case 'down': return 'lucide:trending-down';
      default: return 'lucide:minus';
    }
  }
  
  function getTrendColor(trend?: string) {
    switch (trend) {
      case 'up': return 'text-green-400';
      case 'down': return 'text-red-400';
      default: return 'text-gray-400';
    }
  }
</script>

<div class="bg-black/40 backdrop-blur-xl border border-white/10 rounded-lg overflow-hidden shadow-2xl">
  <div class="px-4 py-3 border-b border-white/10 bg-gradient-to-r from-gray-900/50 to-transparent">
    <div class="flex items-center gap-2">
      <Icon icon="lucide:activity" class="w-5 h-5 text-primary" />
      <h2 class="text-lg font-semibold text-white">Métricas</h2>
    </div>
  </div>
  
  <div class="p-4 space-y-3">
    {#each metricsStore as metric}
      <div class="flex items-center justify-between p-3 bg-white/5 backdrop-blur-sm rounded-lg border border-white/10">
        <div class="flex-1">
          <p class="text-xs text-gray-500 mb-1">{metric.name}</p>
          <p class="text-xl font-bold text-white">
            {metric.value}{metric.unit || ''}
          </p>
        </div>
        
        {#if metric.trend}
          <Icon 
            icon={getTrendIcon(metric.trend)} 
            class="w-5 h-5 {getTrendColor(metric.trend)}"
          />
        {/if}
      </div>
    {/each}
  </div>
</div>
