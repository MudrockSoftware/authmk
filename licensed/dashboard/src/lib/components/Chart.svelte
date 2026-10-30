<script lang="ts">
  import {
    ArcElement,
    CategoryScale,
    Chart,
    DoughnutController,
    Filler,
    Legend,
    LinearScale,
    LineController,
    LineElement,
    PointElement,
    Tooltip,
    type ChartConfiguration
  } from "chart.js";
  import { theme } from "#lib/theme.svelte.ts";

  Chart.register(LineController, LineElement, PointElement, LinearScale, CategoryScale, Filler, Tooltip, Legend, DoughnutController, ArcElement);

  type Series = { label: string; data: number[]; colour: "primary" | "secondary" | "accent" };

  let {
    kind,
    labels,
    series,
    label
  }: { kind: "line" | "doughnut"; labels: string[]; series: Series[]; label: string } = $props();

  let canvas: HTMLCanvasElement;

  // Colours come from the daisyUI theme, so charts follow light and dark.
  function token(name: string): string {
    return getComputedStyle(document.documentElement).getPropertyValue(`--color-${name}`).trim();
  }

  // The theme's colours are hex: a light fill under each line.
  function faint(colour: string): string {
    return /^#[0-9a-f]{6}$/i.test(colour) ? `${colour}24` : colour;
  }

  function config(): ChartConfiguration<"line"> | ChartConfiguration<"doughnut"> {
    const text = token("base-content");
    const grid = token("base-300");
    const font = { family: getComputedStyle(document.body).fontFamily };

    if (kind === "doughnut") {
      const palette = ["primary", "secondary", "accent", "info", "success", "warning"].map(token);
      return {
        type: "doughnut",
        data: {
          labels,
          datasets: [{ label: series[0]?.label, data: series[0]?.data ?? [], backgroundColor: palette, borderColor: token("base-100"), borderWidth: 2 }]
        },
        options: {
          responsive: true,
          maintainAspectRatio: false,
          cutout: "62%",
          plugins: { legend: { position: "bottom", labels: { color: text, font, usePointStyle: true } } }
        }
      };
    }

    return {
      type: "line",
      data: {
        labels,
        datasets: series.map((s) => ({
          label: s.label,
          data: s.data,
          borderColor: token(s.colour),
          backgroundColor: faint(token(s.colour)),
          fill: true,
          tension: 0.35,
          pointRadius: 0,
          pointHoverRadius: 4,
          borderWidth: 2
        }))
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: "index", intersect: false },
        scales: {
          x: { ticks: { color: text, font, maxTicksLimit: 8 }, grid: { display: false } },
          y: { beginAtZero: true, ticks: { color: text, font, precision: 0 }, grid: { color: grid } }
        },
        plugins: { legend: { labels: { color: text, font, usePointStyle: true } } }
      }
    };
  }

  $effect(() => {
    // Redraws when the data or the theme changes.
    void theme.version;
    void labels;
    void series;
    const chart = new Chart(canvas, config() as ChartConfiguration);
    return () => chart.destroy();
  });
</script>

<div class="relative h-64" role="img" aria-label={label}>
  <canvas bind:this={canvas}></canvas>
</div>
