// enable Advanced mode in HASS in user settings
// add resource in http://192.168.1.178:8123/config/lovelace/resources
//  URL: /local/termux-tilt-card-v2.js


class TermuxTiltCard extends HTMLElement {
  static getConfigElement() {
    return document.createElement("div");
  }

  static getStubConfig() {
    return {
      type: "custom:termux-tilt-card",
      title: "Van Tilt",
      front_left_entity: "sensor.van_tilt_meter_front_left_lift",
      front_right_entity: "sensor.van_tilt_meter_front_right_lift",
      rear_left_entity: "sensor.van_tilt_meter_rear_left_lift",
      rear_right_entity: "sensor.van_tilt_meter_rear_right_lift",
      set_zero_button_entity: "button.van_tilt_meter_set_zero",
      sampling_switch_entity: "switch.van_tilt_meter_live_sampling"
    };
  }

  setConfig(config) {
    const required = [
      "front_left_entity",
      "front_right_entity",
      "rear_left_entity",
      "rear_right_entity",
      "set_zero_button_entity",
      "sampling_switch_entity"
    ];

    for (const key of required) {
      if (!config[key]) {
        throw new Error(`Missing required config key: ${key}`);
      }
    }

    this._config = {
      title: "Van Tilt",
      ...config,
    };

    if (!this.shadowRoot) {
      this.attachShadow({ mode: "open" });
    }

    this._render();
  }

  set hass(hass) {
    this._hass = hass;
    if (this._config) {
      this._render();
    }
  }

  getCardSize() {
    return 4;
  }

  _valueCm(entityId) {
    const state = this._hass?.states?.[entityId];
    if (!state) {
      return "n/a";
    }

    const cm = Number(state.state);
    if (!Number.isFinite(cm)) {
      return "n/a";
    }

    return cm.toFixed(1);
  }

  _sampledAt() {
    const state = this._hass?.states?.[this._config.front_left_entity];
    const sampledAt = state?.attributes?.sampled_at;
    if (!sampledAt) {
      return "No sample yet";
    }

    const parsed = new Date(sampledAt);
    if (Number.isNaN(parsed.getTime())) {
      return "No sample yet";
    }

    return parsed.toLocaleString();
  }

  _isSamplingOn() {
    if (!this._config.sampling_switch_entity) {
      return false;
    }

    return this._hass?.states?.[this._config.sampling_switch_entity]?.state === "on";
  }

  _callService(domain, service, entityId) {
    if (!entityId) {
      return;
    }

    this._hass.callService(domain, service, {
      entity_id: entityId,
    });
  }

  _startMeasure() {
    this._callService("switch", "turn_on", this._config.sampling_switch_entity);
  }

