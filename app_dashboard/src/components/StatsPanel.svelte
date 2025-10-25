<script lang="ts">
  import { onMount } from 'svelte';
  import Icon from '@iconify/svelte';
  
  type ViewType = 'system' | 'routes' | 'users' | 'buses';
  
  let systemStats = $state<any>(null);
  let routeStats = $state<any>(null);
  let userStats = $state<any>(null);
  let busStats = $state<any>(null);
  let loading = $state(true);
  let selectedView = $state<ViewType>('system');
  
  async function fetchStats() {
    try {
      const [system, routes, users, buses] = await Promise.all([
        fetch('http://localhost:8080/api/stats/system').then(r => r.json()),
        fetch('http://localhost:8080/api/stats/routes?days=7').then(r => r.json()),
        fetch('http://localhost:8080/api/stats/users').then(r => r.json()),
        fetch('http://localhost:8080/api/stats/buses?days=7').then(r => r.json()),
      ]);
      
      systemStats = system;
      routeStats = routes;
      userStats = users;
      busStats = buses;
      loading = false;
    } catch (error) {
      console.error('Error fetching stats:', error);
      loading = false;
    }
  }
  
  onMount(() => {
    fetchStats();
    // Actualizar cada 10 segundos
    const interval = setInterval(fetchStats, 10000);
    return () => clearInterval(interval);
  });
  
  function formatUptime(seconds: number) {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    return `${hours}h ${minutes}m`;
  }
  
  function formatBytes(bytes: number) {
    return `${bytes} MB`;
  }
</script>

