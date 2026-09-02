import { useEffect, useRef } from 'react';
import { MapContainer, TileLayer, Polyline, Marker, Tooltip, useMap } from 'react-leaflet';
import 'leaflet/dist/leaflet.css';
import L from 'leaflet';
import { useSimulationStore } from '../store/useSimulationStore';

// Custom icons
const createPulsingIcon = (color: string) => L.divIcon({
  className: 'custom-div-icon',
  html: `<div style="background-color: ${color}; width: 24px; height: 24px; border-radius: 50%; border: 3px solid white; box-shadow: 0 0 10px rgba(0,0,0,0.5);"></div>`,
  iconSize: [24, 24],
  iconAnchor: [12, 12]
});

const defaultIcon = createPulsingIcon('#3b82f6'); // Solid Blue
const estimatedIcon = createPulsingIcon('#9ca3af'); // Gray for estimated

// Marker Layer to handle 60fps updates without React re-renders
function AnimatedMarkerLayer() {
  const map = useMap();
  const markerRef = useRef<L.Marker | null>(null);
  
  const isFollowingRef = useRef(true);
  
  // Track map drag to disable follow mode
  useEffect(() => {
    const handleDragStart = () => { isFollowingRef.current = false; };
    map.on('dragstart', handleDragStart);
    return () => { map.off('dragstart', handleDragStart); };
  }, [map]);

  useEffect(() => {
    // Initial marker setup
    const state = useSimulationStore.getState();
    const pos = state.displayedPosition || state.origin;
    if (pos) {
      markerRef.current = L.marker([pos.lat, pos.lng], { icon: defaultIcon }).addTo(map);
    }

    // Subscribe to rapid position updates
    const unsubscribe = useSimulationStore.subscribe((state, prevState) => {
      const pos = state.displayedPosition;
      if (!pos) return;

      if (!markerRef.current) {
        markerRef.current = L.marker([pos.lat, pos.lng], { icon: defaultIcon }).addTo(map);
      } else {
        markerRef.current.setLatLng([pos.lat, pos.lng]);
        
        // Update icon if GPS state changes
        if (state.gpsState !== prevState.gpsState) {
            markerRef.current.setIcon(state.gpsState === 'disabled' ? estimatedIcon : defaultIcon);
        }
      }

      // Camera follow logic
      if (isFollowingRef.current && state.phase === 'simulating') {
        map.setView([pos.lat, pos.lng], map.getZoom(), { animate: false });
      }
    });

    return () => {
      unsubscribe();
      if (markerRef.current) {
        markerRef.current.remove();
      }
    };
  }, [map]);

  return null;
}

// Track Layer to handle paths
function TrackLayer() {
  const routeCoordinates = useSimulationStore(s => s.routeCoordinates);
  const gpsTrackHistory = useSimulationStore(s => s.gpsTrackHistory);
  const estimatedTrackHistory = useSimulationStore(s => s.estimatedTrackHistory);
  const phase = useSimulationStore(s => s.phase);
  const origin = useSimulationStore(s => s.origin);
  const destination = useSimulationStore(s => s.destination);

  const routePositions: [number, number][] = routeCoordinates.map(c => [c.lat, c.lng]);
  const gpsSegments: [number, number][][] = gpsTrackHistory.map(segment => segment.map(c => [c.lat, c.lng]));
  const estSegments: [number, number][][] = estimatedTrackHistory.map(segment => segment.map(c => [c.lat, c.lng]));

  return (
    <>
      {/* Full Route Preview (Solid blue) */}
      {phase === 'route-preview' && (
        <Polyline positions={routePositions} pathOptions={{ color: '#3b82f6', weight: 6 }} />
      )}
      
      {/* Remaining Route during simulation (Light gray) */}
      {phase === 'simulating' && (
        <Polyline positions={routePositions} pathOptions={{ color: '#9ca3af', weight: 4 }} />
      )}
      
      {/* Start and End Markers during preview */}
      {phase === 'route-preview' && origin && destination && (
        <>
          <Marker position={[origin.lat, origin.lng]}>
            <Tooltip permanent direction="top" className="font-bold">Start: Hyde Park</Tooltip>
          </Marker>
          <Marker position={[destination.lat, destination.lng]}>
            <Tooltip permanent direction="top" className="font-bold">End: Tower Bridge</Tooltip>
          </Marker>
        </>
      )}

      {/* GPS Track Segments (Solid blue) - Uses MultiPolyline internally */}
      {gpsSegments.length > 0 && (
        <Polyline positions={gpsSegments} pathOptions={{ color: '#3b82f6', weight: 6 }} />
      )}

      {/* Estimated Track Segments (Dashed blue/gray) - Uses MultiPolyline internally */}
      {estSegments.length > 0 && (
        <Polyline 
          positions={estSegments} 
          pathOptions={{ color: '#3b82f6', weight: 6, dashArray: '10, 10' }} 
        />
      )}
    </>
  );
}

function MapController() {
  const map = useMap();
  const routeCoordinates = useSimulationStore(s => s.routeCoordinates);
  const phase = useSimulationStore(s => s.phase);

  // Fit bounds on route load
  useEffect(() => {
    if (phase === 'route-preview' && routeCoordinates.length > 0) {
      const bounds = L.latLngBounds(routeCoordinates.map(c => [c.lat, c.lng]));
      map.fitBounds(bounds, { padding: [50, 50] });
    }
  }, [phase, routeCoordinates, map]);
  
  return null;
}

export default function NavigationMap() {
  const origin = useSimulationStore(s => s.origin);
  const center = origin ? [origin.lat, origin.lng] : [51.5029, -0.1504]; // default London

  return (
    <div className="absolute inset-0 z-0">
      <MapContainer 
        center={center as L.LatLngExpression} 
        zoom={14} 
        zoomControl={false}
        className="w-full h-full"
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        <MapController />
        <TrackLayer />
        <AnimatedMarkerLayer />
      </MapContainer>
    </div>
  );
}
