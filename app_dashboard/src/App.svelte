<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import Header from './components/Header.svelte';
  import StatusBar from './components/StatusBar.svelte';
  import LogsPanel from './components/LogsPanel.svelte';
  import MetricsPanel from './components/MetricsPanel.svelte';
  import ApiStatus from './components/ApiStatus.svelte';
  import ScrapingStatus from './components/ScrapingStatus.svelte';
  import { connectWebSocket } from './services/websocket';

  onMount(() => {
    connectWebSocket();
  });
</script>

<div class="flex flex-col h-screen bg-gradient-to-br from-black via-gray-950 to-black text-foreground">
  <!-- Header con Glass Effect -->
  <Header />
  
  <!-- Status Bar con Glass Effect -->
  <StatusBar />
  
  <!-- Main Dashboard Grid con backdrop blur -->
  <main class="flex-1 overflow-hidden p-4 gap-4 grid grid-cols-1 lg:grid-cols-3 relative">
    <!-- Background pattern -->
    <div class="absolute inset-0 bg-[radial-gradient(ellipse_at_top_right,_var(--tw-gradient-stops))] from-gray-900/20 via-transparent to-transparent pointer-events-none"></div>
    
    <!-- Logs Panel (2 columnas en desktop) -->
    <div class="lg:col-span-2 flex flex-col gap-4 relative z-10">
      <LogsPanel />
    </div>
    
    <!-- Right Sidebar (1 columna) -->
    <div class="flex flex-col gap-4 relative z-10">
      <ApiStatus />
      <MetricsPanel />
      <ScrapingStatus />
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
