import { useSimulationStore } from '../store/useSimulationStore';
import { simulationEngine } from '../simulation/engine';
import { Navigation } from 'lucide-react';

export default function RoutePreview() {
  const phase = useSimulationStore(s => s.phase);
  const totalRouteDistance = useSimulationStore(s => s.totalRouteDistance);
  const realWorldDuration = useSimulationStore(s => s.realWorldDuration);
  
  if (phase !== 'route-preview') return null;

  const distanceKm = (totalRouteDistance / 1000).toFixed(1);
  const durationMins = Math.round(realWorldDuration / 60);

  return (
    <div className="absolute bottom-0 left-0 right-0 z-[400] bg-white rounded-t-3xl shadow-[0_-4px_20px_rgba(0,0,0,0.1)] p-6 pb-8 animate-in slide-in-from-bottom-full duration-300">
      <div className="w-12 h-1.5 bg-slate-200 rounded-full mx-auto mb-6"></div>
      
      <div className="flex justify-between items-end mb-8">
        <div>
          <h2 className="text-4xl font-bold text-slate-800 tracking-tight">{durationMins} <span className="text-2xl text-slate-500 font-medium">min</span></h2>
          <p className="text-slate-500 text-lg mt-1">{distanceKm} km</p>
        </div>
        <div className="text-right">
          <div className="text-sm font-medium text-green-600 bg-green-50 px-3 py-1 rounded-full inline-block">
            Fastest route
          </div>
        </div>
      </div>

      <button 
        onClick={() => simulationEngine.start()}
        className="w-full bg-blue-600 text-white rounded-2xl py-4 text-xl font-semibold flex items-center justify-center gap-3 shadow-lg shadow-blue-500/30 active:scale-[0.98] transition-transform"
      >
        <Navigation size={24} className="fill-current" />
        Start Simulation
      </button>
    </div>
  );
}
