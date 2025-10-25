<script lang="ts">
  import { logsStore, clearLogs, type LogEntry } from '../stores';
  import Icon from '@iconify/svelte';
  import { Popover } from 'bits-ui';
  import { afterUpdate } from 'svelte';
  
  let searchTerm = '';
  let selectedSources: string[] = [];
  let selectedLevels: string[] = [];
  let autoScroll = true;
  let logsContainer: HTMLDivElement;
  
  $: filteredLogs = $logsStore.filter(log => {
    if (searchTerm && !log.message.toLowerCase().includes(searchTerm.toLowerCase())) {
      return false;
    }
    if (selectedSources.length > 0 && !selectedSources.includes(log.source)) {
      return false;
    }
    if (selectedLevels.length > 0 && !selectedLevels.includes(log.level)) {
      return false;
    }
    return true;
  });
  
  function getLevelColor(level: string) {
    switch (level) {
      case 'debug': return 'text-blue-400';
      case 'info': return 'text-green-400';
      case 'warn': return 'text-yellow-400';
      case 'error': return 'text-red-400';
      default: return 'text-gray-400';
    }
  }
  
  function getLevelBadgeColor(level: string) {
    switch (level) {
      case 'debug': return 'bg-blue-500/20 text-blue-400 border-blue-500/30';
      case 'info': return 'bg-green-500/20 text-green-400 border-green-500/30';
      case 'warn': return 'bg-yellow-500/20 text-yellow-400 border-yellow-500/30';
      case 'error': return 'bg-red-500/20 text-red-400 border-red-500/30';
      default: return 'bg-gray-500/20 text-gray-400 border-gray-500/30';
    }
  }
  
  function getSourceColor(source: string) {
    switch (source) {
      case 'backend': return 'bg-primary/20 text-primary border-primary/30';
      case 'frontend': return 'bg-purple-500/20 text-purple-400 border-purple-500/30';
      case 'graphhopper': return 'bg-cyan-500/20 text-cyan-400 border-cyan-500/30';
      case 'scraping': return 'bg-orange-500/20 text-orange-400 border-orange-500/30';
      default: return 'bg-gray-500/20 text-gray-400 border-gray-500/30';
    }
  }
  
  function formatTime(timestamp: number) {
    const date = new Date(timestamp);
    return date.toLocaleTimeString('es-CL', { 
      hour: '2-digit', 
      minute: '2-digit', 
      second: '2-digit',
      fractionalSecondDigits: 3
    });
  }
  
  function toggleSource(source: string) {
    if (selectedSources.includes(source)) {
      selectedSources = selectedSources.filter(s => s !== source);
    } else {
      selectedSources = [...selectedSources, source];
    }
  }
  
  function toggleLevel(level: string) {
    if (selectedLevels.includes(level)) {
      selectedLevels = selectedLevels.filter(l => l !== level);
    } else {
      selectedLevels = [...selectedLevels, level];
    }
  }
  
  afterUpdate(() => {
    if (autoScroll && logsContainer) {
      logsContainer.scrollTop = logsContainer.scrollHeight;
    }
  });
</script>

