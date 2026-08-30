import fs from 'fs';
import { ReplayEngine } from './engine.js';
import { haversine } from './integrator.js';

const data = JSON.parse(fs.readFileSync('../../public/model/benchmark.json', 'utf8'));
const tripId = 'A5';
const tripData = data.trips[tripId];

const modelMetadataMap = {
    'cnn_baseline': {},
    'cnn_feature_c': {},
    'gru': {}
};

const engine = new ReplayEngine(tripData, {}, modelMetadataMap, {zuptAssist: false, liveCnn: false});
engine.beginGpsPhase(tripData.outageStart);
engine.beginOutagePhase();

for (let i = 0; i < tripData.outageDuration; i++) {
    engine.step();
}

const finalSnap = engine.step(); // This should return the 'done' snapshot
if (finalSnap) {
    console.log("CNN Baseline Distance:", finalSnap.models['cnn_baseline'].distanceTraveled);
    console.log("CNN Baseline Final Error:", finalSnap.models['cnn_baseline'].positionError);
    console.log("GRU Distance:", finalSnap.models['gru'].distanceTraveled);
} else {
    console.log("Engine finished");
}
