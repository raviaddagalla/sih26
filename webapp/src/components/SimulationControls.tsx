import { useSimulationStore } from '../store/useSimulationStore';
import { Wifi, WifiOff, RefreshCcw } from 'lucide-react';

export default function SimulationControls() {
  const phase = useSimulationStore(s => s.phase);
  const gpsState = useSimulationStore(s => s.gpsState);
  const setGPSState = useSimulationStore(s => s.setGPSState);

  if (phase !== 'simulating') return null;

  return (
    <div className="absolute top-12 left-4 right-4 z-[400] flex justify-between items-start pointer-events-none">
      
      {/* GPS Status Indicator */}
      <div className="pointer-events-auto bg-white rounded-2xl shadow-lg p-3 px-4 flex items-center gap-3">
        {gpsState === 'available' && (
          <>
            <div className="w-3 h-3 bg-blue-500 rounded-full animate-pulse shadow-[0_0_8px_rgba(59,130,246,0.8)]"></div>
            <div className="font-semibold text-slate-800">GPS Active</div>
          </>
        )}
        {gpsState === 'disabled' && (
          <>
            <div className="w-3 h-3 bg-slate-400 rounded-full"></div>
            <div>
              <div className="font-semibold text-slate-800 leading-tight">GPS OFF</div>
              <div className="text-xs text-slate-500 font-medium">Estimating location</div>
            </div>
          </>
        )}
        {gpsState === 'restoring' && (
          <>
            <div className="w-3 h-3 bg-yellow-500 rounded-full animate-pulse"></div>
            <div>
              <div className="font-semibold text-yellow-700 leading-tight">GPS Restoring</div>
              <div className="text-xs text-yellow-600 font-medium">Correcting location...</div>
            </div>
          </>
        )}
      </div>

      {/* GPS Actions */}
      <div className="pointer-events-auto flex flex-col gap-3">
        {gpsState === 'available' && (
          <button 
            onClick={() => setGPSState('disabled')}
            className="bg-white rounded-full p-4 shadow-lg flex flex-col items-center justify-center text-slate-700 hover:text-slate-900 active:scale-95 transition-all border border-slate-100"
          >
            <WifiOff size={24} className="text-slate-600 mb-1" />
            <span className="text-[10px] font-bold uppercase tracking-wider">Turn GPS Off</span>
          </button>
        )}
        
        {gpsState === 'disabled' && (
          <button 
            onClick={() => setGPSState('restoring')}
            className="bg-blue-600 rounded-full p-4 shadow-lg shadow-blue-500/30 flex flex-col items-center justify-center text-white active:scale-95 transition-all"
          >
            <Wifi size={24} className="mb-1" />
            <span className="text-[10px] font-bold uppercase tracking-wider">Turn GPS On</span>
          </button>
        )}
        
        {gpsState === 'restoring' && (
          <div className="bg-yellow-50 rounded-full p-4 shadow-lg flex flex-col items-center justify-center text-yellow-700 opacity-80 border border-yellow-200">
            <RefreshCcw size={24} className="mb-1 animate-spin" />
            <span className="text-[10px] font-bold uppercase tracking-wider">Correcting</span>
          </div>
        )}
      </div>

    </div>
  );
}