  _render() {
    if (!this.shadowRoot || !this._config) {
      return;
    }

    const fl = this._valueCm(this._config.front_left_entity);
    const fr = this._valueCm(this._config.front_right_entity);
    const rl = this._valueCm(this._config.rear_left_entity);
    const rr = this._valueCm(this._config.rear_right_entity);
    const samplingOn = this._isSamplingOn();

    this.shadowRoot.innerHTML = `
      <style>
        :host {
          --tilt-bg: radial-gradient(circle at 10% 10%, #f6f9ff 0%, #e9eef7 55%, #dbe3f0 100%);
          --tilt-car: #1f2a37;
          --tilt-wheel: #111827;
          --tilt-wheel-ring: #6b7280;
          --tilt-text: #0f172a;
          --tilt-muted: #475569;
          --tilt-accent: #0ea5e9;
          --tilt-accent-strong: #0284c7;
          --tilt-danger: #ef4444;
          --tilt-border: rgba(15, 23, 42, 0.15);
          display: block;
        }

        ha-card {
          padding: 16px;
          background: var(--tilt-bg);
          border: 1px solid var(--tilt-border);
          overflow: hidden;
        }

        .header {
          display: flex;
          justify-content: space-between;
          align-items: baseline;
          margin-bottom: 12px;
          color: var(--tilt-text);
        }

        .title {
          font-size: 1.1rem;
          font-weight: 700;
          letter-spacing: 0.01em;
        }

        .sampled {
          font-size: 0.76rem;
          color: var(--tilt-muted);
          text-align: right;
        }

        .layout {
          position: relative;
          margin: 8px 0 14px;
          min-height: 200px;
        }

        .car {
          position: absolute;
          left: 18%;
          right: 18%;
          top: 28px;
          bottom: 28px;
          background: linear-gradient(180deg, #334155 0%, var(--tilt-car) 100%);
          border-radius: 18px;
          box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.12), 0 12px 22px rgba(15, 23, 42, 0.22);
          overflow: hidden;
        }

        .car img {
          position: absolute;
          inset: 0;
          width: 100%;
          height: 100%;
          object-fit: contain;
          opacity: 0.96;
        }

        .wheel {
          position: absolute;
          width: 78px;
          height: 78px;
          border-radius: 50%;
          background: radial-gradient(circle at 30% 30%, #374151 0%, var(--tilt-wheel) 60%);
          border: 3px solid var(--tilt-wheel-ring);
          color: #f8fafc;
          display: flex;
          align-items: center;
          justify-content: center;
          flex-direction: column;
          font-size: 0.82rem;
          font-weight: 700;
          box-shadow: 0 8px 16px rgba(2, 6, 23, 0.3);
          transform: translateZ(0);
          z-index: 2;
        }

        .wheel span {
          font-size: 0.66rem;
          font-weight: 500;
          opacity: 0.88;
          margin-top: 2px;
        }

        .fl { top: 0; left: 0; }
        .fr { top: 0; right: 0; }
        .rl { bottom: 0; left: 0; }
        .rr { bottom: 0; right: 0; }

        .buttons {
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: 10px;
        }

        .buttons button {
          border: none;
          border-radius: 10px;
          padding: 10px 12px;
          font-size: 0.9rem;
          font-weight: 700;
          letter-spacing: 0.01em;
          cursor: pointer;
          color: #f8fafc;
          background: var(--tilt-accent);
          transition: transform 0.08s ease, filter 0.08s ease;
        }

        .buttons button:active {
          transform: translateY(1px) scale(0.995);
          filter: brightness(0.94);
        }

        .buttons button.secondary {
          background: var(--tilt-danger);
        }

        .sampling {
          margin-top: 10px;
          border-radius: 10px;
          padding: 8px 10px;
          font-size: 0.8rem;
          font-weight: 600;
          color: ${samplingOn ? "#064e3b" : "#7f1d1d"};
          background: ${samplingOn ? "rgba(16, 185, 129, 0.2)" : "rgba(248, 113, 113, 0.2)"};
          border: 1px solid ${samplingOn ? "rgba(16, 185, 129, 0.35)" : "rgba(248, 113, 113, 0.35)"};
        }
      </style>

      <ha-card>
        <div class="header">
          <div class="title">${this._config.title}</div>
          <div class="sampled">Last sample:<br>${this._sampledAt()}</div>
        </div>

        <div class="layout">
          <div class="car"><img src="/local/van-top.png" alt="Van top view"></div>
          <div class="wheel fl">${fl}<span>cm</span></div>
          <div class="wheel fr">${fr}<span>cm</span></div>
          <div class="wheel rl">${rl}<span>cm</span></div>
          <div class="wheel rr">${rr}<span>cm</span></div>
        </div>

        <div class="buttons">
          <button id="measure">Start measure (5 min)</button>
          <button id="setzero" class="secondary">Set zero</button>
        </div>

        ${this._config.sampling_switch_entity ? `<div class="sampling">Live sampling: ${samplingOn ? "ON (auto-stops after 5 min)" : "OFF"}</div>` : ""}
      </ha-card>
    `;

    this.shadowRoot.getElementById("measure")?.addEventListener("click", () => {
      this._startMeasure();
    });

    this.shadowRoot.getElementById("setzero")?.addEventListener("click", () => {
      this._callService("button", "press", this._config.set_zero_button_entity);
    });
  }
}

customElements.define("termux-tilt-card", TermuxTiltCard);
window.customCards = window.customCards || [];
window.customCards.push({
  type: "termux-tilt-card",
  name: "Termux Tilt Card",
  description: "Visualizes wheel lift heights in cm with live sampling and zeroing controls.",
});
