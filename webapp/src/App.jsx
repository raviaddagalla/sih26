import React, { useState, useEffect, useRef } from 'react';
import { loadModelAndNorm, preprocessWindow } from './modelUtils';
import { loadBenchmarkData } from './experiment/registry';
import { ReplayEngine } from './experiment/engine';
import Header from './components/Header';
import ExperimentControls from './components/ExperimentControls';
import MapView from './components/MapView';
import ModelTabs from './components/ModelTabs';
import ChartsPanel from './components/ChartsPanel';
import MetricsPanel from './components/MetricsPanel';
import './index.css'; // Import CSS styles // NOTE: App.css intentionally NOT imported. It contained a second, conflicting
// design system (old purple gradient header, pastel flat-UI colors) that was fighting the dark
// instrument-panel tokens in index.css/design/tokens.css for the exact same class names
// (.app-container, .main-content, .sidebar, .map-container, etc.). Two stylesheets targeting the
// same selectors is why nothing looked consistent.

function App() {
  // Data loading state
  const [benchmarkData, setBenchmarkData] = useState(null);
  const [modelData, setModelData] = useState(null); // Live model (cnn_feature_c)
  const [normParams, setNormParams] = useState(null);
  const [loadError, setLoadError] = useState(null);
  const [liveModelVerified, setLiveModelVerified] = useState(false);
  const [liveModelError, setLiveModelError] = useState(null);

  // Experiment state
  const [experimentPhase, setExperimentPhase] = useState('idle'); // 'idle' | 'gps' | 'outage' | 'done'
  const [isRunning, setIsRunning] = useState(false);
  const [selectedTrip, setSelectedTrip] = useState('A5');
  const [speed, setSpeed] = useState(5.0); // playback speed multiplier
  const [zuptAssist, setZuptAssist] = useState(false);
  const [liveCnn, setLiveCnn] = useState(false);
  const [activeTab, setActiveTab] = useState('cnn_feature_c'); // Focus on IDR demo by default
  const [showIntro, setShowIntro] = useState(true);
  const [showSummary, setShowSummary] = useState(false);
  const [bannerText, setBannerText] = useState('');

  // Refs for animation and engine
  const engineRef = useRef(null);
  const animationFrameRef = useRef(null);
  const lastTimestampRef = useRef(0);
  const accumulatedTimeRef = useRef(0);
  const isRunningRef = useRef(false);
  const speedRef = useRef(5.0);
  const baseTimePerStepMs = 200; // base 200ms per step (5 Hz)

  // Load data on startup
  useEffect(() => {
    async function loadAllData() {
      try {
        setLoadError(null);
        
        // Load benchmark data (contains all model data for replay)
        const data = await loadBenchmarkData();
        setBenchmarkData(data);
        
        // Load normalization parameters
        const norm = await fetch('/model/norm_params.json').then(r => r.json());
        setNormParams(norm);
        
        // Load live CNN model (cnn_feature_c) for TF.js inference
        const { model, normParams: liveNorm } = await loadModelAndNorm();
        setModelData({ model, normParams: liveNorm });
        
        // Verify live model works by testing first prediction
        if (benchmarkData && benchmarkData.trips.A5 && 
            benchmarkData.trips.A5.outageWindows && 
            benchmarkData.trips.A5.outageWindows.length > 0) {
          // Get first window of outage for A5
          const firstWindow = benchmarkData.trips.A5.outageWindows[0];
          const inputTensor = preprocessWindow(firstWindow, normParams);
          const prediction = model.predict(inputTensor);
          const predictedVel = prediction.dataSync()[0];
          inputTensor.dispose();
          prediction.dispose();
          
          // Check against replayed velocity for first step
          const replayedVel = benchmarkData.trips.A5.models.cnn_feature_c.outage.vel[0];
          const error = Math.abs(predictedVel - replayedVel);
          setLiveModelVerified(error < 1.0); // Allow 1 m/s tolerance
          if (error >= 1.0) {
            setLiveModelError(`Live model verification failed: error ${error.toFixed(2)} m/s`);
          }
        }
        
      } catch (err) {
        console.error('Failed to load data:', err);
        setLoadError(err.message);
      }
    }
    
    loadAllData();
  }, []);

  // Start/pause/reset handlers
  const startExperiment = () => {
    if (!benchmarkData || !modelData) return;
    
    setIsRunning(true);
    isRunningRef.current = true;
    setShowIntro(false);
    setShowSummary(false);
    setBannerText('Experiment starting...');
    setTimeout(() => setBannerText(''), 2000);
    
    // Initialize engine
    engineRef.current = new ReplayEngine(
      benchmarkData.trips[selectedTrip],
      { 'cnn_feature_c': { model: modelData.model, normParams: modelData.normParams } },
      benchmarkData.metricsSummary,
      { zuptAssist: zuptAssist, liveCnn: liveCnn }
    );
    
    engineRef.current.start();
    engineRef.current.beginGpsPhase(
      Math.max(0, benchmarkData.trips[selectedTrip].outageStartIndex - 180)
    );
    
    // Start animation loop
    lastTimestampRef.current = performance.now();
    accumulatedTimeRef.current = 0;
    animationFrameRef.current = requestAnimationFrame(animationLoop);
  };

  const pauseExperiment = () => {
    setIsRunning(false);
    isRunningRef.current = false;
    if (animationFrameRef.current) {
      cancelAnimationFrame(animationFrameRef.current);
    }
    setBannerText('Experiment paused');
    setTimeout(() => setBannerText(''), 1500);
  };

  const resetExperiment = () => {
    setIsRunning(false);
    isRunningRef.current = false;
    setExperimentPhase('idle');
    if (animationFrameRef.current) {
      cancelAnimationFrame(animationFrameRef.current);
    }
    if (engineRef.current) {
      engineRef.current.reset();
    }
    lastTimestampRef.current = 0;
    accumulatedTimeRef.current = 0;
    setShowSummary(false);
    setBannerText('Experiment reset');
    setTimeout(() => setBannerText(''), 1500);
  };

  const toggleGps = () => {
    if (experimentPhase === 'gps') {
      // User clicked to start outage early
      setBannerText('GPS signal lost - starting dead reckoning');
      setTimeout(() => setBannerText(''), 2000);
      if (engineRef.current) {
        engineRef.current.beginOutagePhase();
      }
    }
  };

  // Animation loop - driven by requestAnimationFrame for smooth playback
  const animationLoop = (timestamp) => {
    if (!isRunningRef.current) return;
    
    const deltaTime = timestamp - lastTimestampRef.current;
    lastTimestampRef.current = timestamp;
    accumulatedTimeRef.current += deltaTime;
    
    // Convert to experiment time (seconds) based on speed
    const currentSpeed = speedRef.current;
    const experimentTimeSec = accumulatedTimeRef.current / 1000.0 * currentSpeed;
    const stepsToAdvance = Math.floor(experimentTimeSec / 1.0); // 1 second per step
    
    if (stepsToAdvance > 0) {
      // Advance experiment by the needed number of steps
      for (let i = 0; i < stepsToAdvance; i++) {
        const snapshot = engineRef.current.step();
        if (snapshot === null) {
          // Experiment finished
          handleExperimentDone();
          break;
        }
        // Update state with snapshot (we'll use useState updates below)
        // For performance, we'll update less frequently or use useRef for internal state
        // For now, let's update state on each step - React will batch updates
        setExperimentSnapshot(snapshot);
        // Update progress
        if (engineRef.current) {
          setExperimentProgress(engineRef.current.getProgress());
        }
      }
      
      // Adjust accumulated time to avoid drift
      accumulatedTimeRef.current -= (stepsToAdvance * 1000.0) / currentSpeed;
    }
    
    animationFrameRef.current = requestAnimationFrame(animationLoop);
  };

// State for experiment snapshot (to avoid too many re-renders)
  const [experimentSnapshot, setExperimentSnapshot] = useState(null);
  const [experimentProgress, setExperimentProgress] = useState(0);
  
  // Handle experiment completion
  const handleExperimentDone = () => {
    setIsRunning(false);
    isRunningRef.current = false;
    setExperimentPhase('done');
    if (animationFrameRef.current) {
      cancelAnimationFrame(animationFrameRef.current);
    }
    setShowSummary(true);
    setBannerText('Experiment complete - see results');
    setTimeout(() => setBannerText(''), 2000);
  };

  // Effect to update experiment phase based on engine state
  useEffect(() => {
    if (engineRef.current) {
      setExperimentPhase(engineRef.current.phase);
    }
  }, [engineRef.current]);

  // Effect to handle trip changes
  useEffect(() => {
    if (isRunning) {
      // Restart experiment with new trip
      resetExperiment();
      // Could auto-start here if desired
    }
  }, [selectedTrip]);

  // Effect to handle live CNN toggle
  useEffect(() => {
    if (liveCnn && !modelData) {
      // Try to load live model if not already loaded
      loadModelAndNorm().then(({ model, normParams }) => {
        setModelData({ model, normParams });
        // Verification will happen in the main loadData effect
      });
    }
  }, [liveCnn]);

  // Render logic
  if (loadError) {
    return (
      <div className="error-container">
        <h1>Loading Error</h1>
        <p>{loadError}</p>
        <button onClick={() => window.location.reload()}>Retry</button>
      </div>
    );
  }

if (!benchmarkData || !modelData || !normParams) {
    return (
      <div className="loading-container">
        <div className="loading-spinner"></div>
        <h1>Loading Experiment Data...</h1>
        <p>Loading benchmark data, model weights, and normalization parameters...</p>
          {liveModelVerified !== false && (
            <div className="live-model-status">
              {liveModelVerified ? (
                <span className="status live">Live Model: Verified ✓</span>
              ) : liveModelError ? (
                <span className="status error">Live Model Error: {liveModelError}</span>
              ) : (
                <span className="status loading">Live Model: Verifying...</span>
              )}
            </div>
          )}
      </div>
    );
  }

  if (showIntro) {
    return (
      <div className="intro-container">
        <div className="intro-content">
          <h1 style={{color: 'var(--accent-signal)'}}>The GPS Blackout Problem</h1>
          <p style={{fontSize: '16px'}}>
            When vehicles enter tunnels, dense urban canyons, or underground parking, GPS signals fail. 
            Navigation apps freeze or jump erratically.
          </p>
          <p style={{fontSize: '16px'}}>
            <b>IDR (Intelligent Dead Reckoning)</b> solves this using the smartphone's built-in IMU sensors and an AI model 
            to continue tracking the vehicle accurately during these blackouts, snapping to the real road network.
          </p>
          
          <h2 style={{marginTop: '30px'}}>Demo Instructions for Judges:</h2>
          <ol style={{fontSize: '15px'}}>
            <li>Click "Start Demo" below.</li>
            <li>Watch the vehicle follow the true GPS trajectory (green line).</li>
            <li>Click "TURN OFF GPS" to simulate entering a tunnel.</li>
            <li>Observe the <b>Frozen Marker</b> (what standard GPS does) vs the <b>IDR Path</b> (cyan line) seamlessly continuing.</li>
            <li>Review the final drift error when GPS is restored.</li>
          </ol>
          
          <button className="start-btn" style={{marginTop: '40px', width: '100%', fontSize: '18px'}} onClick={() => setShowIntro(false)}>
            Start IDR Demo
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="app-container">
      <Header 
        gpsActive={experimentPhase === 'gps' || experimentPhase === 'idle'}
        experimentPhase={experimentPhase}
        modelLoadStatus={modelData ? 'ready' : 'loading'}
        liveModelVerified={liveModelVerified}
        liveModelError={liveModelError}
      />
      
      <div className="main-content">
        <aside className="sidebar">
          <ExperimentControls
            experimentPhase={experimentPhase}
            isRunning={isRunning}
            onStart={startExperiment}
            onPause={pauseExperiment}
            onReset={resetExperiment}
            onToggleGps={toggleGps}
            onSpeedChange={(val) => { setSpeed(val); speedRef.current = val; }}
            onZuputAssistToggle={setZuptAssist}
            onLiveCnnToggle={setLiveCnn}
            speed={speed}
            zuptAssist={zuptAssist}
            liveCnn={liveCnn}
            availableTrips={['A5', 'T2']}
            selectedTrip={selectedTrip}
            onTripChange={setSelectedTrip}
            progress={experimentProgress}
          />
        </aside>
        
        <main className="main-panel">
          {!showSummary && (
            <>
              <div className="map-container">
                <MapView
                  experimentPhase={experimentPhase}
                  gpsFinishedIndex={experimentPhase === 'gps' 
                    ? Math.min(benchmarkData.trips[selectedTrip].outageStart - 1, 
                       benchmarkData.trips[selectedTrip].ref.lat.length - 1) 
                    : -1}
                  outageStartIndex={benchmarkData.trips[selectedTrip].outageStart}
                  tripRefLat={benchmarkData.trips[selectedTrip].ref.lat}
                  tripRefLon={benchmarkData.trips[selectedTrip].ref.lon}
                  modelSnapshots={experimentSnapshot?.models || {}}
                  activeTab={activeTab}
                  showReference={true}
                  showGpsTrace={experimentPhase === 'gps' || experimentPhase === 'idle'}
                  showModels={experimentPhase === 'outage' || experimentPhase === 'done'}
                  showOutageStart={experimentPhase === 'outage' || experimentPhase === 'done'}
                  showCurrentPosition={experimentPhase === 'outage'}
                />
              </div>
              
              <ModelTabs
                activeTab={activeTab}
                onTabChange={setActiveTab}
                modelSnapshots={experimentSnapshot?.models || {}}
                tripRefLat={benchmarkData.trips[selectedTrip].ref.lat}
                tripRefLon={benchmarkData.trips[selectedTrip].ref.lon}
                experimentPhase={experimentPhase}
                outageStartIndex={benchmarkData.trips[selectedTrip].outageStart}
                outageDuration={benchmarkData.trips[selectedTrip].outageDuration}
                benchmarkData={benchmarkData}
                selectedTrip={selectedTrip}
              />
            </>
          )}
          
          {showSummary && (
            <MetricsPanel
              modelSnapshots={experimentSnapshot?.models || {}}
              benchmarkData={benchmarkData}
              selectedTrip={selectedTrip}
              experimentPhase={experimentPhase}
            />
          )}
          
          {!showSummary && (
            <ChartsPanel
              modelSnapshots={experimentSnapshot?.models || {}}
              benchmarkData={benchmarkData}
              selectedTrip={selectedTrip}
              experimentPhase={experimentPhase}
              outageStartIndex={benchmarkData.trips[selectedTrip].outageStart}
              outageDuration={benchmarkData.trips[selectedTrip].outageDuration}
            />
          )}
        </main>
      </div>
      
      {bannerText && (
        <div className={`banner ${bannerText.includes('lost') ? 'error' : bannerText.includes('starting') ? 'warning' : ''}`}>
          {bannerText}
        </div>
      )}
    </div>
  );
}

export default App;
