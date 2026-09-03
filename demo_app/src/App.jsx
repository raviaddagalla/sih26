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

// Component to dynamically set map center
const MapUpdater = ({ center }) => {
  const map = useMap();
  useEffect(() => {
    if (center) map.setView(center, map.getZoom());
  }, [center, map]);
  return null;
};

// Main App Component
function App() {
  const [data, setData] = useState(null);
  const [currentIndex, setCurrentIndex] = useState(0);
  const [isPlaying, setIsPlaying] = useState(false);
  const [speed, setSpeed] = useState(1);
  const animationRef = useRef(null);

  useEffect(() => {
    fetch('/trajectory.json')
      .then(res => res.json())
      .then(json => {
        // Data format: { actual: [[lon, lat], ...], raw: [...], rbpf: [...] }
        // Leaflet expects [lat, lon]
        const formatPath = (path) => path.map(coord => [coord[1], coord[0]]);
        
        const actual = formatPath(json.actual);
        const rbpf = formatPath(json.rbpf);
        
        // Calculate cumulative distance for actual path
        const calcDist = (p1, p2) => Math.sqrt(Math.pow(p1[0]-p2[0], 2) + Math.pow(p1[1]-p2[1], 2)) * 111139;
        const distances = [0];
        let cum = 0;
        for(let i=1; i<actual.length; i++) {
          cum += calcDist(actual[i-1], actual[i]);
          distances.push(cum);
        }

        setData({ actual, rbpf, distances });
      });
  }, []);

  const togglePlay = () => {
    setIsPlaying(!isPlaying);
  };

  const reset = () => {
    setIsPlaying(false);
    setCurrentIndex(0);
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

  if (!data) return <div style={{display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100vh', width: '100vw'}}><h2>Loading Demo Data...</h2></div>;

  const currentActual = data.actual[currentIndex];
  const currentRbpf = data.rbpf[currentIndex];

  // Calculate some stats for the overlay
  const progress = Math.round((currentIndex / data.actual.length) * 100);
  
  // Calculate drift error between actual and rbpf roughly
  const calcDist = (p1, p2) => Math.sqrt(Math.pow(p1[0]-p2[0], 2) + Math.pow(p1[1]-p2[1], 2)) * 111139;
  const currentDriftRbpf = calcDist(currentActual, currentRbpf).toFixed(1);
  
  const currentDistance = (data.distances[currentIndex] / 1000).toFixed(2); // in km

  return (
    <>
      <header className="header">
        <h1>Intelligent Dead Reckoning</h1>
        <p>SIH 2026 Navigation Benchmark</p>
      </header>

      <main className="map-container">
        <MapContainer center={currentActual} zoom={16} scrollWheelZoom={true}>
          <TileLayer
            attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
            url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
          />
          <MapUpdater center={currentActual} />

          {/* Paths drawn so far */}
          <Polyline positions={data.actual.slice(0, currentIndex + 1)} color="#10b981" weight={4} opacity={0.6} />
          <Polyline positions={data.rbpf.slice(0, currentIndex + 1)} color="#3b82f6" weight={4} opacity={0.8} />

          {/* Current Position Trackers */}
          <Marker position={currentActual} icon={actualIcon} zIndexOffset={100} />
          <Marker position={currentRbpf} icon={rbpfIcon} zIndexOffset={90} />
        </MapContainer>

        <div className="stats-overlay">
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
      </main>
    </>
  );
}

export default App;
