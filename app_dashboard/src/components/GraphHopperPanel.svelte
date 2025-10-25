<script lang="ts">
	import { onMount, onDestroy } from 'svelte';
	import Icon from '@iconify/svelte';

	interface RouteProfile {
		name: string;
		requests: number;
		avgTimeMs: number;
		avgDistanceKm: number;
		avgPoints: number;
		totalNodesVisited: number;
	}

	interface GraphHopperMetrics {
		status: 'active' | 'idle' | 'offline';
		totalRequests: number;
		avgResponseTimeMs: number;
		profilesUsed: RouteProfile[];
		lastRequestAt: string | null;
		cacheHitRate: number;
		activeProfiles: string[];
	}

	let metrics = $state<GraphHopperMetrics | null>(null);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let intervalId: number | undefined;

	async function fetchMetrics() {
		try {
			console.log('[GraphHopperPanel] Fetching data from /api/stats/graphhopper...');
			const response = await fetch('http://localhost:8080/api/stats/graphhopper');
			console.log('[GraphHopperPanel] Response status:', response.status);
			if (!response.ok) throw new Error('Failed to fetch GraphHopper metrics');
			const data = await response.json();
			console.log('[GraphHopperPanel] Data received:', data);
			metrics = data;
			error = null;
		} catch (err) {
			error = err instanceof Error ? err.message : 'Error desconocido';
			console.error('[GraphHopperPanel] Error fetching GraphHopper metrics:', err);
		} finally {
			loading = false;
			console.log('[GraphHopperPanel] Loading finished. Error:', error, 'Data:', metrics);
		}
	}

	onMount(() => {
		fetchMetrics();
		intervalId = setInterval(fetchMetrics, 10000) as unknown as number;
	});

	onDestroy(() => {
		if (intervalId !== undefined) {
			clearInterval(intervalId);
		}
	});

	function getStatusColor(status: string): string {
		switch (status) {
			case 'active':
				return 'text-emerald-400';
			case 'idle':
				return 'text-gray-400';
			case 'offline':
				return 'text-red-400';
			default:
				return 'text-gray-400';
		}
	}

	function getStatusBadge(status: string): string {
		switch (status) {
			case 'active':
				return 'bg-emerald-400/10 text-emerald-400 border-emerald-400/20';
			case 'idle':
				return 'bg-gray-400/10 text-gray-400 border-gray-400/20';
			case 'offline':
				return 'bg-red-400/10 text-red-400 border-red-400/20';
			default:
				return 'bg-gray-400/10 text-gray-400 border-gray-400/20';
		}
	}

	function getStatusText(status: string): string {
		switch (status) {
			case 'active':
				return 'Activo';
			case 'idle':
				return 'Esperando';
			case 'offline':
				return 'Offline';
			default:
				return 'Desconocido';
		}
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

	function getProfileIcon(profileName: string): string {
		switch (profileName) {
			case 'foot':
				return 'lucide:footprints';
			case 'bus':
				return 'lucide:bus';
			case 'car':
				return 'lucide:car';
			case 'pt':
				return 'lucide:train-front';
			default:
				return 'lucide:route';
		}
	}

	function getProfileColor(profileName: string): string {
		switch (profileName) {
			case 'foot':
				return 'text-blue-400 bg-blue-500/10 border-blue-500/20';
			case 'bus':
				return 'text-green-400 bg-green-500/10 border-green-500/20';
			case 'car':
				return 'text-purple-400 bg-purple-500/10 border-purple-500/20';
			case 'pt':
				return 'text-orange-400 bg-orange-500/10 border-orange-500/20';
			default:
				return 'text-gray-400 bg-gray-500/10 border-gray-500/20';
		}
	}

	function getProfileDetails(profileName: string): { speed: string; description: string } {
		switch (profileName) {
			case 'foot':
				return {
					speed: '4.25 km/h',
					description: 'Peatonal personalizado para accesibilidad (85% velocidad normal)'
				};
			case 'bus':
				return {
					speed: '70 km/h max',
					description: 'Buses urbanos con prioridad en vías principales'
				};
			case 'car':
				return {
					speed: '120 km/h max',
					description: 'Vehículos privados en carreteras urbanas/regionales'
				};
			case 'pt':
				return {
					speed: '80 km/h max',
					description: 'Transporte público (buses/metro) con transferencias'
				};
			default:
				return {
					speed: 'Variable',
					description: 'Perfil genérico'
				};
		}
	}
</script>

<div class="neomorphic p-6 rounded-2xl">
	<!-- Header -->
	<div class="flex items-center justify-between mb-6">
		<div class="flex items-center gap-3">
			<div class="relative">
				<div class="absolute inset-0 bg-gradient-to-r from-purple-400 to-pink-400 rounded-xl blur-md opacity-75"></div>
				<div class="relative neomorphic-inset p-3 rounded-xl">
					<Icon icon="lucide:route" class="w-6 h-6 text-purple-300" />
				</div>
			</div>
			<div>
				<h3 class="text-xl font-bold gradient-text">GraphHopper Routing</h3>
				<p class="text-sm text-muted-foreground">Motor de cálculo de rutas</p>
			</div>
		</div>

		{#if metrics}
			<span class={`px-4 py-2 rounded-xl text-sm font-medium border neomorphic-inset ${getStatusBadge(metrics.status)}`}>
				{metrics.status.toUpperCase()}
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
	{:else if metrics}
		<!-- Estado y Métricas Generales -->
		<div class="grid grid-cols-3 gap-4 mb-6">
			<div class="neomorphic-inset rounded-xl p-4 bg-gradient-to-br from-background/30 to-background/10">
				<div class="flex items-center gap-2 mb-2">
					<Icon icon="lucide:activity" width={16} class={getStatusColor(metrics.status)} />
					<span class="text-xs text-muted-foreground uppercase tracking-wider">Estado</span>
				</div>
				<p class={`text-2xl font-bold ${getStatusColor(metrics.status)}`}>
					{getStatusText(metrics.status)}
				</p>
				{#if metrics.status === 'idle'}
					<p class="text-xs text-gray-500 mt-1">Sin routing activo</p>
				{/if}
			</div>

			<div class="neomorphic-inset rounded-xl p-4 bg-gradient-to-br from-background/30 to-background/10">
				<div class="flex items-center gap-2 mb-2">
					<Icon icon="lucide:zap" width={16} class="text-yellow-400" />
					<span class="text-xs text-muted-foreground uppercase tracking-wider">Requests</span>
				</div>
				<p class="text-2xl font-bold text-white">{metrics.totalRequests}</p>
				<p class="text-xs text-gray-500 mt-1">Cálculos de ruta</p>
			</div>

			<div class="neomorphic-inset rounded-xl p-4 bg-gradient-to-br from-background/30 to-background/10">
				<div class="flex items-center gap-2 mb-2">
					<Icon icon="lucide:clock" width={16} class="text-blue-400" />
					<span class="text-xs text-muted-foreground uppercase tracking-wider">Tiempo Promedio</span>
				</div>
				<p class="text-2xl font-bold text-blue-400">{metrics.avgResponseTimeMs.toFixed(1)}ms</p>
				<p class="text-xs text-gray-500 mt-1">Por cálculo</p>
			</div>
		</div>

		<!-- Perfiles de Routing -->
		{#if metrics.profilesUsed.length > 0}
			<div class="mb-6">
				<h3 class="text-sm font-semibold text-white mb-3">Perfiles de Routing</h3>
				<div class="space-y-3">
					{#each metrics.profilesUsed as profile}
						<div class={`neomorphic-inset rounded-xl p-4 bg-gradient-to-br from-background/30 to-background/10 border ${getProfileColor(profile.name)}`}>
							<div class="flex items-center justify-between mb-3">
								<div class="flex items-center gap-2">
									<Icon icon={getProfileIcon(profile.name)} width={20} />
									<span class="font-semibold capitalize">{profile.name}</span>
								</div>
								<span class="text-xs px-2 py-1 neomorphic-inset rounded">
									{profile.requests} requests
								</span>
							</div>
							<div class="grid grid-cols-4 gap-3 text-xs">
								<div>
									<p class="text-muted-foreground mb-1">Tiempo</p>
									<p class="font-semibold text-white">{profile.avgTimeMs.toFixed(1)}ms</p>
								</div>
								<div>
									<p class="text-muted-foreground mb-1">Distancia</p>
									<p class="font-semibold text-white">{profile.avgDistanceKm.toFixed(2)}km</p>
								</div>
								<div>
									<p class="text-muted-foreground mb-1">Puntos</p>
									<p class="font-semibold text-white">{profile.avgPoints}</p>
								</div>
								<div>
									<p class="text-muted-foreground mb-1">Nodos</p>
									<p class="font-semibold text-white">{profile.totalNodesVisited}</p>
								</div>
							</div>
						</div>
					{/each}
				</div>
			</div>
		{/if}

		<!-- Perfiles Activos como Chips -->
		<div class="neomorphic-inset rounded-xl p-4 bg-gradient-to-br from-background/30 to-background/10 mb-6">
			<div class="flex items-center justify-between mb-3">
				<h3 class="text-sm font-semibold text-white">Perfiles Configurados</h3>
				<span class="text-xs px-2 py-1 neomorphic-inset rounded text-cyan-300">
					{metrics.activeProfiles.length} activos
				</span>
			</div>
			{#if metrics.activeProfiles.length > 0}
				<div class="flex flex-wrap gap-2">
					{#each metrics.activeProfiles as profile}
						{@const details = getProfileDetails(profile)}
						<div 
							class={`group relative neomorphic-inset rounded-lg px-3 py-2 border transition-all hover:scale-105 cursor-pointer ${getProfileColor(profile)}`}
							title={details.description}
						>
							<div class="flex items-center gap-2">
								<Icon icon={getProfileIcon(profile)} width={16} />
								<span class="font-semibold capitalize text-xs">{profile}</span>
								<span class="text-[10px] opacity-70">{details.speed}</span>
							</div>
							
							<!-- Tooltip al hover -->
							<div class="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 hidden group-hover:block z-10">
								<div class="bg-gray-900 text-white text-xs rounded-lg px-3 py-2 shadow-xl border border-gray-700 whitespace-nowrap">
									<div class="font-semibold mb-1 capitalize">{profile}</div>
									<div class="text-gray-300 text-[10px] max-w-[200px] whitespace-normal">
										{details.description}
									</div>
									<div class="text-cyan-300 font-mono mt-1">{details.speed}</div>
								</div>
							</div>
						</div>
					{/each}
				</div>
			{:else}
				<p class="text-sm text-gray-500">No hay perfiles activos</p>
			{/if}
		</div>

		<!-- Última Ejecución -->
		<div class="neomorphic-inset rounded-xl p-4 bg-gradient-to-br from-background/30 to-background/10">
			<div class="flex items-center justify-between">
				<div class="flex items-center gap-2">
					<Icon icon="lucide:clock" width={16} class="text-gray-400" />
					<span class="text-xs text-muted-foreground">Último cálculo</span>
				</div>
				<span class="text-sm text-white font-medium">{formatLastRun(metrics.lastRequestAt)}</span>
			</div>
		</div>

		<!-- Información Técnica -->
		<div class="mt-6 pt-6 border-t border-white/5">
			<h3 class="text-xs text-muted-foreground uppercase tracking-wider mb-3">Algoritmo</h3>
			<div class="flex flex-wrap gap-2">
				<span class="neomorphic-inset px-3 py-1 text-orange-300 text-xs rounded-xl">
					A* Bidirectional
				</span>
				<span class="neomorphic-inset px-3 py-1 text-cyan-300 text-xs rounded-xl">
					Beeline Routing
				</span>
				<span class="neomorphic-inset px-3 py-1 text-pink-300 text-xs rounded-xl">
					OSM Santiago
				</span>
			</div>
		</div>
	{/if}
</div>
