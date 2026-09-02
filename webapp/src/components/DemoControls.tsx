import { useState } from 'react';
import { useSimulationStore } from '../store/useSimulationStore';
import { simulationEngine } from '../simulation/engine';
import { Settings, X } from 'lucide-react';

export default function DemoControls() {
  const [isOpen, setIsOpen] = useState(false);
  const phase = useSimulationStore(s => s.phase);
  
  if (phase === 'calibration') return null;

  if (!isOpen) {
    return (
      <button 
        onClick={() => setIsOpen(true)}
        className="absolute top-4 right-4 z-[1000] w-8 h-8 bg-white/80 backdrop-blur rounded-full flex items-center justify-center shadow-sm text-slate-400 hover:text-slate-600 border border-slate-200"
      >
        <Settings size={14} />
      </button>
    );
  }

  const handleReset = () => {
    simulationEngine.reset();
  };

  return (
    <div className="absolute top-4 right-4 z-[1000] bg-white rounded-xl shadow-xl border border-slate-200 w-64 p-4 text-sm animate-in fade-in zoom-in-95 duration-200">
      <div className="flex justify-between items-center mb-4">
        <h3 className="font-semibold text-slate-800">Demo Controls</h3>
        <button onClick={() => setIsOpen(false)} className="text-slate-400 hover:text-slate-600">
          <X size={16} />
        </button>
      </div>

      <div className="space-y-4">
        <button 
          onClick={handleReset}
          className="w-full py-2 bg-red-50 text-red-600 rounded-lg font-medium hover:bg-red-100 transition-colors"
        >
          Reset Simulation
        </button>
        
        <div className="pt-2 border-t border-slate-100">
          <div className="text-xs font-medium text-slate-500 mb-2 uppercase tracking-wider">Internal State</div>
          <DebugState />
        </div>
      </div>
    </div>
  );
}

function DebugState() {
  const progress = useSimulationStore(s => s.progress);
  const playbackElapsedTime = useSimulationStore(s => s.playbackElapsedTime);
  const speed = useSimulationStore(s => s.speed);
  const gpsState = useSimulationStore(s => s.gpsState);
  
  return (
    <div className="space-y-1 font-mono text-[10px] text-slate-600">
      <div className="flex justify-between"><span>Progress:</span> <span>{(progress * 100).toFixed(1)}%</span></div>
      <div className="flex justify-between"><span>Playback:</span> <span>{playbackElapsedTime.toFixed(1)}s</span></div>
      <div className="flex justify-between"><span>Speed:</span> <span>{(speed * 3.6).toFixed(1)} km/h</span></div>
      <div className="flex justify-between"><span>GPS:</span> <span>{gpsState}</span></div>
    </div>
  );
}
