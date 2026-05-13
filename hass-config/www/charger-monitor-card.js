/**
 * charger-monitor-card.js
 * Custom Lovelace card showing a solar power-flow diagram:
 *   Solar Panel --> Battery --> Load
 * Place at hass-config/www/charger-monitor-card.js
 * Register via: Settings -> Dashboards -> Resources -> /local/charger-monitor-card.js
 *
 * Usage in dashboard YAML:
 *   type: custom:charger-monitor-card
 *   entity_prefix: sensor.charger_monitor_   # (optional, default shown)
 */
class ChargerMonitorCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: "open" });
  }

  setConfig(config) {
    this._prefix = config.entity_prefix || "sensor.charger_monitor_";
    this._render();
  }

  set hass(hass) {
    this._hass = hass;
    this._updateValues();
  }

  _render() {
    this.shadowRoot.innerHTML = `
      <style>
        :host { display: block; }
        ha-card {
          padding: 16px;
          font-family: var(--primary-font-family, sans-serif);
        }
        .title {
          font-size: 1.1em;
          font-weight: 600;
          margin-bottom: 12px;
          color: var(--primary-text-color);
          display: flex;
          align-items: center;
          gap: 8px;
        }
        .status-dot {
          width: 10px; height: 10px;
          border-radius: 50%;
          background: #9e9e9e;
          display: inline-block;
          flex-shrink: 0;
        }
        .status-dot.connected { background: #4caf50; }
        .status-dot.connecting { background: #ff9800; }
        .flow-grid {
          display: grid;
          grid-template-columns: 1fr 40px 1fr 40px 1fr;
          align-items: center;
          gap: 4px;
          margin: 16px 0;
        }
        .node {
          background: var(--card-background-color, #fff);
          border: 2px solid var(--divider-color, #ccc);
          border-radius: 12px;
          padding: 10px 6px;
          text-align: center;
        }
        .node.solar { border-color: #f9a825; }
        .node.battery { border-color: #1e88e5; }
        .node.load { border-color: #43a047; }
        .node-icon { font-size: 1.6em; }
        .node-label {
          font-size: 0.7em;
          color: var(--secondary-text-color);
          margin: 2px 0;
        }
        .node-value {
          font-size: 1.05em;
          font-weight: 600;
          color: var(--primary-text-color);
        }
        .node-sub {
          font-size: 0.75em;
          color: var(--secondary-text-color);
        }
        .arrow {
          text-align: center;
          font-size: 1.4em;
          color: var(--secondary-text-color);
        }
        .metrics-row {
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: 8px;
          margin-top: 8px;
        }
        .metric {
          background: var(--secondary-background-color, #f5f5f5);
          border-radius: 8px;
          padding: 8px 10px;
        }
        .metric-label {
          font-size: 0.72em;
          color: var(--secondary-text-color);
        }
        .metric-value {
          font-size: 1em;
          font-weight: 600;
          color: var(--primary-text-color);
        }
        .flags-row {
          display: flex;
          flex-wrap: wrap;
          gap: 6px;
          margin-top: 10px;
        }
        .flag {
          display: flex;
          align-items: center;
          gap: 4px;
          font-size: 0.78em;
          padding: 3px 8px;
          border-radius: 12px;
          background: var(--secondary-background-color, #f5f5f5);
          color: var(--secondary-text-color);
        }
        .flag.on { background: #e8f5e9; color: #2e7d32; }
        .flag.warn { background: #fff3e0; color: #e65100; }
        .flag-dot { width: 7px; height: 7px; border-radius: 50%; background: currentColor; }
      </style>
      <ha-card>
        <div class="title">
          <span class="status-dot" id="status-dot"></span>
          <span id="title-text">Charger Monitor</span>
        </div>

        <div class="flow-grid">
          <div class="node solar">
            <div class="node-icon">☀️</div>
            <div class="node-label">Solar</div>
            <div class="node-value" id="solar-power">—</div>
            <div class="node-sub" id="solar-voltage">—</div>
          </div>
          <div class="arrow">→</div>
          <div class="node battery">
            <div class="node-icon">🔋</div>
            <div class="node-label">Battery</div>
            <div class="node-value" id="batt-voltage">—</div>
            <div class="node-sub" id="batt-current">—</div>
          </div>
          <div class="arrow">→</div>
          <div class="node load">
            <div class="node-icon">⚡</div>
            <div class="node-label">Load</div>
            <div class="node-value" id="load-power">—</div>
            <div class="node-sub" id="load-current">—</div>
          </div>
        </div>

        <div class="metrics-row">
          <div class="metric">
            <div class="metric-label">Charge today</div>
            <div class="metric-value" id="charge-cap">—</div>
          </div>
          <div class="metric">
            <div class="metric-label">Energy today</div>
            <div class="metric-value" id="charge-energy">—</div>
          </div>
          <div class="metric">
            <div class="metric-label">Start battery</div>
            <div class="metric-value" id="start-batt">—</div>
          </div>
          <div class="metric">
            <div class="metric-label">Device</div>
            <div class="metric-value" id="device-type">—</div>
          </div>
        </div>

        <div class="flags-row" id="flags-row"></div>
      </ha-card>
    `;
  }

  _st(entityId) {
    if (!this._hass) return null;
    const s = this._hass.states[entityId];
    return s ? s.state : null;
  }

  _num(entityId, decimals = 1) {
    const v = this._st(entityId);
    if (v == null || v === "unavailable" || v === "unknown") return "—";
    const n = parseFloat(v);
    return isNaN(n) ? "—" : n.toFixed(decimals);
  }

  _updateValues() {
    if (!this._hass || !this.shadowRoot.querySelector("#solar-power")) return;

    const p = this._prefix;
    const conn = this._st(p + "connection_status") || "unavailable";

    // Status dot
    const dot = this.shadowRoot.getElementById("status-dot");
    dot.className = "status-dot " + (conn === "connected" ? "connected" : conn === "connecting" ? "connecting" : "");

    // Title
    const deviceType = this._st(p + "device_type") || "";
    this.shadowRoot.getElementById("title-text").textContent =
      "Charger Monitor" + (deviceType && deviceType !== "unavailable" ? " — " + deviceType : "");

    // Flow nodes
    this.shadowRoot.getElementById("solar-power").textContent = this._num(p + "solar_panel_power", 0) + " W";
    this.shadowRoot.getElementById("solar-voltage").textContent = this._num(p + "solar_panel_voltage") + " V";
    this.shadowRoot.getElementById("batt-voltage").textContent = this._num(p + "battery_voltage", 2) + " V";
    this.shadowRoot.getElementById("batt-current").textContent = this._num(p + "battery_current") + " A";
    this.shadowRoot.getElementById("load-power").textContent = this._num(p + "load_power", 0) + " W";
    this.shadowRoot.getElementById("load-current").textContent = this._num(p + "load_current") + " A";

    // Metrics
    const capRaw = this._st(p + "charge_capacity");
    this.shadowRoot.getElementById("charge-cap").textContent =
      capRaw && capRaw !== "unavailable" ? parseFloat(capRaw).toFixed(0) + " Ah" : "—";
    const enRaw = this._st(p + "charge_energy");
    this.shadowRoot.getElementById("charge-energy").textContent =
      enRaw && enRaw !== "unavailable" ? parseFloat(enRaw).toFixed(0) + " Wh" : "—";
    this.shadowRoot.getElementById("start-batt").textContent =
      this._num(p + "starting_battery_voltage") + " V";
    this.shadowRoot.getElementById("device-type").textContent =
      (deviceType && deviceType !== "unavailable") ? deviceType : "—";

    // Binary flags — use binary_sensor.chargermonitor_<key>
    const bsPrefix = "binary_sensor.charger_monitor_";
    const flags = [
      { key: "charge_state", label: "Charging", warn: false },
      { key: "full_charge", label: "Full", warn: false },
      { key: "over_temp", label: "Over-Temp", warn: true },
      { key: "battery_over_pressure", label: "Batt OV", warn: true },
      { key: "pv_over_pressure", label: "PV OV", warn: true },
      { key: "battery_under_voltage", label: "Batt UV", warn: true },
    ];
    const flagsRow = this.shadowRoot.getElementById("flags-row");
    flagsRow.innerHTML = "";
    for (const f of flags) {
      const state = this._hass.states["binary_sensor.chargermonitor_" + f.key];
      if (!state) continue;
      const isOn = state.state === "on";
      const div = document.createElement("div");
      div.className = "flag" + (isOn ? (f.warn ? " warn" : " on") : "");
      div.innerHTML = `<span class="flag-dot"></span>${f.label}`;
      flagsRow.appendChild(div);
    }
  }

  getCardSize() { return 4; }

  static getConfigElement() {
    return document.createElement("charger-monitor-card-editor");
  }

  static getStubConfig() {
    return { entity_prefix: "sensor.charger_monitor_" };
  }
}

customElements.define("charger-monitor-card", ChargerMonitorCard);
window.customCards = window.customCards || [];
window.customCards.push({
  type: "charger-monitor-card",
  name: "Charger Monitor",
  description: "Solar power-flow diagram for the van charger monitor.",
});
