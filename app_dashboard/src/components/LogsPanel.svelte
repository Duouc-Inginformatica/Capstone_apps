<script lang="ts">
  import { logsStore, clearLogs, type LogEntry } from '../stores/index.svelte';
  import Icon from '@iconify/svelte';
  import { Popover } from 'bits-ui';
  
  let searchTerm = $state('');
  let selectedSources = $state<string[]>([]);
  let selectedLevels = $state<string[]>([]);
  let autoScroll = $state(true);
  let hideStatsLogs = $state(true); // Ocultar logs de /api/stats/ por defecto
  let logsContainer: HTMLDivElement;
  
  let filteredLogs = $derived.by(() => logsStore.filter(log => {
    if (searchTerm && !log.message.toLowerCase().includes(searchTerm.toLowerCase())) {
      return false;
    }
    if (selectedSources.length > 0 && !selectedSources.includes(log.source)) {
      return false;
    }
    if (selectedLevels.length > 0 && !selectedLevels.includes(log.level)) {
      return false;
    }
    // Filtrar logs de /api/stats/ y /api/status si está activado
    if (hideStatsLogs && (log.message.includes('/api/stats/') || log.message.includes('/api/status'))) {
      return false;
    }
    return true;
  }));
  
  function getLevelColor(level: string) {
    switch (level) {
      case 'debug': return 'text-blue-400';
      case 'info': return 'text-emerald-400';
      case 'warn': return 'text-amber-400';
      case 'error': return 'text-rose-400';
      default: return 'text-gray-400';
    }
  }
  
  function getLevelBadgeColor(level: string) {
    switch (level) {
      case 'debug': return 'bg-gradient-to-r from-blue-500/20 to-cyan-500/20 text-blue-300 border-blue-500/30 shadow-blue-500/20';
      case 'info': return 'bg-gradient-to-r from-emerald-500/20 to-green-500/20 text-emerald-300 border-emerald-500/30 shadow-emerald-500/20';
      case 'warn': return 'bg-gradient-to-r from-amber-500/20 to-yellow-500/20 text-amber-300 border-amber-500/30 shadow-amber-500/20';
      case 'error': return 'bg-gradient-to-r from-rose-500/20 to-red-500/20 text-rose-300 border-rose-500/30 shadow-rose-500/20';
      default: return 'bg-gradient-to-r from-gray-500/20 to-slate-500/20 text-gray-300 border-gray-500/30 shadow-gray-500/20';
    }
  }
  
  function getSourceColor(source: string) {
    switch (source) {
      case 'backend': return 'bg-gradient-to-r from-primary/20 to-indigo-500/20 text-primary border-primary/30 shadow-primary/20';
      case 'frontend': return 'bg-gradient-to-r from-purple-500/20 to-pink-500/20 text-purple-300 border-purple-500/30 shadow-purple-500/20';
      case 'graphhopper': return 'bg-gradient-to-r from-cyan-500/20 to-blue-500/20 text-cyan-300 border-cyan-500/30 shadow-cyan-500/20';
      case 'scraping': return 'bg-gradient-to-r from-orange-500/20 to-red-500/20 text-orange-300 border-orange-500/30 shadow-orange-500/20';
      default: return 'bg-gradient-to-r from-gray-500/20 to-slate-500/20 text-gray-300 border-gray-500/30 shadow-gray-500/20';
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
  
  // Función para detectar indentación y categoría del log
  function parseLogMessage(message: string): {
    indentLevel: number;
    content: string;
    category: string | null;
    isStage: boolean;
    hasEmoji: boolean;
  } {
    // Detectar espacios al inicio (indentación)
    const indentMatch = message.match(/^(\s*)/);
    const indentLevel = indentMatch ? Math.floor(indentMatch[1].length / 2) : 0;

    // Detectar categoría ([MOOVIT], [GTFS], etc.)
    const categoryMatch = message.match(/\[(MOOVIT|GTFS|GraphHopper|GEOMETRY|DEBUG|REDCL)\]/i);
    const category = categoryMatch ? categoryMatch[1].toUpperCase() : null;

    // Detectar si es una etapa (ETAPA 1, ETAPA 2, etc.)
    const isStage = /ETAPA \d+/i.test(message) || /═{3,}/.test(message);

    // Detectar si tiene emojis
    const hasEmoji = /[\u{1F300}-\u{1F9FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]/u.test(message);

    return {
      indentLevel,
      content: message.trimStart(),
      category,
      isStage,
      hasEmoji
    };
  }

  // Función para obtener el color según la categoría
  function getCategoryColor(category: string | null): string {
    if (!category) return '';
    
    switch (category) {
      case 'MOOVIT':
        return 'text-emerald-300';
      case 'GTFS':
        return 'text-blue-300';
      case 'GRAPHHOPPER':
        return 'text-pink-300';
      case 'GEOMETRY':
        return 'text-purple-300';
      case 'DEBUG':
        return 'text-yellow-300';
      case 'REDCL':
        return 'text-cyan-300';
      default:
        return 'text-gray-300';
    }
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
  
  $effect(() => {
    if (autoScroll && logsContainer) {
      logsContainer.scrollTop = logsContainer.scrollHeight;
    }
  });
</script>

<div class="flex flex-col neomorphic overflow-hidden rounded-2xl" style="max-height: 500px;">
  <!-- Header del panel -->
  <div class="flex items-center justify-between px-6 py-4 border-b border-white/5 bg-gradient-to-r from-background/30 via-background/20 to-transparent flex-shrink-0">
    <div class="flex items-center gap-3">
      <div class="p-2 rounded-xl bg-gradient-to-br from-gray-400/20 to-gray-500/20 shadow-lg">
        <Icon icon="lucide:terminal" class="w-5 h-5 text-gray-300" />
      </div>
      <div>
        <h2 class="text-lg font-bold gradient-text">Logs en Tiempo Real</h2>
        <p class="text-xs text-muted-foreground">
          {filteredLogs.length} de {logsStore.length} entradas
        </p>
      </div>
    </div>
    
    <div class="flex items-center gap-3">
      <!-- Búsqueda -->
      <div class="relative">
        <Icon icon="lucide:search" class="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-muted-foreground pointer-events-none" />
        <input
          type="text"
          placeholder="Buscar en logs..."
          bind:value={searchTerm}
          class="pl-10 pr-4 py-2 text-sm neomorphic-inset rounded-xl text-white placeholder:text-muted-foreground w-64 focus:ring-2 focus:ring-primary/50 transition-all"
        />
      </div>
      
      <!-- Filtros -->
      <Popover.Root>
        <Popover.Trigger 
          class="p-2.5 rounded-xl neomorphic-inset card-hover transition-all"
        >
          <Icon icon="lucide:filter" class="w-4 h-4 text-white" />
        </Popover.Trigger>
        <Popover.Content 
          class="z-50 w-80 p-5 neomorphic rounded-2xl shadow-2xl"
        >
          <div class="space-y-5">
            <div>
              <h3 class="text-sm font-semibold text-white mb-3 flex items-center gap-2">
                <Icon icon="lucide:box" class="w-4 h-4 text-gray-300" />
                Fuente
              </h3>
              <div class="flex flex-wrap gap-2">
                {#each ['backend', 'frontend', 'graphhopper', 'scraping'] as source}
                  <button
                    onclick={() => toggleSource(source)}
                    class="px-3 py-1.5 text-xs font-medium rounded-lg border transition-all card-hover shadow-sm {selectedSources.includes(source) ? getSourceColor(source) + ' scale-105' : 'neomorphic-inset text-muted-foreground'}"
                  >
                    {source}
                  </button>
                {/each}
              </div>
            </div>
            
            <div>
              <h3 class="text-sm font-semibold text-white mb-3 flex items-center gap-2">
                <Icon icon="lucide:alert-circle" class="w-4 h-4 text-gray-400" />
                Nivel
              </h3>
              <div class="flex flex-wrap gap-2">
                {#each ['debug', 'info', 'warn', 'error'] as level}
                  <button
                    onclick={() => toggleLevel(level)}
                    class="px-3 py-1.5 text-xs font-medium rounded-lg border transition-all card-hover shadow-sm {selectedLevels.includes(level) ? getLevelBadgeColor(level) + ' scale-105' : 'neomorphic-inset text-muted-foreground'}"
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
        onclick={() => autoScroll = !autoScroll}
        class="px-4 py-2 text-xs font-semibold rounded-xl border transition-all {autoScroll ? 'bg-gradient-to-r from-gray-300 to-gray-400 text-black border-gray-300/30 shadow-lg shadow-gray-300/30' : 'neomorphic-inset text-muted-foreground'} card-hover"
      >
        <div class="flex items-center gap-2">
          <Icon icon={autoScroll ? "lucide:check-circle-2" : "lucide:circle"} class="w-3.5 h-3.5" />
          Auto-scroll
        </div>
      </button>
      
      <!-- Ocultar Stats -->
      <button
        onclick={() => hideStatsLogs = !hideStatsLogs}
        class="px-4 py-2 text-xs font-semibold rounded-xl border transition-all {hideStatsLogs ? 'bg-gradient-to-r from-gray-300 to-gray-400 text-black border-gray-300/30 shadow-lg shadow-gray-300/30' : 'neomorphic-inset text-muted-foreground'} card-hover"
        title={hideStatsLogs ? 'Mostrar logs de /api/stats/' : 'Ocultar logs de /api/stats/'}
      >
        <div class="flex items-center gap-2">
          <Icon icon={hideStatsLogs ? "lucide:eye-off" : "lucide:eye"} class="w-3.5 h-3.5" />
          Stats
        </div>
      </button>
      
      <!-- Limpiar -->
      <button
        onclick={clearLogs}
        class="p-2.5 rounded-xl neomorphic-inset transition-all card-hover group hover:shadow-lg hover:shadow-red-500/20"
        title="Limpiar logs"
      >
        <Icon icon="lucide:trash-2" class="w-4 h-4 text-muted-foreground group-hover:text-red-400 transition-colors" />
      </button>
    </div>
  </div>
  
  <!-- Logs Container -->
  <div bind:this={logsContainer} class="flex-1 overflow-y-auto custom-scrollbar">
    {#if filteredLogs.length === 0}
      <div class="flex flex-col items-center justify-center h-full text-muted-foreground">
        <Icon icon="lucide:inbox" class="w-16 h-16 mb-4 opacity-20" />
        <p class="text-sm">No hay logs que mostrar</p>
      </div>
    {:else}
      <div class="font-mono text-xs p-2 space-y-0.5">
        {#each filteredLogs as log (log.id)}
          {@const parsed = parseLogMessage(log.message)}
          {@const categoryColor = getCategoryColor(parsed.category)}
          {@const isStageHeader = parsed.isStage}
          
          <div 
            class="flex items-start gap-3 px-4 py-2 rounded-xl hover:bg-white/5 transition-all group {isStageHeader ? 'bg-gradient-to-r from-primary/10 to-transparent border-l-2 border-primary/50 font-bold' : 'neomorphic-inset'}"
            style="padding-left: {(parsed.indentLevel * 1.5) + 1}rem;"
          >
            <!-- Timestamp -->
            <span class="text-muted-foreground shrink-0 w-24 font-bold text-[10px]">
              {formatTime(log.timestamp)}
            </span>
            
            <!-- Source Badge (solo si no es log muy indentado) -->
            {#if parsed.indentLevel < 2}
              <span class="px-2 py-0.5 rounded-lg text-[9px] font-bold border shadow-sm shrink-0 {getSourceColor(log.source)} uppercase tracking-wide">
                {log.source}
              </span>
            {/if}
            
            <!-- Level Badge (solo si no es log muy indentado) -->
            {#if parsed.indentLevel < 2}
              <span class="px-2 py-0.5 rounded-lg text-[9px] font-bold border shadow-sm shrink-0 {getLevelBadgeColor(log.level)} uppercase tracking-wide">
                {log.level}
              </span>
            {/if}
            
            <!-- Message con emojis y categoría -->
            <span 
              class="flex-1 break-all leading-relaxed {isStageHeader ? 'text-white font-bold text-sm' : categoryColor || getLevelColor(log.level)}"
            >
              {#if parsed.category && parsed.indentLevel === 0}
                <span class="inline-block px-2 py-0.5 rounded text-[9px] font-bold bg-white/10 border border-white/20 mr-2">
                  {parsed.category}
                </span>
              {/if}
              {parsed.content}
            </span>
            
            <!-- Metadata (si existe) -->
            {#if log.metadata && Object.keys(log.metadata).length > 0}
              <button
                class="text-muted-foreground hover:text-white text-[10px] shrink-0 neomorphic-inset px-2 py-1 rounded-lg transition-all opacity-0 group-hover:opacity-100"
                title={JSON.stringify(log.metadata, null, 2)}
              >
                <Icon icon="lucide:info" class="w-3 h-3" />
              </button>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>
