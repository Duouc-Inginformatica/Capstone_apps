<script lang="ts">
  import Icon from '@iconify/svelte';
  import { version } from '../../package.json';
</script>

<header class="border-b border-white/10 bg-black/40 backdrop-blur-xl px-6 py-4">
  <div class="flex items-center justify-between">
    <div class="flex items-center gap-4">
      <!-- Logo y Título -->
      <div class="flex items-center gap-3">
        <div class="w-10 h-10 bg-gradient-to-br from-primary to-red-700 rounded-lg flex items-center justify-center shadow-lg shadow-primary/50">
          <Icon icon="lucide:activity" class="w-6 h-6 text-white" />
        </div>
        <div>
          <h1 class="text-xl font-bold text-white">
            WayFindCL Debug Dashboard
          </h1>
          <p class="text-xs text-gray-400">
            Red Mobilidad · Monitoring & Debugging
          </p>
        </div>
      </div>
    </div>
    
    <!-- Version -->
    <div class="flex items-center gap-2">
      <span class="text-xs text-gray-500">v{version}</span>
    </div>
  </div>
</header>