<div class="neomorphic overflow-hidden h-full flex flex-col">
  <div class="px-6 py-4 border-b border-white/5 bg-gradient-to-r from-background/30 via-background/20 to-transparent shrink-0">
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-3">
        <div class="p-2 rounded-xl bg-gradient-to-br from-gray-400/20 to-gray-500/20 shadow-lg">
          <Icon icon="lucide:pie-chart" class="w-5 h-5 text-gray-300" />
        </div>
        <h2 class="text-lg font-bold gradient-text">Estadísticas</h2>
      </div>
      
      <div class="flex gap-1 neomorphic-inset rounded-xl p-1">
        <button
          onclick={() => selectedView = 'system'}
          class="px-3 py-1.5 text-xs font-semibold rounded-lg transition-all {selectedView === 'system' ? 'bg-gradient-to-r from-gray-300 to-gray-400 text-black shadow-lg shadow-gray-300/30' : 'text-muted-foreground hover:text-white'}"
        >
          <div class="flex items-center gap-1.5">
            <Icon icon="lucide:cpu" class="w-3.5 h-3.5" />
            Sistema
          </div>
        </button>
        <button
          onclick={() => selectedView = 'routes'}
          class="px-3 py-1.5 text-xs font-semibold rounded-lg transition-all {selectedView === 'routes' ? 'bg-gradient-to-r from-gray-300 to-gray-400 text-black shadow-lg shadow-gray-300/30' : 'text-muted-foreground hover:text-white'}"
        >
          <div class="flex items-center gap-1.5">
            <Icon icon="lucide:map" class="w-3.5 h-3.5" />
            Rutas
          </div>
        </button>
        <button
          onclick={() => selectedView = 'users'}
          class="px-3 py-1.5 text-xs font-semibold rounded-lg transition-all {selectedView === 'users' ? 'bg-gradient-to-r from-gray-300 to-gray-400 text-black shadow-lg shadow-gray-300/30' : 'text-muted-foreground hover:text-white'}"
        >
          <div class="flex items-center gap-1.5">
            <Icon icon="lucide:users" class="w-3.5 h-3.5" />
            Usuarios
          </div>
        </button>
        <button
          onclick={() => selectedView = 'buses'}
          class="px-3 py-1.5 text-xs font-semibold rounded-lg transition-all {selectedView === 'buses' ? 'bg-gradient-to-r from-gray-300 to-gray-400 text-black shadow-lg shadow-gray-300/30' : 'text-muted-foreground hover:text-white'}"
        >
          <div class="flex items-center gap-1.5">
            <Icon icon="lucide:bus" class="w-3.5 h-3.5" />
            Buses
          </div>
        </button>
      </div>
    </div>
  </div>
  
  <div class="flex-1 overflow-y-auto custom-scrollbar p-4">
    {#if loading}
      <div class="flex flex-col items-center justify-center h-full gap-3">
        <Icon icon="lucide:loader-2" class="w-10 h-10 text-primary animate-spin" />
        <p class="text-sm text-muted-foreground">Cargando estadísticas...</p>
      </div>
    {:else if selectedView === 'system' && systemStats}
      <div class="space-y-3">
        <!-- Uptime y versión -->
        <div class="grid grid-cols-2 gap-3">
          <div class="neomorphic-inset rounded-xl p-4 card-hover">
            <div class="flex items-center gap-2 mb-2">
              <Icon icon="lucide:clock" class="w-4 h-4 text-emerald-400" />
              <div class="text-xs text-muted-foreground font-medium">Uptime</div>
            </div>
            <div class="text-xl font-bold text-white">{formatUptime(systemStats.uptime)}</div>
          </div>
          <div class="neomorphic-inset rounded-xl p-4 card-hover">
            <div class="flex items-center gap-2 mb-2">
              <Icon icon="lucide:code-2" class="w-4 h-4 text-primary" />
              <div class="text-xs text-muted-foreground font-medium">Versión</div>
            </div>
            <div class="text-xl font-bold gradient-text">{systemStats.version}</div>
          </div>
        </div>
        
        <!-- Memoria -->
        <div class="neomorphic-inset rounded-xl p-4 card-hover">
          <div class="flex items-center gap-2 mb-3">
            <div class="p-1.5 rounded-lg bg-gradient-to-br from-blue-500/20 to-cyan-500/20">
              <Icon icon="lucide:hard-drive" class="w-4 h-4 text-blue-400" />
            </div>
            <div class="text-sm font-bold text-white">Memoria</div>
          </div>
          <div class="space-y-2 text-xs">
            <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
              <span class="text-muted-foreground">Allocated</span>
              <span class="text-white font-bold font-mono">{formatBytes(systemStats.memory.allocated)}</span>
            </div>
            <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
              <span class="text-muted-foreground">Total</span>
              <span class="text-white font-bold font-mono">{formatBytes(systemStats.memory.total)}</span>
            </div>
            <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
              <span class="text-muted-foreground">System</span>
              <span class="text-primary font-bold font-mono">{formatBytes(systemStats.memory.system)}</span>
            </div>
          </div>
        </div>
        
        <!-- Base de Datos -->
        <div class="neomorphic-inset rounded-xl p-4 card-hover">
          <div class="flex items-center gap-2 mb-3">
            <div class="p-1.5 rounded-lg bg-gradient-to-br from-purple-500/20 to-pink-500/20">
              <Icon icon="lucide:database" class="w-4 h-4 text-purple-400" />
            </div>
            <div class="text-sm font-bold text-white">Base de Datos</div>
          </div>
          <div class="space-y-3 text-xs">
            <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
              <span class="text-muted-foreground">Conexiones</span>
              <span class="text-white font-bold font-mono">{systemStats.database.connections}/{systemStats.database.maxConnections}</span>
            </div>
            <div class="neomorphic-inset rounded-lg p-2">
              <div class="flex justify-between items-center mb-2">
                <span class="text-muted-foreground">Pool Usage</span>
                <span class="text-primary font-semibold">{Math.round((systemStats.database.connections / systemStats.database.maxConnections) * 100)}%</span>
              </div>
              <div class="relative w-full h-2 neomorphic-inset rounded-full overflow-hidden">
                <div 
                  class="absolute top-0 left-0 h-full bg-gradient-to-r from-purple-500 to-pink-500 rounded-full transition-all duration-500 shadow-lg shadow-purple-500/50" 
                  style="width: {(systemStats.database.connections / systemStats.database.maxConnections) * 100}%"
                ></div>
              </div>
            </div>
          </div>
        </div>
        
        <!-- Requests -->
        <div class="neomorphic-inset rounded-xl p-4 card-hover">
          <div class="flex items-center gap-2 mb-3">
            <div class="p-1.5 rounded-lg bg-gradient-to-br from-emerald-500/20 to-green-500/20">
              <Icon icon="lucide:activity" class="w-4 h-4 text-emerald-400" />
            </div>
            <div class="text-sm font-bold text-white">Requests</div>
          </div>
          <div class="space-y-2 text-xs">
            <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
              <span class="text-muted-foreground">Total</span>
              <span class="text-white font-bold font-mono">{systemStats.requests.total.toLocaleString()}</span>
            </div>
            <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
              <span class="text-muted-foreground">Últimas 24h</span>
              <span class="text-emerald-400 font-bold font-mono">{systemStats.requests.last24Hours.toLocaleString()}</span>
            </div>
            <div class="flex justify-between items-center neomorphic-inset rounded-lg px-3 py-2">
              <span class="text-muted-foreground">Por minuto</span>
              <span class="text-primary font-bold font-mono">{systemStats.requests.perMinute.toFixed(2)}</span>
            </div>
          </div>
        </div>
      </div>
      
    {:else if selectedView === 'routes' && routeStats}
      <div class="space-y-3">
        <div class="neomorphic-inset rounded-xl p-4 card-hover">
          <div class="flex items-center gap-2 mb-2">
            <Icon icon="lucide:map-pin" class="w-5 h-5 text-primary" />
            <div class="text-xs text-muted-foreground font-medium">Total de Rutas</div>
          </div>
          <div class="text-3xl font-bold gradient-text">{routeStats.totalRequests.toLocaleString()}</div>
        </div>
        
        <div class="neomorphic-inset rounded-xl p-4 card-hover">
          <div class="flex items-center gap-2 mb-3">
            <Icon icon="lucide:bus" class="w-4 h-4 text-cyan-400" />
            <div class="text-sm font-bold text-white">Por Tipo de Transporte</div>
          </div>
          <div class="space-y-2">
            {#each Object.entries(routeStats.byType) as [type, count]}
              <div class="flex justify-between items-center text-xs neomorphic-inset rounded-lg px-3 py-2">
                <span class="text-muted-foreground capitalize">{type}</span>
                <span class="text-white font-bold font-mono">{count}</span>
              </div>
            {/each}
          </div>
        </div>
        
        <div class="neomorphic-inset rounded-xl p-4 card-hover">
          <div class="flex items-center gap-2 mb-3">
            <Icon icon="lucide:clock" class="w-4 h-4 text-amber-400" />
            <div class="text-sm font-bold text-white">Por Hora del Día</div>
          </div>
          <div class="space-y-2">
            {#each Object.entries(routeStats.byTimeOfDay) as [timeOfDay, count]}
              <div class="flex justify-between items-center text-xs neomorphic-inset rounded-lg px-3 py-2">
                <span class="text-muted-foreground capitalize">{timeOfDay}</span>
                <span class="text-white font-bold font-mono">{count}</span>
              </div>
            {/each}
          </div>
        </div>
        
        {#if routeStats.averageDistance > 0}
          <div class="neomorphic-inset rounded-xl p-4 card-hover">
            <div class="flex items-center gap-2 mb-2">
              <Icon icon="lucide:ruler" class="w-4 h-4 text-green-400" />
              <div class="text-xs text-muted-foreground font-medium">Distancia Promedio</div>
            </div>
            <div class="text-2xl font-bold text-emerald-400">{routeStats.averageDistance.toFixed(2)} <span class="text-sm">km</span></div>
          </div>
        {/if}
      </div>
      
    {:else if selectedView === 'users' && userStats}
      <div class="space-y-3">
        <div class="grid grid-cols-2 gap-3">
          <div class="neomorphic-inset rounded-xl p-4 card-hover">
            <div class="flex items-center gap-2 mb-2">
              <Icon icon="lucide:users" class="w-4 h-4 text-primary" />
              <div class="text-xs text-muted-foreground font-medium">Total</div>
            </div>
            <div class="text-2xl font-bold gradient-text">{userStats.totalUsers.toLocaleString()}</div>
          </div>
          <div class="neomorphic-inset rounded-xl p-4 card-hover">
            <div class="flex items-center gap-2 mb-2">
              <Icon icon="lucide:user-check" class="w-4 h-4 text-emerald-400" />
              <div class="text-xs text-muted-foreground font-medium">Activos</div>
            </div>
            <div class="text-2xl font-bold text-emerald-400">{userStats.activeUsers.toLocaleString()}</div>
          </div>
        </div>
        
        <div class="grid grid-cols-2 gap-3">
          <div class="neomorphic-inset rounded-xl p-4 card-hover">
            <div class="flex items-center gap-2 mb-2">
              <Icon icon="lucide:user-plus" class="w-4 h-4 text-cyan-400" />
              <div class="text-xs text-muted-foreground font-medium">Hoy</div>
            </div>
            <div class="text-xl font-bold text-white">{userStats.newUsersToday}</div>
          </div>
          <div class="neomorphic-inset rounded-xl p-4 card-hover">
            <div class="flex items-center gap-2 mb-2">
              <Icon icon="lucide:calendar-days" class="w-4 h-4 text-purple-400" />
              <div class="text-xs text-muted-foreground font-medium">7 días</div>
            </div>
            <div class="text-xl font-bold text-white">{userStats.newUsersThisWeek}</div>
          </div>
        </div>
        
        {#if Object.keys(userStats.byAccessibility).length > 0}
          <div class="neomorphic-inset rounded-xl p-4 card-hover">
            <div class="flex items-center gap-2 mb-3">
              <Icon icon="lucide:accessibility" class="w-4 h-4 text-amber-400" />
              <div class="text-sm font-bold text-white">Por Accesibilidad</div>
            </div>
            <div class="space-y-2">
              {#each Object.entries(userStats.byAccessibility) as [type, count]}
                <div class="flex justify-between items-center text-xs neomorphic-inset rounded-lg px-3 py-2">
                  <span class="text-muted-foreground capitalize">{type}</span>
                  <span class="text-white font-bold font-mono">{count}</span>
                </div>
              {/each}
            </div>
          </div>
        {/if}
      </div>
      
    {:else if selectedView === 'buses' && busStats}
      <div class="space-y-3">
        <div class="neomorphic-inset rounded-xl p-4 card-hover">
          <div class="flex items-center gap-2 mb-2">
            <Icon icon="lucide:bus" class="w-5 h-5 text-orange-400" />
            <div class="text-xs text-muted-foreground font-medium">Consultas de Buses</div>
          </div>
          <div class="text-3xl font-bold gradient-text">{busStats.totalRequests.toLocaleString()}</div>
        </div>
        
        {#if busStats.peakHours && busStats.peakHours.length > 0}
          <div class="neomorphic-inset rounded-xl p-4 card-hover">
            <div class="flex items-center gap-2 mb-3">
              <Icon icon="lucide:trending-up" class="w-4 h-4 text-rose-400" />
              <div class="text-sm font-bold text-white">Horas Pico</div>
            </div>
            <div class="space-y-2">
              {#each busStats.peakHours.slice(0, 5) as peak, index}
                <div class="flex justify-between items-center text-xs neomorphic-inset rounded-lg px-3 py-2">
                  <div class="flex items-center gap-2">
                    <div class="w-5 h-5 rounded-full bg-gradient-to-br from-primary to-secondary flex items-center justify-center text-[10px] font-bold">
                      {index + 1}
                    </div>
                    <span class="text-muted-foreground font-mono">{peak.hour}:00 - {peak.hour + 1}:00</span>
                  </div>
                  <span class="text-white font-bold font-mono">{peak.count}</span>
                </div>
              {/each}
            </div>
          </div>
        {/if}
      </div>
    {/if}
  </div>
</div>
