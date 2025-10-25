<script lang="ts">
  import { onMount } from 'svelte';
  import ScrollReveal from 'scrollreveal';
  import Header from './components/Header.svelte';
  import LogsPanel from './components/LogsPanel.svelte';
  import MetricsPanel from './components/MetricsPanel.svelte';
  import MetricsChart from './components/MetricsChart.svelte';
  import GtfsPanel from './components/GtfsPanel.svelte';
  import DatabaseReport from './components/DatabaseReport.svelte';
  import ScraperPanel from './components/ScraperPanel.svelte';
  import GraphHopperPanel from './components/GraphHopperPanel.svelte';
  import { connectWebSocket } from './services/websocket';

  onMount(() => {
    connectWebSocket();
    
    // Configurar ScrollReveal
    const sr = ScrollReveal({
      distance: '30px',
      duration: 800,
      easing: 'cubic-bezier(0.4, 0, 0.2, 1)',
      interval: 100,
      opacity: 0,
      reset: false,
      mobile: true,
      viewFactor: 0.2
    });
    
    // Animar elementos con scroll
    sr.reveal('.reveal-item', { origin: 'bottom' });
    sr.reveal('.reveal-left', { origin: 'left', distance: '50px' });
    sr.reveal('.reveal-right', { origin: 'right', distance: '50px' });
  });
</script>

<div class="flex flex-col h-screen bg-gradient-to-br from-black via-gray-950 to-black text-foreground">
  <!-- Header con Glass Effect y Status integrado -->
  <Header />
  
  <!-- Main Dashboard Grid con backdrop blur -->
  <main class="flex-1 overflow-y-auto custom-scrollbar p-4 gap-4 grid grid-cols-1 lg:grid-cols-3 relative">
    <!-- Background pattern -->
    <div class="absolute inset-0 bg-[radial-gradient(ellipse_at_top_right,_var(--tw-gradient-stops))] from-gray-900/20 via-transparent to-transparent pointer-events-none"></div>
    
    <!-- Logs Panel (2 columnas en desktop) -->
    <div class="lg:col-span-2 flex flex-col gap-4 relative z-10">
      <div class="reveal-left">
        <LogsPanel />
      </div>
      <div class="reveal-left">
        <GtfsPanel />
      </div>
      <div class="reveal-left">
        <DatabaseReport />
      </div>
      <div>
        <ScraperPanel />
      </div>
      <div>
        <GraphHopperPanel />
      </div>
    </div>
    
    <!-- Right Sidebar (1 columna) -->
    <div class="flex flex-col gap-4 relative z-10">
      <div class="reveal-right">
        <MetricsChart />
      </div>
      <div class="reveal-right">
        <MetricsPanel />
      </div>
    </div>
  </main>
</div>

<style>
  :global(body) {
    margin: 0;
    padding: 0;
    overflow: hidden;
  }
</style>
