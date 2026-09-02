import { useSimulationStore } from '../store/useSimulationStore';
import { simulationEngine } from '../simulation/engine';
import { CheckCircle2, RotateCcw } from 'lucide-react';

export default function ActivityPanel() {
  const phase = useSimulationStore(s => s.phase);
  const simulatedElapsedTime = useSimulationStore(s => s.simulatedElapsedTime);
  const realWorldDuration = useSimulationStore(s => s.realWorldDuration);
  const totalRouteDistance = useSimulationStore(s => s.totalRouteDistance);
  const progress = useSimulationStore(s => s.progress);

  if (phase !== 'simulating' && phase !== 'completed') return null;

  const distanceLeft = (totalRouteDistance * (1 - progress) / 1000).toFixed(1);
  const totalKm = (totalRouteDistance / 1000).toFixed(1);
  
  const timeRemainingSecs = Math.max(realWorldDuration - simulatedElapsedTime, 0);
  const minsRemaining = Math.floor(timeRemainingSecs / 60);

  // Format elapsed time MM:SS based on SIMULATED time, not playback time, so it feels real
  const elapsedMins = Math.floor(simulatedElapsedTime / 60);
  const elapsedSecs = Math.floor(simulatedElapsedTime % 60);
  const elapsedStr = `${elapsedMins.toString().padStart(2, '0')}:${elapsedSecs.toString().padStart(2, '0')}`;

  if (phase === 'completed') {
    return (
      <div className="absolute bottom-0 left-0 right-0 z-[400] bg-white rounded-t-3xl shadow-[0_-4px_20px_rgba(0,0,0,0.1)] p-6 pb-8 animate-in slide-in-from-bottom-full duration-300 flex flex-col items-center text-center">
        <CheckCircle2 size={64} className="text-green-500 mb-4" />
        <h2 className="text-3xl font-bold text-slate-800 mb-1">Trip complete</h2>
        <p className="text-slate-500 text-lg mb-8">{totalKm} km in {Math.floor(realWorldDuration/60)} minutes</p>
        
        <button 
          onClick={() => simulationEngine.reset()}
          className="bg-slate-100 text-slate-700 px-8 py-3 rounded-xl font-semibold flex items-center gap-2 active:bg-slate-200"
        >
          <RotateCcw size={20} />
          Restart Demo
        </button>
      </div>
    );
  }

  return (
    <div className="absolute bottom-0 left-0 right-0 z-[400] bg-white rounded-t-3xl shadow-[0_-4px_20px_rgba(0,0,0,0.1)] p-6 pb-8">
      <div className="w-12 h-1.5 bg-slate-200 rounded-full mx-auto mb-6"></div>
      
      <div className="flex justify-between items-center">
        <div>
          <h2 className="text-4xl font-bold text-slate-800 tracking-tight flex items-baseline gap-1">
            {minsRemaining} <span className="text-2xl text-slate-500 font-medium">min</span>
          </h2>
          <p className="text-slate-500 text-lg mt-1">{distanceLeft} km</p>
        </div>
        
        <div className="text-right border-l border-slate-100 pl-6">
          <div className="text-sm font-medium text-slate-400 uppercase tracking-wider mb-1">Elapsed</div>
          <div className="text-2xl font-semibold text-slate-700 font-mono">{elapsedStr}</div>
        </div>
      </div>
    </div>
  );
}
