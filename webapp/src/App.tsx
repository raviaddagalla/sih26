import CalibrationScreen from './components/CalibrationScreen';
import NavigationMap from './components/NavigationMap';
import SearchPanel from './components/SearchPanel';
import RoutePreview from './components/RoutePreview';
import SimulationControls from './components/SimulationControls';
import ActivityPanel from './components/ActivityPanel';
import DemoControls from './components/DemoControls';

function App() {
  return (
    <div className="w-screen h-screen overflow-hidden relative bg-slate-100 font-sans selection:bg-blue-200 text-slate-900">
      <CalibrationScreen />
      
      {/* Map layer (always mounted under the UI panels) */}
      <NavigationMap />

      {/* UI Layers */}
      <SearchPanel />
      <RoutePreview />
      
      <SimulationControls />
      <ActivityPanel />
      
      <DemoControls />
    </div>
  );
}

export default App;
