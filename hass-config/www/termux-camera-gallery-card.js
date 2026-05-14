class TermuxCameraGalleryCard extends HTMLElement {
  setConfig(config) {
    const sensorEntity = config.sensor_entity || config.entity;
    if (!sensorEntity) {
      throw new Error("entity (or sensor_entity) is required");
    }
    this._config = {
      title: "Van Camera",
      service: "termux_camera_photo.capture_photo",
      ...config,
      sensor_entity: sensorEntity,
    };
  }

  set hass(hass) {
    this._hass = hass;
    this._render();
  }

  getCardSize() {
    return 5;
  }

  _render() {
    if (!this._hass || !this._config) {
      return;
    }

    const stateObj = this._hass.states[this._config.sensor_entity];
    const attrs = stateObj ? stateObj.attributes : {};
    const photos = Array.isArray(attrs.recent_photos) ? attrs.recent_photos : [];
    const lastError = attrs.last_error;
    const latestUrl = attrs.latest_photo_url;

    if (!this._root) {
      this._root = this.attachShadow({ mode: "open" });
    }

    this._root.innerHTML = `
      <style>
        ha-card {
          padding: 14px;
        }
        .header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 10px;
          margin-bottom: 10px;
        }
        .title {
          font-size: 1.1rem;
          font-weight: 600;
        }
        button {
          border: 0;
          border-radius: 8px;
          padding: 9px 12px;
          background: var(--primary-color);
          color: var(--text-primary-color);
          cursor: pointer;
          font-weight: 600;
        }
        .status {
          font-size: 0.85rem;
          margin-bottom: 10px;
          color: var(--secondary-text-color);
        }
        .status.error {
          color: var(--error-color);
        }
        .latest {
          margin-bottom: 12px;
        }
        .latest img {
          width: 100%;
          max-height: 240px;
          object-fit: cover;
          border-radius: 10px;
          border: 1px solid var(--divider-color);
        }
        .grid {
          display: grid;
          grid-template-columns: repeat(auto-fill, minmax(92px, 1fr));
          gap: 8px;
        }
        .thumb-wrap {
          position: relative;
        }
        .thumb {
          display: block;
          text-decoration: none;
        }
        .thumb img {
          width: 100%;
          height: 80px;
          object-fit: cover;
          border-radius: 8px;
          border: 1px solid var(--divider-color);
        }
        .delete-btn {
          position: absolute;
          top: 4px;
          right: 4px;
          border: 0;
          border-radius: 6px;
          padding: 4px 6px;
          font-size: 0.75rem;
          line-height: 1;
          background: var(--error-color);
          color: var(--primary-text-color);
          cursor: pointer;
        }
        .empty {
          color: var(--secondary-text-color);
          font-size: 0.9rem;
        }
      </style>
      <ha-card>
        <div class="header">
          <div class="title">${this._config.title}</div>
          <button id="capture-btn">Take picture</button>
        </div>
        ${lastError ? `<div class="status error">${lastError}</div>` : ""}
        ${latestUrl ? `<a class="latest" href="${latestUrl}" target="_blank" rel="noopener noreferrer"><img src="${latestUrl}" alt="Latest photo"></a>` : ""}
        ${photos.length === 0 ? "<div class='empty'>No photos yet.</div>" : ""}
        <div class="grid">
          ${photos
            .map(
              (photo) => `
                <div class="thumb-wrap">
                  <a class="thumb" href="${photo.url}" target="_blank" rel="noopener noreferrer" title="${photo.filename}">
                    <img src="${photo.url}" alt="${photo.filename}">
                  </a>
                  <button class="delete-btn" data-filename="${photo.filename}" title="Delete ${photo.filename}">Del</button>
                </div>
              `,
            )
            .join("")}
        </div>
      </ha-card>
    `;

    const captureButton = this._root.getElementById("capture-btn");
    if (captureButton) {
      captureButton.onclick = async () => {
        const [domain, service] = this._config.service.split(".");
        if (!domain || !service) {
          return;
        }
        await this._hass.callService(domain, service, this._config.service_data || {});
      };
    }

    const deleteButtons = this._root.querySelectorAll(".delete-btn");
    for (const deleteButton of deleteButtons) {
      deleteButton.onclick = async (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        const filename = deleteButton.getAttribute("data-filename");
        if (!filename) {
          return;
        }
        const confirmed = window.confirm(`Delete ${filename}?`);
        if (!confirmed) {
          return;
        }
        const payload = { filename };
        if (attrs.entry_id) {
          payload.entry_id = attrs.entry_id;
        }
        await this._hass.callService("termux_camera_photo", "delete_photo", payload);
      };
    }
  }
}

customElements.define("termux-camera-gallery-card", TermuxCameraGalleryCard);

window.customCards = window.customCards || [];
window.customCards.push({
  type: "termux-camera-gallery-card",
  name: "Termux Camera Gallery",
  description: "Capture photos and browse recent captures from Termux Camera Photo.",
});