<div class="flex flex-col h-full bg-black/40 backdrop-blur-xl border border-white/10 rounded-lg overflow-hidden shadow-2xl">
  <!-- Header del panel -->
  <div class="flex items-center justify-between px-4 py-3 border-b border-white/10 bg-gradient-to-r from-gray-900/50 to-transparent">
    <div class="flex items-center gap-2">
      <Icon icon="lucide:terminal" class="w-5 h-5 text-primary" />
      <h2 class="text-lg font-semibold text-white">Logs en Tiempo Real</h2>
      <span class="text-xs text-gray-500">
        ({filteredLogs.length} de {$logsStore.length})
      </span>
    </div>
    
    <div class="flex items-center gap-2">
      <!-- Búsqueda -->
      <div class="relative">
        <Icon icon="lucide:search" class="absolute left-2 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-500" />
        <input
          type="text"
          placeholder="Buscar logs..."
          bind:value={searchTerm}
          class="pl-8 pr-3 py-1.5 text-sm bg-black/50 border border-white/10 rounded-md focus:outline-none focus:ring-2 focus:ring-primary/50 text-white placeholder:text-gray-600 w-64 backdrop-blur-sm"
        />
      </div>
      
      <!-- Filtros -->
      <Popover.Root>
        <Popover.Trigger 
          class="p-2 rounded-md hover:bg-white/5 border border-white/10 transition-colors backdrop-blur-sm"
        >
          <Icon icon="lucide:filter" class="w-4 h-4 text-gray-400" />
        </Popover.Trigger>
        <Popover.Content 
          class="z-50 w-72 p-4 bg-black/90 backdrop-blur-xl border border-white/20 rounded-lg shadow-2xl"
        >
          <div class="space-y-4">
            <div>
              <h3 class="text-sm font-medium text-white mb-2">Source</h3>
              <div class="flex flex-wrap gap-2">
                {#each ['backend', 'frontend', 'graphhopper', 'scraping'] as source}
                  <button
                    on:click={() => toggleSource(source)}
                    class="px-3 py-1 text-xs rounded-md border transition-colors {selectedSources.includes(source) ? getSourceColor(source) : 'bg-secondary/50 text-muted-foreground border-border hover:bg-secondary'}"
                  >
                    {source}
                  </button>
                {/each}
              </div>
            </div>
            
            <div>
              <h3 class="text-sm font-medium text-foreground mb-2">Level</h3>
              <div class="flex flex-wrap gap-2">
                {#each ['debug', 'info', 'warn', 'error'] as level}
                  <button
                    on:click={() => toggleLevel(level)}
                    class="px-3 py-1 text-xs rounded-md border transition-colors {selectedLevels.includes(level) ? getLevelBadgeColor(level) : 'bg-secondary/50 text-muted-foreground border-border hover:bg-secondary'}"
                  >
                    {level}
                  </button>
                {/each}
              </div>
            </div>
          </div>
        </Popover.Content>
      </Popover.Root>
      
      <!-- Auto-scroll -->
      <button
        on:click={() => autoScroll = !autoScroll}
        class="px-3 py-1.5 text-xs rounded-md border border-border transition-colors {autoScroll ? 'bg-primary text-primary-foreground' : 'bg-secondary text-muted-foreground hover:bg-secondary/80'}"
      >
        Auto-scroll
      </button>
      
      <!-- Limpiar -->
      <button
        on:click={clearLogs}
        class="p-2 rounded-md hover:bg-destructive/20 border border-border transition-colors group"
        title="Limpiar logs"
      >
        <Icon icon="lucide:trash-2" class="w-4 h-4 text-muted-foreground group-hover:text-destructive" />
      </button>
    </div>
  </div>
  
  <!-- Logs Container -->
  <div bind:this={logsContainer} class="flex-1 overflow-y-auto custom-scrollbar bg-background/50">
    {#if filteredLogs.length === 0}
      <div class="flex items-center justify-center h-full text-muted-foreground">
        <p>No hay logs que mostrar</p>
      </div>
    {:else}
      <div class="font-mono text-xs">
        {#each filteredLogs as log (log.id)}
          <div class="flex items-start gap-3 px-4 py-2 hover:bg-secondary/30 border-b border-border/50 transition-colors">
            <!-- Timestamp -->
            <span class="text-muted-foreground shrink-0 w-28">
              {formatTime(log.timestamp)}
            </span>
            
            <!-- Source Badge -->
            <span class="px-2 py-0.5 rounded text-[10px] font-medium border shrink-0 {getSourceColor(log.source)}">
              {log.source.toUpperCase()}
            </span>
            
            <!-- Level Badge -->
            <span class="px-2 py-0.5 rounded text-[10px] font-medium border shrink-0 {getLevelBadgeColor(log.level)}">
              {log.level.toUpperCase()}
            </span>
            
            <!-- Message -->
            <span class="{getLevelColor(log.level)} flex-1 break-all">
              {log.message}
            </span>
            
            <!-- Metadata (si existe) -->
            {#if log.metadata && Object.keys(log.metadata).length > 0}
              <button
                class="text-muted-foreground hover:text-foreground text-[10px] shrink-0"
                title={JSON.stringify(log.metadata, null, 2)}
              >
                {'...'}
              </button>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>
