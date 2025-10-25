<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import * as echarts from 'echarts';
  import type { ECharts } from 'echarts';
  import Icon from '@iconify/svelte';
  import { metricsStore } from '../stores/index.svelte';
  
  let chartContainer: HTMLDivElement;
  let chart: ECharts | null = null;
  let chartType = $state<'line' | 'gauge'>('line');
  
  // Historial de métricas para el gráfico de líneas
  let metricsHistory = $state<{
    timestamps: string[];
    cpu: number[];
    memory: number[];
    requests: number[];
  }>({
    timestamps: [],
    cpu: [],
    memory: [],
    requests: []
  });
  
  const MAX_HISTORY_POINTS = 30;
  
  async function fetchMetrics() {
    try {
      const response = await fetch('http://localhost:8080/api/stats/metrics');
      if (response.ok) {
        const data = await response.json();
        
        // Actualizar el store con datos reales
        const cpuMetric = metricsStore.find(m => m.name === 'CPU Usage');
        const memoryMetric = metricsStore.find(m => m.name === 'Memory');
        const requestsMetric = metricsStore.find(m => m.name === 'API Requests/min');
        
        if (cpuMetric) cpuMetric.value = Math.round(data.cpuUsage);
        if (memoryMetric) memoryMetric.value = data.memoryUsage;
        if (requestsMetric) requestsMetric.value = data.requestsPerMin;
        
        // Actualizar historial
        updateMetricsHistory();
      }
    } catch (error) {
      console.error('Error fetching metrics:', error);
    }
  }
  
  function updateMetricsHistory() {
    const now = new Date();
    const timeStr = now.toLocaleTimeString('es-CL', { 
      hour: '2-digit', 
      minute: '2-digit', 
      second: '2-digit' 
    });
    
    // Buscar métricas actuales
    const cpuMetric = metricsStore.find(m => m.name === 'CPU Usage');
    const memoryMetric = metricsStore.find(m => m.name === 'Memory');
    const requestsMetric = metricsStore.find(m => m.name === 'API Requests/min');
    
    metricsHistory.timestamps.push(timeStr);
    metricsHistory.cpu.push(typeof cpuMetric?.value === 'number' ? cpuMetric.value : 0);
    metricsHistory.memory.push(typeof memoryMetric?.value === 'number' ? memoryMetric.value : 0);
    metricsHistory.requests.push(typeof requestsMetric?.value === 'number' ? requestsMetric.value : 0);
    
    // Mantener solo los últimos N puntos
    if (metricsHistory.timestamps.length > MAX_HISTORY_POINTS) {
      metricsHistory.timestamps.shift();
      metricsHistory.cpu.shift();
      metricsHistory.memory.shift();
      metricsHistory.requests.shift();
    }
  }
  
  function initChart() {
    if (!chartContainer) return;
    
    chart = echarts.init(chartContainer, 'dark');
    updateChart();
    
    // Responsive resize
    window.addEventListener('resize', handleResize);
  }
  
  function handleResize() {
    chart?.resize();
  }
  
  function updateChart() {
    if (!chart) return;
    
    if (chartType === 'line') {
      updateLineChart();
    } else {
      updateGaugeChart();
    }
  }
  
  function updateLineChart() {
    const option = {
      backgroundColor: 'transparent',
      grid: {
        left: '3%',
        right: '4%',
        bottom: '12%',
        top: '18%',
        containLabel: true
      },
      tooltip: {
        trigger: 'axis',
        backgroundColor: 'rgba(15, 15, 20, 0.95)',
        borderColor: 'rgba(180, 180, 190, 0.5)',
        borderWidth: 1,
        textStyle: {
          color: '#fff',
          fontSize: 12
        },
        shadowBlur: 20,
        shadowColor: 'rgba(180, 180, 190, 0.3)'
      },
      legend: {
        data: ['CPU %', 'Memory MB', 'Requests/min'],
        textStyle: {
          color: '#a1a1aa',
          fontSize: 13
        },
        top: 5,
        itemGap: 20
      },
      xAxis: {
        type: 'category',
        boundaryGap: false,
        data: metricsHistory.timestamps,
        axisLine: {
          lineStyle: {
            color: 'rgba(255, 255, 255, 0.1)'
          }
        },
        axisLabel: {
          color: '#71717a',
          fontSize: 11,
          rotate: 45
        }
      },
      yAxis: {
        type: 'value',
        axisLine: {
          show: false
        },
        axisLabel: {
          color: '#71717a',
          fontSize: 11
        },
        splitLine: {
          lineStyle: {
            color: 'rgba(255, 255, 255, 0.05)',
            type: 'dashed'
          }
        }
      },
      series: [
        {
          name: 'CPU %',
          type: 'line',
          smooth: true,
          symbol: 'circle',
          symbolSize: 6,
          data: metricsHistory.cpu,
          lineStyle: {
            width: 3,
            color: new echarts.graphic.LinearGradient(0, 0, 1, 0, [
              { offset: 0, color: '#c8c8d2' },
              { offset: 1, color: '#a0a0aa' }
            ]),
            shadowColor: 'rgba(200, 200, 210, 0.5)',
            shadowBlur: 10
          },
          itemStyle: {
            color: '#c8c8d2',
            borderWidth: 2,
            borderColor: '#fff'
          },
          areaStyle: {
            color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
              { offset: 0, color: 'rgba(200, 200, 210, 0.3)' },
              { offset: 1, color: 'rgba(200, 200, 210, 0)' }
            ])
          }
        },
        {
          name: 'Memory MB',
          type: 'line',
          smooth: true,
          symbol: 'circle',
          symbolSize: 6,
          data: metricsHistory.memory,
          lineStyle: {
            width: 3,
            color: new echarts.graphic.LinearGradient(0, 0, 1, 0, [
              { offset: 0, color: '#a0a0aa' },
              { offset: 1, color: '#787882' }
            ]),
            shadowColor: 'rgba(160, 160, 170, 0.5)',
            shadowBlur: 10
          },
          itemStyle: {
            color: '#a0a0aa',
            borderWidth: 2,
            borderColor: '#fff'
          },
          areaStyle: {
            color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
              { offset: 0, color: 'rgba(160, 160, 170, 0.3)' },
              { offset: 1, color: 'rgba(160, 160, 170, 0)' }
            ])
          }
        },
        {
          name: 'Requests/min',
          type: 'line',
          smooth: true,
          symbol: 'circle',
          symbolSize: 6,
          data: metricsHistory.requests,
          lineStyle: {
            width: 3,
            color: new echarts.graphic.LinearGradient(0, 0, 1, 0, [
              { offset: 0, color: '#8c8c96' },
              { offset: 1, color: '#64646e' }
            ]),
            shadowColor: 'rgba(140, 140, 150, 0.5)',
            shadowBlur: 10
          },
          itemStyle: {
            color: '#8c8c96',
            borderWidth: 2,
            borderColor: '#fff'
          },
          areaStyle: {
            color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
              { offset: 0, color: 'rgba(140, 140, 150, 0.3)' },
              { offset: 1, color: 'rgba(140, 140, 150, 0)' }
            ])
          }
        }
      ]
    };
    
    chart?.setOption(option);
  }
  
  function updateGaugeChart() {
    const cpuMetric = metricsStore.find(m => m.name === 'CPU Usage');
    const cpuValue = typeof cpuMetric?.value === 'number' ? cpuMetric.value : 0;
    
    const option = {
      backgroundColor: 'transparent',
      series: [
        {
          type: 'gauge',
          startAngle: 180,
          endAngle: 0,
          center: ['50%', '75%'],
          radius: '90%',
          min: 0,
          max: 100,
          splitNumber: 10,
          axisLine: {
            lineStyle: {
              width: 8,
              color: [
                [0.3, new echarts.graphic.LinearGradient(0, 0, 1, 0, [
                  { offset: 0, color: '#b8b8c2' },
                  { offset: 1, color: '#c8c8d2' }
                ])],
                [0.7, new echarts.graphic.LinearGradient(0, 0, 1, 0, [
                  { offset: 0, color: '#909096' },
                  { offset: 1, color: '#a0a0aa' }
                ])],
                [1, new echarts.graphic.LinearGradient(0, 0, 1, 0, [
                  { offset: 0, color: '#68686e' },
                  { offset: 1, color: '#787882' }
                ])]
              ]
            }
          },
          pointer: {
            icon: 'path://M12.8,0.7l12,40.1H0.7L12.8,0.7z',
            length: '12%',
            width: 20,
            offsetCenter: [0, '-60%'],
            itemStyle: {
              color: new echarts.graphic.LinearGradient(0, 0, 1, 0, [
                { offset: 0, color: '#c8c8d2' },
                { offset: 1, color: '#a0a0aa' }
              ]),
              shadowColor: 'rgba(200, 200, 210, 0.6)',
              shadowBlur: 15
            }
          },
          axisTick: {
            length: 12,
            lineStyle: {
              color: 'auto',
              width: 2
            }
          },
          splitLine: {
            length: 20,
            lineStyle: {
              color: 'auto',
              width: 4
            }
          },
          axisLabel: {
            color: '#a1a1aa',
            fontSize: 14,
            distance: -60,
            rotate: 'tangential',
            formatter: function (value: number) {
              if (value === 0) {
                return '0';
              } else if (value === 50) {
                return '50';
              } else if (value === 100) {
                return '100';
              }
              return '';
            }
          },
          title: {
            offsetCenter: [0, '-10%'],
            fontSize: 18,
            color: '#a1a1aa',
            fontWeight: 'bold'
          },
          detail: {
            fontSize: 40,
            offsetCenter: [0, '-35%'],
            valueAnimation: true,
            formatter: function (value: number) {
              return Math.round(value) + ' %';
            },
            color: new echarts.graphic.LinearGradient(0, 0, 1, 0, [
              { offset: 0, color: '#c8c8d2' },
              { offset: 1, color: '#8c8c96' }
            ]),
            fontWeight: 'bold',
            rich: {
              value: {
                fontSize: 40,
                fontWeight: 'bold',
                color: '#fff'
              }
            }
          },
          data: [
            {
              value: cpuValue,
              name: 'CPU Usage'
            }
          ]
        }
      ]
    };
    
    chart?.setOption(option);
  }
  
  function toggleChartType() {
    chartType = chartType === 'line' ? 'gauge' : 'line';
    updateChart();
  }
  
  onMount(() => {
    initChart();
    
    // Fetch inicial
    fetchMetrics();
    
    // Actualizar métricas cada 5 segundos
    const metricsInterval = setInterval(fetchMetrics, 5000);
    
    // Actualizar gráfico cada 2 segundos (usa datos del store)
    const chartInterval = setInterval(() => {
      updateChart();
    }, 2000);
    
    return () => {
      clearInterval(metricsInterval);
      clearInterval(chartInterval);
    };
  });
  
  onDestroy(() => {
    window.removeEventListener('resize', handleResize);
    chart?.dispose();
  });
  
  // Reactivamente actualizar cuando cambian las métricas
  $effect(() => {
    // Este efecto se ejecuta cuando metricsStore cambia
    if (chart && metricsStore.length > 0) {
      updateChart();
    }
  });
</script>

<div class="neomorphic overflow-hidden h-full flex flex-col">
  <div class="px-6 py-4 border-b border-white/5 bg-gradient-to-r from-background/30 via-background/20 to-transparent shrink-0">
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-3">
        <div class="p-2 rounded-xl bg-gradient-to-br from-gray-400/20 to-gray-500/20 shadow-lg">
          <Icon icon="lucide:bar-chart-3" class="w-5 h-5 text-gray-300" />
        </div>
        <h2 class="text-lg font-bold gradient-text">Gráficos de Rendimiento</h2>
      </div>
      
      <button
        onclick={toggleChartType}
        class="px-4 py-2 text-xs font-semibold rounded-xl neomorphic-inset transition-all card-hover flex items-center gap-2 text-white"
      >
        <Icon icon={chartType === 'line' ? 'lucide:gauge' : 'lucide:line-chart'} class="w-4 h-4" />
        {chartType === 'line' ? 'Vista Gauge' : 'Vista Líneas'}
      </button>
    </div>
  </div>
  
  <div class="flex-1 p-4 overflow-hidden">
    <div bind:this={chartContainer} class="w-full h-full min-h-[300px]"></div>
  </div>
</div>
