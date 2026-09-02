import { useState } from 'react';
import { useSimulationStore } from '../store/useSimulationStore';
import { Search, MapPin, Navigation, Map as MapIcon, X } from 'lucide-react';
import { DEMO_ORIGIN, DEMO_DESTINATION, DEMO_ROUTE } from '../routing/demoRouteProvider';
import { analyzeRoute } from '../geo/math';

export default function SearchPanel() {
  const phase = useSimulationStore(s => s.phase);
  const setPhase = useSimulationStore(s => s.setPhase);
  const setLocations = useSimulationStore(s => s.setLocations);
  const setRoute = useSimulationStore(s => s.setRoute);
  
  const [isSearching, setIsSearching] = useState(false);

  if (phase !== 'map' && phase !== 'route-preview') return null;

  const handleDemoSelect = async () => {
    // In demo mode, we always use the fallback route to guarantee reliability
    const { totalDistance, distances } = analyzeRoute(DEMO_ROUTE);
    
    setLocations(DEMO_ORIGIN, DEMO_DESTINATION);
    setRoute(DEMO_ROUTE, distances, totalDistance);
    setPhase('route-preview');
    setIsSearching(false);
  };

  return (
    <>
      {/* Floating search bar when not searching and no route selected */}
      {phase === 'map' && !isSearching && (
        <div className="absolute top-12 left-4 right-4 z-[400]">
          <div 
            onClick={() => setIsSearching(true)}
            className="bg-white rounded-full shadow-lg h-12 flex items-center px-4 gap-3 cursor-text"
          >
            <Search size={20} className="text-slate-400" />
            <span className="text-slate-500 text-lg flex-1">Search here</span>
            <div className="w-8 h-8 bg-slate-100 rounded-full flex items-center justify-center">
              <MapIcon size={16} className="text-slate-600" />
            </div>
          </div>
        </div>
      )}

      {/* Expanded search sheet */}
      {isSearching && (
        <div className="absolute inset-0 z-[500] bg-white flex flex-col animate-in slide-in-from-bottom-4 fade-in duration-200">
          <div className="p-4 pt-12 shadow-sm relative z-10">
            <button 
              onClick={() => setIsSearching(false)}
              className="absolute top-4 right-4 p-2"
            >
              <X size={24} className="text-slate-500" />
            </button>
            <h2 className="text-2xl font-semibold mb-6 text-slate-800">Where to?</h2>
            
            <div className="flex flex-col gap-3 relative">
              <div className="absolute left-[19px] top-7 bottom-7 w-[2px] bg-slate-200"></div>
              
              <div className="flex gap-4 items-center">
                <div className="w-10 h-10 rounded-full bg-blue-50 flex items-center justify-center shrink-0 z-10">
                  <Navigation size={18} className="text-blue-500" />
                </div>
                <div className="flex-1 bg-slate-100 rounded-lg p-3 text-slate-700">
                  Your location
                </div>
              </div>
              
              <div className="flex gap-4 items-center">
                <div className="w-10 h-10 rounded-full bg-red-50 flex items-center justify-center shrink-0 z-10">
                  <MapPin size={18} className="text-red-500" />
                </div>
                <input 
                  autoFocus
                  type="text"
                  placeholder="Search destination" 
                  className="flex-1 bg-slate-100 rounded-lg p-3 text-slate-800 outline-none focus:ring-2 focus:ring-blue-500"
                />
              </div>
            </div>
          </div>

          <div className="flex-1 overflow-y-auto bg-slate-50 p-4">
            <h3 className="text-sm font-medium text-slate-500 uppercase tracking-wider mb-4">Recommended</h3>
            
            <div 
              onClick={handleDemoSelect}
              className="bg-white p-4 rounded-xl shadow-sm mb-3 flex items-start gap-4 active:scale-[0.98] transition-transform cursor-pointer"
            >
              <div className="w-10 h-10 rounded-full bg-slate-100 flex items-center justify-center shrink-0 mt-1">
                <MapPin size={20} className="text-slate-600" />
              </div>
              <div>
                <h4 className="text-lg font-medium text-slate-800">Hyde Park to Tower Bridge</h4>
                <p className="text-slate-500 text-sm mt-0.5">London, United Kingdom</p>
                <div className="text-xs text-blue-600 bg-blue-50 inline-block px-2 py-1 rounded mt-2 font-medium">
                  Simulation Demo Route
                </div>
              </div>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
