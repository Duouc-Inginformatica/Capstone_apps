<script lang="ts">
	import { onMount, onDestroy } from 'svelte';
	import Icon from '@iconify/svelte';

	interface ScraperStatus {
		source: string;
		status: string;
		method: string;
		lastRunAt: string | null;
		totalRequests: number;
		successfulRuns: number;
		failedRuns: number;
		successRate: number;
		avgResponseTimeMs: number;
		routesGenerated: number;
		stopsExtracted: number;
		metroLines: string[];
		lastError: string;
	}

	let scraperData = $state<ScraperStatus | null>(null);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let intervalId: number | undefined;

	async function fetchScraperData() {
		try {
			console.log('[ScraperPanel] Fetching data from /api/stats/scraper...');
			const response = await fetch('http://localhost:8080/api/stats/scraper');
			console.log('[ScraperPanel] Response status:', response.status);
			if (!response.ok) throw new Error('Failed to fetch scraper data');
			const data = await response.json();
			console.log('[ScraperPanel] Data received:', data);
			scraperData = data;
			error = null;
		} catch (err) {
			error = err instanceof Error ? err.message : 'Error desconocido';
			console.error('[ScraperPanel] Error fetching scraper data:', err);
		} finally {
			loading = false;
			console.log('[ScraperPanel] Loading finished. Error:', error, 'Data:', scraperData);
		}
	}

	onMount(() => {
		fetchScraperData();
		intervalId = setInterval(fetchScraperData, 10000) as unknown as number;
	});

	onDestroy(() => {
		if (intervalId !== undefined) {
			clearInterval(intervalId);
		}
	});

	function getStatusColor(status: string): string {
		if (status === 'active') return 'text-emerald-400';
		if (status === 'idle') return 'text-gray-400';
		return 'text-red-400';
	}

	function getStatusBadge(status: string): string {
		if (status === 'active') return 'bg-emerald-400/10 text-emerald-400 border-emerald-400/20';
		if (status === 'idle') return 'bg-gray-400/10 text-gray-400 border-gray-400/20';
		return 'bg-red-400/10 text-red-400 border-red-400/20';
	}

	function getStatusText(status: string): string {
		if (status === 'active') return 'Activo';
		if (status === 'idle') return 'Esperando';
		return 'Offline';
	}

	function formatLastRun(isoDate: string | null): string {
		if (!isoDate) return 'Nunca';
		const date = new Date(isoDate);
		const now = new Date();
		const diffMs = now.getTime() - date.getTime();
		const diffMins = Math.floor(diffMs / 60000);

		if (diffMins < 1) return 'hace menos de 1 min';
		if (diffMins < 60) return `hace ${diffMins} min`;
		const diffHours = Math.floor(diffMins / 60);
		if (diffHours < 24) return `hace ${diffHours}h`;
		return `hace ${Math.floor(diffHours / 24)}d`;
	}

	function formatResponseTime(ms: number): string {
		if (ms < 1000) return `${ms}ms`;
		return `${(ms / 1000).toFixed(1)}s`;
	}
</script>

