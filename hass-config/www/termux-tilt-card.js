// enable Advanced mode in HASS in user settings
// add resource in http://192.168.1.178:8123/config/lovelace/resources
//  URL: /local/termux-tilt-card.js


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
      sampling_switch_entity: "switch.van_tilt_meter_live_sampling",
      calibration_source_entity: "sensor.van_tilt_meter_front_left_lift"
    };
  }

  setConfig(config) {
    const required = [
      "front_left_entity",
      "front_right_entity",
      "rear_left_entity",
      "rear_right_entity",
      "set_zero_button_entity"
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
    const state = this._hass?.states?.[this._config.calibration_source_entity || this._config.front_left_entity];
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

  _callTiltService(service) {
    this._hass.callService("termux_tilt", service, {});
  }

  _calibrationState() {
    const state = this._hass?.states?.[this._config.calibration_source_entity || this._config.front_left_entity];
    const attrs = state?.attributes || {};
    return {
      active: Boolean(attrs.calibration_active),
      hasModel: Boolean(attrs.calibration_has_model),
      step: attrs.calibration_step,
      stepIndex: Number.isFinite(Number(attrs.calibration_step_index)) ? Number(attrs.calibration_step_index) : 0,
      totalSteps: Number.isFinite(Number(attrs.calibration_total_steps)) ? Number(attrs.calibration_total_steps) : 0,
      instruction: attrs.calibration_instruction || "",
      progress: Number.isFinite(Number(attrs.calibration_progress)) ? Number(attrs.calibration_progress) : 0,
      targetLiftMm: Number.isFinite(Number(attrs.calibration_target_lift_mm)) ? Number(attrs.calibration_target_lift_mm) : 100,
      lastError: attrs.calibration_last_error || "",
      completedAt: attrs.calibration_completed_at || ""
    };
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
    const calibration = this._calibrationState();
    const calibrationPercent = Math.max(0, Math.min(100, Math.round(calibration.progress * 100)));
    const targetLiftCm = (calibration.targetLiftMm / 10).toFixed(1);
    const completedText = calibration.completedAt ? new Date(calibration.completedAt).toLocaleString() : "never";

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
          font-size: 1.3rem;
          font-weight: 700;
          box-shadow: 0 8px 16px rgba(2, 6, 23, 0.3);
          transform: translateZ(0);
          z-index: 2;
        }

        .wheel span {
          font-size: 0.76rem;
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

        .calibration-buttons {
          display: grid;
          grid-template-columns: 1fr 1fr 1fr;
          gap: 8px;
          margin-top: 10px;
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

        .buttons button.neutral {
          background: var(--tilt-accent-strong);
        }

        .buttons button.warn {
          background: #b91c1c;
        }

        .buttons button:disabled {
          opacity: 0.45;
          cursor: not-allowed;
        }

        .calibration {
          margin-top: 12px;
          border-radius: 10px;
          padding: 10px;
          border: 1px solid rgba(14, 165, 233, 0.25);
          background: rgba(255, 255, 255, 0.45);
          color: var(--tilt-text);
          font-size: 0.82rem;
        }

        .calibration-title {
          font-weight: 700;
          margin-bottom: 4px;
          font-size: 0.88rem;
        }

        .calibration-line {
          margin-top: 2px;
          color: var(--tilt-muted);
        }

        .calibration-line strong {
          color: var(--tilt-text);
        }

        .error {
          margin-top: 6px;
          color: #991b1b;
          font-weight: 600;
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

        <div class="calibration">
          <div class="calibration-title">Phone Mount Calibration</div>
          <div class="calibration-line"><strong>Status:</strong> ${calibration.active ? "Running" : (calibration.hasModel ? "Saved" : "Not calibrated")}</div>
          <div class="calibration-line"><strong>Target lift:</strong> ${targetLiftCm} cm per wheel step</div>
          <div class="calibration-line"><strong>Progress:</strong> ${calibrationPercent}% ${calibration.active && calibration.totalSteps > 0 ? `(${Math.min(calibration.stepIndex + 1, calibration.totalSteps)}/${calibration.totalSteps})` : ""}</div>
          <div class="calibration-line"><strong>Instruction:</strong> ${calibration.instruction || "Press Init calibration to begin."}</div>
          <div class="calibration-line"><strong>Last completed:</strong> ${completedText}</div>
          ${calibration.lastError ? `<div class="error">Calibration error: ${calibration.lastError}</div>` : ""}

          <div class="buttons calibration-buttons">
            <button id="calib-init" class="neutral">Init calibration</button>
            <button id="calib-capture" ${calibration.active ? "" : "disabled"}>Capture step</button>
            <button id="calib-cancel" class="warn" ${calibration.active ? "" : "disabled"}>Cancel</button>
          </div>
        </div>
      </ha-card>
    `;

    this.shadowRoot.getElementById("measure")?.addEventListener("click", () => {
      this._startMeasure();
    });

    this.shadowRoot.getElementById("setzero")?.addEventListener("click", () => {
      this._callService("button", "press", this._config.set_zero_button_entity);
    });

    this.shadowRoot.getElementById("calib-init")?.addEventListener("click", () => {
      this._callTiltService("start_calibration");
    });

    this.shadowRoot.getElementById("calib-capture")?.addEventListener("click", () => {
      this._callTiltService("capture_calibration_step");
    });

    this.shadowRoot.getElementById("calib-cancel")?.addEventListener("click", () => {
      this._callTiltService("cancel_calibration");
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
