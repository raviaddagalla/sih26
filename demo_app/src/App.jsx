import React, { useState, useEffect, useRef } from 'react';
import { MapContainer, TileLayer, Marker, Polyline, useMap } from 'react-leaflet';
import 'leaflet/dist/leaflet.css';
import L from 'leaflet';
import './index.css';

// Fix leaflet icon issues
delete L.Icon.Default.prototype._getIconUrl;
L.Icon.Default.mergeOptions({
  iconRetinaUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.7.1/images/marker-icon-2x.png',
  iconUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.7.1/images/marker-icon.png',
  shadowUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.7.1/images/marker-shadow.png',
});

// Custom circle icons for trackers
const createCircleIcon = (color) => {
  return L.divIcon({
    className: 'custom-div-icon',
    html: `<div style="background-color: ${color}; width: 16px; height: 16px; border-radius: 50%; border: 2px solid white; box-shadow: 0 0 10px ${color}80;"></div>`,
    iconSize: [16, 16],
    iconAnchor: [8, 8]
  });
};

const actualIcon = createCircleIcon('#10b981');
const rbpfIcon = createCircleIcon('#3b82f6');
const rawIcon = createCircleIcon('#ef4444');

// Datasets registry with genuine 10Hz IO-VNBD and 100Hz RoadSens
const DATASETS = {
  roadsens: {
    id: 'roadsens',
    name: 'RoadSens Model (Default)',
    shortName: 'RoadSens (100 Hz)',
    tag: 'Indian Road Conditions & Pothole Dynamics',
    architecture: 'Velocity CNN (Feature Set C)',
    sensors: '100 Hz High-Frequency IMU (Linear Accel + Gyro)',
    file: '/trajectory.json',
    location: 'West Bengal, India',
    badge: 'DEFAULT',
    stats: '21.4 km Path • High Pavement Vibration'
  },
  iovnbd: {
    id: 'iovnbd',
    name: 'IO-VNBD 10Hz Model',
    shortName: 'IO-VNBD (10 Hz)',
    tag: 'Direct from IO-VNBD-master (Trip S1)',
    architecture: 'Stateful GRU (12-Channel Recurrent Network)',
    sensors: '10 Hz Android Smartphone IMU (Low-Frequency)',
    file: '/trajectory_iovnbd.json',
    location: 'Coventry, United Kingdom',
    badge: '10 HZ IMU',
    stats: '19.4 km Path • 27.9% Raw Drift • 12.6% Fused'
  }
};

// Component to dynamically set map center when position or dataset changes
const MapUpdater = ({ center, isDatasetSwitch }) => {
  const map = useMap();
  useEffect(() => {
    if (center) {
      if (isDatasetSwitch) {
        map.flyTo(center, 13, { duration: 1.5 });
      } else {
        map.setView(center, map.getZoom());
      }
    }
  }, [center, map, isDatasetSwitch]);
  return null;
};

