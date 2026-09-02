import { useEffect, useState } from 'react';
import { useSimulationStore } from '../store/useSimulationStore';

export default function CalibrationScreen() {
  const phase = useSimulationStore(s => s.phase);
  const setPhase = useSimulationStore(s => s.setPhase);
  const [progress, setProgress] = useState(0);

  useEffect(() => {
    if (phase !== 'calibration') return;

    const DURATION = 3000;
    const startTime = performance.now();
    let frame: number;

    const animate = (time: number) => {
      const elapsed = time - startTime;
      const p = Math.min(elapsed / DURATION, 1);
      setProgress(p);

      if (p < 1) {
        frame = requestAnimationFrame(animate);
      } else {
        setPhase('map');
      }
    };

    frame = requestAnimationFrame(animate);
    return () => cancelAnimationFrame(frame);
  }, [phase, setPhase]);

  if (phase !== 'calibration') return null;

  return (
    <div className="absolute inset-0 z-50 bg-slate-900 flex flex-col items-center justify-center text-white p-6">
      <div className="text-2xl font-semibold mb-2">Calibrate your device</div>
      <div className="text-slate-400 mb-12 text-center">Rotate your phone in a figure-eight to improve location accuracy</div>
      
      <div className="relative w-48 h-48 mb-12">
        {/* Figure 8 path visualization */}
        <svg viewBox="0 0 100 100" className="w-full h-full opacity-30">
          <path d="M 50 50 C 20 20, 20 80, 50 50 C 80 20, 80 80, 50 50" fill="transparent" stroke="white" strokeWidth="4" strokeLinecap="round" strokeDasharray="5, 10" />
        </svg>
        
        {/* Animated phone icon following the path */}
        <div 
          className="absolute top-1/2 left-1/2 -mt-4 -ml-3 w-6 h-8 border-2 border-white rounded-sm"
          style={{
            transform: `
              translate(${Math.sin(progress * Math.PI * 4) * 40}px, ${Math.sin(progress * Math.PI * 2) * 40}px)
              rotate(${progress * 360 * 2}deg)
            `
          }}
        >
          <div className="w-full h-1 bg-white mt-1 opacity-50"></div>
        </div>
      </div>
      
      <div className="w-64 h-2 bg-slate-800 rounded-full overflow-hidden">
        <div 
          className="h-full bg-blue-500 rounded-full transition-all duration-100 ease-linear"
          style={{ width: `${progress * 100}%` }}
        />
      </div>
      
      <button 
        onClick={() => setPhase('map')}
        className="mt-12 px-6 py-2 rounded-full border border-slate-700 text-slate-400 text-sm active:bg-slate-800"
      >
        Skip
      </button>
    </div>
  );
}
