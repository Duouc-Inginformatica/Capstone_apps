<script lang="ts">
  import { onMount } from 'svelte';
  import Icon from '@iconify/svelte';
  import { metricsStore } from '../stores/index.svelte';
  
  async function fetchMetrics() {
    try {
      const response = await fetch('http://localhost:8080/api/stats/metrics');
      if (response.ok) {
        const data = await response.json();
        
        // Actualizar el store con datos reales
        metricsStore[0].value = Math.round(data.cpuUsage);
        metricsStore[1].value = data.memoryUsage;
        metricsStore[2].value = data.activeUsers;
        metricsStore[3].value = data.requestsPerMin;
        
        // Actualizar tendencias basado en valores
        metricsStore[0].trend = data.cpuUsage > 70 ? 'up' : data.cpuUsage < 30 ? 'down' : 'stable';
        metricsStore[1].trend = data.memoryUsage > 512 ? 'up' : 'stable';
        metricsStore[2].trend = data.activeUsers > 0 ? 'up' : 'stable';
        metricsStore[3].trend = data.requestsPerMin > 50 ? 'up' : 'stable';
      }
    } catch (error) {
      console.error('Error fetching metrics:', error);
    }
  }
  
  onMount(() => {
    // Fetch inicial
    fetchMetrics();
    
    // Actualizar cada 5 segundos
    const interval = setInterval(fetchMetrics, 5000);
    
    return () => clearInterval(interval);
  });
  
  function getTrendIcon(trend?: string) {
    switch (trend) {
      case 'up': return 'lucide:trending-up';
      case 'down': return 'lucide:trending-down';
      default: return 'lucide:minus';
    }
  }
  
  function getTrendColor(trend?: string) {
    switch (trend) {
      case 'up': return 'text-emerald-400';
      case 'down': return 'text-rose-400';
      default: return 'text-gray-400';
    }
  }
  
  function getTrendGlow(trend?: string) {
    switch (trend) {
      case 'up': return 'shadow-emerald-500/30';
      case 'down': return 'shadow-rose-500/30';
      default: return 'shadow-gray-500/20';
    }
  }
  
  function getMetricIcon(index: number) {
    const icons = [
      'lucide:zap',
      'lucide:cpu',
      'lucide:hard-drive',
      'lucide:network',
      'lucide:clock',
      'lucide:users'
    ];
    return icons[index % icons.length];
  }
  
  function getMetricGradient(index: number) {
    const gradients = [
      'from-gray-300/20 to-gray-400/20',
      'from-gray-400/20 to-gray-500/20',
      'from-gray-350/20 to-gray-450/20',
      'from-gray-320/20 to-gray-420/20',
      'from-gray-380/20 to-gray-480/20',
      'from-gray-340/20 to-gray-440/20'
    ];
    return gradients[index % gradients.length];
  }
</script>

<div class="neomorphic overflow-hidden">
  <div class="px-6 py-4 border-b border-white/5 bg-gradient-to-r from-background/30 via-background/20 to-transparent">
    <div class="flex items-center gap-3">
      <div class="p-2 rounded-xl bg-gradient-to-br from-gray-400/20 to-gray-500/20 shadow-lg">
        <Icon icon="lucide:activity" class="w-5 h-5 text-gray-300" />
      </div>
      <h2 class="text-lg font-bold gradient-text">Métricas del Sistema</h2>
    </div>
  </div>
  
  <div class="p-4 grid grid-cols-2 gap-3">
    {#each metricsStore as metric, index}
      <div class="neomorphic-inset rounded-2xl p-4 card-hover group relative overflow-hidden">
        <!-- Gradient Background -->
        <div class="absolute inset-0 bg-gradient-to-br {getMetricGradient(index)} opacity-0 group-hover:opacity-100 transition-opacity duration-500"></div>
        
        <div class="relative flex items-start justify-between">
          <div class="flex-1">
            <div class="flex items-center gap-2 mb-2">
              <div class="p-1.5 rounded-lg bg-gradient-to-br {getMetricGradient(index)}">
                <Icon icon={getMetricIcon(index)} class="w-4 h-4 text-white" />
              </div>
              <p class="text-xs text-muted-foreground font-medium uppercase tracking-wide">{metric.name}</p>
            </div>
            <p class="text-2xl font-bold text-white mb-1">
              {metric.value}<span class="text-sm text-gray-400 ml-1">{metric.unit || ''}</span>
            </p>
          </div>
          
          {#if metric.trend}
            <div class="flex flex-col items-end gap-1">
              <Icon 
                icon={getTrendIcon(metric.trend)} 
                class="w-5 h-5 {getTrendColor(metric.trend)} drop-shadow-lg {getTrendGlow(metric.trend)} pulse-soft"
              />
            </div>
          {/if}
        </div>
      </div>
    {/each}
  </div>
</div>