<div class="neomorphic p-6 rounded-2xl">
	<!-- Header -->
	<div class="flex items-center justify-between mb-6">
		<div class="flex items-center gap-3">
			<div class="relative">
				<div class="absolute inset-0 bg-gradient-to-r from-emerald-400 to-teal-400 rounded-xl blur-md opacity-75"></div>
				<div class="relative neomorphic-inset p-3 rounded-xl">
					<Icon icon="lucide:globe" class="w-6 h-6 text-emerald-300" />
				</div>
			</div>
			<div>
				<h3 class="text-xl font-bold gradient-text">Web Scraper - Moovit</h3>
				<p class="text-sm text-muted-foreground">Motor de rutas en tiempo real</p>
			</div>
		</div>

		{#if scraperData}
			<span class={`px-4 py-2 rounded-xl text-sm font-medium border neomorphic-inset ${getStatusBadge(scraperData.status)}`}>
				{scraperData.status.toUpperCase()}
			</span>
		{/if}
	</div>

	{#if loading}
		<div class="flex items-center justify-center py-12">
			<Icon icon="lucide:loader-2" class="w-8 h-8 text-primary animate-spin" />
		</div>
	{:else if error}
		<div class="neomorphic-inset p-4 rounded-xl">
			<div class="flex items-center gap-3 mb-3">
				<Icon icon="lucide:alert-triangle" class="w-6 h-6 text-yellow-400" />
				<div>
					<p class="text-yellow-400 font-medium">Error al obtener datos</p>
					<p class="text-xs text-gray-400">{error}</p>
				</div>
			</div>
			<div class="text-xs text-gray-500">
				Verifica que el backend esté corriendo en http://localhost:8080
			</div>
		</div>
	{:else if scraperData}
		<!-- Estado -->
		<div class="grid grid-cols-2 gap-4 mb-6">
			<div class="neomorphic-inset rounded-xl p-4 bg-gradient-to-br from-background/30 to-background/10">
				<div class="flex items-center gap-2 mb-2">
					<Icon icon="lucide:activity" width={16} class={getStatusColor(scraperData.status)} />
					<span class="text-xs text-muted-foreground uppercase tracking-wider">Estado</span>
				</div>
				<p class={`text-2xl font-bold ${getStatusColor(scraperData.status)}`}>
					{getStatusText(scraperData.status)}
				</p>
				{#if scraperData.status === 'idle'}
					<p class="text-xs text-gray-500 mt-1">Sin actividad reciente</p>
				{/if}
			</div>

			<div class="neomorphic-inset rounded-xl p-4 bg-gradient-to-br from-background/30 to-background/10">
				<div class="flex items-center gap-2 mb-2">
					<Icon icon="lucide:map" width={16} class="text-purple-400" />
					<span class="text-xs text-muted-foreground uppercase tracking-wider">Geometría</span>
				</div>
				<p class="text-2xl font-bold text-purple-400">{scraperData.routesGenerated}</p>
				<p class="text-xs text-gray-500 mt-1">Rutas generadas</p>
			</div>
		</div>

		<!-- Última Ejecución -->
		<div class="neomorphic-inset rounded-xl p-4 bg-gradient-to-br from-background/30 to-background/10">
			<div class="flex items-center justify-between">
				<div class="flex items-center gap-2">
					<Icon icon="lucide:clock" width={16} class="text-gray-400" />
					<span class="text-xs text-muted-foreground">Última ejecución</span>
				</div>
				<span class="text-sm text-white font-medium">{formatLastRun(scraperData.lastRunAt)}</span>
			</div>
		</div>

		{#if scraperData.lastError}
			<div class="mt-4 neomorphic-inset rounded-xl p-3 bg-gradient-to-br from-red-500/10 to-background/10">
				<div class="flex items-start gap-2">
					<Icon icon="lucide:alert-circle" width={16} class="text-red-400 mt-0.5" />
					<div class="flex-1">
						<p class="text-xs text-red-400 font-medium mb-1">Último Error</p>
						<p class="text-xs text-gray-300">{scraperData.lastError}</p>
					</div>
				</div>
			</div>
		{/if}

		<!-- Tecnologías -->
		<div class="mt-6 pt-6 border-t border-white/5">
			<h3 class="text-xs text-muted-foreground uppercase tracking-wider mb-3">Stack Tecnológico</h3>
			<div class="flex flex-wrap gap-2">
				<span class="neomorphic-inset px-3 py-1 text-blue-300 text-xs rounded-xl">
					Microsoft Edge
				</span>
				<span class="neomorphic-inset px-3 py-1 text-cyan-300 text-xs rounded-xl">
					chromedp
				</span>
				<span class="neomorphic-inset px-3 py-1 text-yellow-300 text-xs rounded-xl">
					JavaScript Injection
				</span>
				<span class="neomorphic-inset px-3 py-1 text-orange-300 text-xs rounded-xl">
					HTML Parsing
				</span>
			</div>
		</div>
	{/if}
</div>
