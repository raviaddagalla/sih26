import React, { useRef, useEffect } from 'react';
import { MapContainer, TileLayer, Polyline, Marker, Popup } from 'react-leaflet';
import L from 'leaflet';
import { haversine } from '../experiment/integrator';
import 'leaflet/dist/leaflet.css';

// Fix Leaflet icon issue
delete L.Icon.Default.prototype._getIconUrl;
L.Icon.Default.mergeOptions({
  iconRetinaUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.7.1/images/marker-icon-2x.png',
  iconUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.7.1/images/marker-icon.png',
  shadowUrl: 'https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.7.1/images/marker-shadow.png',
});

/**
 * Resize observer for Leaflet map — Leaflet caches container size at initialization.
 * Without this, the map can render tiles in the wrong area when the container size changes
 * (sidebar collapse, window resize, or simply not having its final size yet on first paint
 * inside flex layouts).
 */
const resizeObserver = new ResizeObserver(() => {
  if (mapRef.current) {
    mapRef.current.invalidateSize();
  }
});

/**
 * Map visualization showing reference trajectory, GPS phase, and model estimates
 */
export default function MapView({
  experimentPhase,
  gpsFinishedIndex,
  outageStartIndex,
  tripRefLat,
  tripRefLon,
  modelSnapshots,
  showReference = true,
  showGpsTrace = true,
  showModels = true,
  showOutageStart = true,
  showCurrentPosition = true,
  activeTab = 'compare'
}) {
  const mapRef = useRef(null);
  
  // Calculate bounds to fit all visible trajectories
  React.useEffect(() => {
    if (mapRef.current) {
      const allPositions = [];
      
      // Add reference trajectory
      if (showReference && tripRefLat && tripRefLon) {
        for (let i = 0; i < tripRefLat.length; i++) {
          allPositions.push([tripRefLat[i], tripRefLon[i]]);
        }
      }
      
      // Add model trajectories - filter by activeTab
      if (showModels && modelSnapshots) {
        for (const [modelId, snapshot] of Object.entries(modelSnapshots)) {
          if (activeTab !== 'compare' && modelId !== activeTab) continue;
          
          if (snapshot.trajectory && snapshot.trajectory.length > 0) {
            for (const [lat, lon] of snapshot.trajectory) {
              allPositions.push([lat, lon]);
            }
          }
        }
      }
      
      if (allPositions.length > 0) {
        const lats = allPositions.map(p => p[0]);
        const lons = allPositions.map(p => p[1]);
        const latLngBounds = [
          [Math.min(...lats), Math.min(...lons)],
          [Math.max(...lats), Math.max(...lons)]
        ];
        mapRef.current.fitBounds(latLngBounds, { padding: [50, 50] });
      }
    }
  }, [tripRefLat, tripRefLon, modelSnapshots, showReference, showGpsTrace, showModels, activeTab]);
  
  // Resize observer for Leaflet map - ensures map tiles render correctly
  // when the container size changes (sidebar collapse, window resize, etc.)
  useEffect(() => {
    if (mapRef.current) {
      resizeObserver.observe(mapRef.current);
      return () => resizeObserver.unobserve(mapRef.current);
    }
  }, []);

  return (
    <MapContainer 
      ref={mapRef}
      center={[0, 0]} 
      zoom={13} 
      scrollWheelZoom={true}
      className={experimentPhase === 'outage' ? 'map-dimmed' : ''}
      style={{ height: '100%', width: '100%' }}
    >
      {/* Base tile layer */}
      <TileLayer
        attribution='&copy; <a href="https://openstreetmap.org">OpenStreetMap</a> contributors'
        url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
      />
      
      {/* Reference/GPS trajectory */}
      {showReference && tripRefLat && tripRefLon && tripRefLat.length > 0 && (
        <>
          {/* Google Maps style blue line for the entire trip */}
          <Polyline 
            positions={tripRefLat.map((lat, i) => [lat, tripRefLon[i]])}
            pathOptions={{ color: "#4285F4", weight: 6, opacity: 0.8 }}
          />
          
          {/* Start and End Pins */}
          <Marker position={[tripRefLat[0], tripRefLon[0]]}>
            <Popup>Trip Start</Popup>
          </Marker>
          <Marker position={[tripRefLat[tripRefLat.length - 1], tripRefLon[tripRefLon.length - 1]]}>
            <Popup>Trip End</Popup>
          </Marker>
          
          {/* Show the outage start position if configured */}
          {showOutageStart && outageStartIndex >= 0 && (
            <Marker position={[tripRefLat[outageStartIndex], tripRefLon[outageStartIndex]]}>
              <Popup><strong>GPS Signal Lost</strong><br/>Entering Dead-Reckoning Phase</Popup>
            </Marker>
          )}
        </>
      )}
      
      {/* Model trajectories */}
      {showModels && modelSnapshots && (
        <>
          {Object.entries(modelSnapshots)
            .filter(([modelId]) => activeTab === 'compare' || modelId === activeTab)
            .map(([modelId, snapshot]) => {
            if (!snapshot.trajectory || snapshot.trajectory.length === 0) return null;
            
            return (
              <Polyline 
                key={modelId}
                positions={snapshot.trajectory}
                pathOptions={{
                  color: snapshot.color,
                  weight: 4,
                  opacity: 0.9,
                  dashArray: activeTab === modelId ? null : "5, 5"
                }}
              >
                <Popup>
                  <strong>{snapshot.name} (IDR Estimate)</strong><br/>
                  Position Error: {snapshot.positionError.toFixed(1)} m<br/>
                  Velocity: {(snapshot.velocity * 3.6).toFixed(1)} km/h
                </Popup>
              </Polyline>
            );
          })}
        </>
      )}
      
      {/* Outage start marker */}
      {showOutageStart && tripRefLat && tripRefLon && outageStartIndex >= 0 && (
        <Marker 
          position={[tripRefLat[outageStartIndex], tripRefLon[outageStartIndex]]}
        >
          <Popup>Outage Start</Popup>
        </Marker>
      )}
      
      {/* Naive GPS marker (frozen at outage start) */}
      {experimentPhase === 'outage' && tripRefLat && tripRefLon && outageStartIndex >= 0 && (
        <Marker 
          position={[tripRefLat[outageStartIndex], tripRefLon[outageStartIndex]]}
        >
          <Popup>Naive GPS (Frozen due to blackout)</Popup>
        </Marker>
      )}

      {/* Current position markers (Filtered by activeTab) */}
      {showCurrentPosition && experimentPhase === 'outage' && modelSnapshots && (
        <>
          {Object.entries(modelSnapshots)
            .filter(([modelId]) => activeTab === 'compare' || modelId === activeTab)
            .map(([modelId, snapshot]) => {
            const lastPos = snapshot.trajectory[snapshot.trajectory.length - 1];
            if (!lastPos) return null;
            
            return (
              <Marker 
                key={modelId}
                position={lastPos}
              >
                <Popup>
                  <strong>{snapshot.name}</strong><br/>
                  Error: {snapshot.positionError.toFixed(1)} m
                </Popup>
              </Marker>
            );
          })}
        </>
      )}
    </MapContainer>
  );
}