// Main App Component
function App() {
  const [selectedDataset, setSelectedDataset] = useState('roadsens');
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [data, setData] = useState(null);
  const [currentIndex, setCurrentIndex] = useState(0);
  const [isPlaying, setIsPlaying] = useState(false);
  const [speed, setSpeed] = useState(1);
  const [justSwitched, setJustSwitched] = useState(false);
  const animationRef = useRef(null);

  // Load trajectory data whenever selectedDataset changes
  useEffect(() => {
    setIsPlaying(false);
    setCurrentIndex(0);
    setJustSwitched(true);
    
    const config = DATASETS[selectedDataset];
    fetch(config.file)
      .then(res => res.json())
      .then(json => {
        // Data format: { actual: [[lon, lat], ...], raw: [...], rbpf: [...] }
        // Leaflet expects [lat, lon]
        const formatPath = (path) => path.map(coord => [coord[1], coord[0]]);
        
        const actual = formatPath(json.actual);
        const rbpf = formatPath(json.rbpf);
        const raw = formatPath(json.raw || json.actual);
        
        // Calculate cumulative distance for actual path
        const calcDist = (p1, p2) => Math.sqrt(Math.pow(p1[0]-p2[0], 2) + Math.pow(p1[1]-p2[1], 2)) * 111139;
        const distances = [0];
        let cum = 0;
        for (let i = 1; i < actual.length; i++) {
          cum += calcDist(actual[i-1], actual[i]);
          distances.push(cum);
        }

        setData({ actual, rbpf, raw, distances, metadata: json.metadata });
        
        // Reset the flyTo trigger after brief moment
        setTimeout(() => setJustSwitched(false), 1600);
      })
      .catch(err => {
        console.error("Failed to load trajectory:", err);
      });
  }, [selectedDataset]);

  const togglePlay = () => {
    setIsPlaying(!isPlaying);
  };

  const reset = () => {
    setIsPlaying(false);
    setCurrentIndex(0);
  };

  const handleSelectDataset = (key) => {
    if (key !== selectedDataset) {
      setSelectedDataset(key);
    }
    setIsSettingsOpen(false);
  };

  useEffect(() => {
    if (isPlaying && data) {
      const animate = () => {
        setCurrentIndex(prev => {
          if (prev < data.actual.length - 1) return prev + 1;
          setIsPlaying(false);
          return prev;
        });
      };
      const intervalMs = 100 / speed;
      animationRef.current = setInterval(animate, intervalMs);
    } else {
      clearInterval(animationRef.current);
    }
    return () => clearInterval(animationRef.current);
  }, [isPlaying, data, speed]);

  if (!data) {
    return (
      <div style={{display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100vh', width: '100vw'}}>
        <h2>Loading {DATASETS[selectedDataset].name} Data...</h2>
      </div>
    );
  }

  const currentActual = data.actual[currentIndex] || data.actual[0];
  const currentRbpf = data.rbpf[currentIndex] || data.rbpf[0];
  const currentRaw = data.raw ? (data.raw[currentIndex] || data.raw[0]) : currentActual;

  // Calculate stats for the overlay
  const progress = Math.round((currentIndex / (data.actual.length - 1 || 1)) * 100);
  
  // Calculate drift error between actual and rbpf
  const calcDist = (p1, p2) => Math.sqrt(Math.pow(p1[0]-p2[0], 2) + Math.pow(p1[1]-p2[1], 2)) * 111139;
  const currentDriftRbpf = calcDist(currentActual, currentRbpf).toFixed(1);
  const currentDriftRaw = calcDist(currentActual, currentRaw).toFixed(1);
  const currentDistance = ((data.distances[currentIndex] || 0) / 1000).toFixed(2); // in km

  const activeMeta = DATASETS[selectedDataset];

  return (
    <>
      <header className="header">
        <div className="header-brand">
          <h1>Intelligent Dead Reckoning</h1>
          <p>SIH 2026 Navigation Benchmark</p>
          <div className="dataset-pill" title={`Active Dataset: ${activeMeta.name}`}>
            <span className="pill-dot"></span>
            <span className="pill-text">{activeMeta.shortName}</span>
          </div>
        </div>

        {/* Top Right Settings Trigger Button */}
        <button 
          id="settings-button"
          className="settings-trigger-btn"
          onClick={() => setIsSettingsOpen(true)}
          title="Open Model & Dataset Settings"
          aria-label="Settings"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="12" cy="12" r="3"></circle>
            <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"></path>
          </svg>
          <span>Settings</span>
        </button>
      </header>

      <main className="map-container">
        <MapContainer center={currentActual} zoom={13} scrollWheelZoom={true}>
          <TileLayer
            attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
            url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
          />
          <MapUpdater center={currentActual} isDatasetSwitch={justSwitched} />

          {/* Paths drawn so far */}
          <Polyline positions={data.actual.slice(0, currentIndex + 1)} color="#10b981" weight={4} opacity={0.6} />
          <Polyline positions={data.rbpf.slice(0, currentIndex + 1)} color="#3b82f6" weight={4} opacity={0.8} />

          {/* Current Position Trackers */}
          <Marker position={currentActual} icon={actualIcon} zIndexOffset={100} />
          <Marker position={currentRbpf} icon={rbpfIcon} zIndexOffset={90} />
        </MapContainer>

        {/* Live Telemetry Overlay */}
        <div className="stats-overlay">
          <div className="stat-item">
            <span className="stat-label">Model in Demo</span>
            <span className="stat-value" style={{color: '#4f46e5', fontSize: '1.05rem'}}>
              {activeMeta.shortName}
            </span>
          </div>

          <div className="stat-item">
            <span className="stat-label">System Status</span>
            <span className="stat-value" style={{color: '#ef4444'}}>GNSS OUTAGE</span>
          </div>

          <div className="stat-item">
            <span className="stat-label">Progress</span>
            <span className="stat-value">{progress}%</span>
          </div>
          
          <div className="stat-item">
            <span className="stat-label">Distance Traveled</span>
            <span className="stat-value">{currentDistance} km</span>
          </div>

          <div className="stat-item">
            <span className="stat-label">Map-Matched Drift</span>
            <span className="stat-value" style={{color: '#3b82f6'}}>{currentDriftRbpf} meters</span>
          </div>

          {selectedDataset === 'iovnbd' && (
            <div className="stat-item">
              <span className="stat-label">Raw 10Hz Unbounded Drift</span>
              <span className="stat-value" style={{color: '#ef4444', fontSize: '0.95rem'}}>
                {currentDriftRaw > 1000 ? `${(currentDriftRaw/1000).toFixed(1)} km` : `${currentDriftRaw} m`}
              </span>
            </div>
          )}

          <div className="legend-container">
            <div className="legend-item">
              <div className="legend-color color-actual"></div>
              <span>Actual Ground Truth (Hidden)</span>
            </div>
            <div className="legend-item">
              <div className="legend-color color-rbpf"></div>
              <span>RBPF Fused Output</span>
            </div>
          </div>

          <div className="controls">
            <button className="btn" onClick={togglePlay}>
              {isPlaying ? 'Pause' : 'Play'}
            </button>
            <button className="btn" onClick={reset} style={{background: '#e2e8f0', color: '#1e293b'}}>
              Reset
            </button>
            <select 
              className="speed-select" 
              value={speed} 
              onChange={(e) => setSpeed(Number(e.target.value))}
              title="Playback Speed"
            >
              <option value={0.1}>0.1x</option>
              <option value={0.25}>0.25x</option>
              <option value={0.5}>0.5x</option>
              <option value={1}>1x</option>
              <option value={2}>2x</option>
              <option value={5}>5x</option>
              <option value={10}>10x</option>
            </select>
          </div>
        </div>

        {/* Settings Window / Modal */}
        {isSettingsOpen && (
          <div className="settings-modal-backdrop" onClick={() => setIsSettingsOpen(false)}>
            <div 
              className="settings-modal-window" 
              onClick={(e) => e.stopPropagation()}
              role="dialog"
              aria-modal="true"
              aria-labelledby="settings-title"
            >
              <div className="settings-modal-header">
                <div>
                  <h2 id="settings-title">Benchmark Model Selection</h2>
                  <p className="settings-modal-subtitle">Choose between the high-frequency RoadSens model and the 10 Hz IO-VNBD benchmark model</p>
                </div>
                <button 
                  className="settings-close-btn"
                  onClick={() => setIsSettingsOpen(false)}
                  aria-label="Close settings window"
                >
                  &times;
                </button>
              </div>

              <div className="settings-cards-container">
                {/* RoadSens Card (Default) */}
                <div 
                  className={`dataset-card ${selectedDataset === 'roadsens' ? 'active' : ''}`}
                  onClick={() => handleSelectDataset('roadsens')}
                >
                  <div className="card-top">
                    <div className="card-title-group">
                      <h3>RoadSens Model Demo</h3>
                      <span className="badge badge-default">DEFAULT • 100 HZ</span>
                    </div>
                    {selectedDataset === 'roadsens' && (
                      <span className="check-icon" title="Currently Active">✓ Active</span>
                    )}
                  </div>
                  <p className="card-desc">Indian Road Conditions, Potholes & High Dynamic Vibration (High Frequency)</p>
                  <div className="card-specs">
                    <div className="spec-row">
                      <span className="spec-label">Architecture:</span>
                      <span className="spec-val">Velocity CNN (Feature Set C)</span>
                    </div>
                    <div className="spec-row">
                      <span className="spec-label">Sampling Rate:</span>
                      <span className="spec-val">100 Hz IMU (Linear Accel + Gyro)</span>
                    </div>
                    <div className="spec-row">
                      <span className="spec-label">Location:</span>
                      <span className="spec-val">West Bengal, India</span>
                    </div>
                    <div className="spec-row">
                      <span className="spec-label">Drift:</span>
                      <span className="spec-val">&lt; 5% Map-Matched</span>
                    </div>
                  </div>
                  <button 
                    className={`card-select-btn ${selectedDataset === 'roadsens' ? 'btn-current' : 'btn-switch'}`}
                    onClick={(e) => { e.stopPropagation(); handleSelectDataset('roadsens'); }}
                  >
                    {selectedDataset === 'roadsens' ? 'Currently Loaded' : 'Switch to RoadSens Model'}
                  </button>
                </div>

                {/* Genuine 10Hz IO-VNBD Card */}
                <div 
                  className={`dataset-card ${selectedDataset === 'iovnbd' ? 'active' : ''}`}
                  onClick={() => handleSelectDataset('iovnbd')}
                >
                  <div className="card-top">
                    <div className="card-title-group">
                      <h3>IO-VNBD 10Hz Model Demo</h3>
                      <span className="badge badge-iovnbd">10 HZ SMARTPHONE</span>
                    </div>
                    {selectedDataset === 'iovnbd' && (
                      <span className="check-icon" title="Currently Active">✓ Active</span>
                    )}
                  </div>
                  <p className="card-desc">Extracted directly from D:\Nandhu\dead reckoning\IO-VNBD-master (Trip S1, 19.4 km Coventry UK). Shows realistic 10 Hz physical dead reckoning without GPS, displaying authentic drift progression.</p>
                  <div className="card-specs">
                    <div className="spec-row">
                      <span className="spec-label">Architecture:</span>
                      <span className="spec-val">Stateful GRU (12 Channels)</span>
                    </div>
                    <div className="spec-row">
                      <span className="spec-label">Sampling Rate:</span>
                      <span className="spec-val">10 Hz (Android Smartphone)</span>
                    </div>
                    <div className="spec-row">
                      <span className="spec-label">Location:</span>
                      <span className="spec-val">Coventry, United Kingdom</span>
                    </div>
                    <div className="spec-row">
                      <span className="spec-label">Raw Open-Loop Drift:</span>
                      <span className="spec-val" style={{color: '#ef4444'}}>27.9% (5.4 km error)</span>
                    </div>
                    <div className="spec-row">
                      <span className="spec-label">Map-Matched / Fused Drift:</span>
                      <span className="spec-val" style={{color: '#f59e0b'}}>12.6% (2.4 km error)</span>
                    </div>
                  </div>
                  <button 
                    className={`card-select-btn ${selectedDataset === 'iovnbd' ? 'btn-current' : 'btn-switch'}`}
                    onClick={(e) => { e.stopPropagation(); handleSelectDataset('iovnbd'); }}
                  >
                    {selectedDataset === 'iovnbd' ? 'Currently Loaded' : 'Switch to IO-VNBD 10Hz Model'}
                  </button>
                </div>
              </div>

              <div className="settings-modal-footer">
                <span className="settings-hint">Select a model to simulate its trajectory and view dead-reckoning performance.</span>
                <button 
                  className="btn btn-close-modal"
                  onClick={() => setIsSettingsOpen(false)}
                >
                  Done
                </button>
              </div>
            </div>
          </div>
        )}
      </main>
    </>
  );
}

export default App;
