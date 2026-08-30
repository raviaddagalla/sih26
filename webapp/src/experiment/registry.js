/**
 * Experiment registry - loads benchmark data and provides model access.
 * Central source of truth for experiment configuration and data.
 */
import { loadModelAndNorm } from '../modelUtils';

let cachedData = null;
let cachedNorm = null;
let cachedModel = null;

// Default model set for the 5-model shootout
export const MODEL_IDS = [
  "cnn_baseline",
  "cnn_feature_c", 
  "gru",
  "tcn",
  "xgboost"
];

// Low-speed experiment model (shown in comparison but not main tabs)
export const LOW_SPEED_MODEL_ID = "cnn_feature_c_lowspeed";

/**
 * Load benchmark data from JSON file
 * @returns {Promise<Object>} benchmark data
 */
export async function loadBenchmarkData() {
  if (cachedData) return cachedData;
  
  const response = await fetch('/model/benchmark.json');
  if (!response.ok) {
    throw new Error(`Failed to load benchmark data: ${response.status}`);
  }
  cachedData = await response.json();
  return cachedData;
}

/**
 * Load normalization parameters
 * @returns {Promise<Object>} normalization parameters
 */
export async function loadNormalization() {
  if (cachedNorm) return cachedNorm;
  
  const response = await fetch('/model/norm_params.json');
  if (!response.ok) {
    throw new Error(`Failed to load normalization: ${response.status}`);
  }
  cachedNorm = await response.json();
  return cachedNorm;
}

/**
 * Load the live CNN model (cnn_feature_c) for TF.js inference
 * @returns {Promise<{model: tf.LayersModel, normParams: Object}>}
 */
export async function loadLiveModel() {
  if (cachedModel) return cachedModel;
  
  const { model, normParams } = await loadModelAndNorm();
  cachedModel = { model, normParams };
  return cachedModel;
}

/**
 * Get model metadata from benchmark data
 * @param {Object} benchmarkData 
 * @param {string} modelId 
 * @returns {Object} model metadata
 */
export function getModelMetadata(benchmarkData, modelId) {
  return benchmarkData.modelsSummary[modelId] || {};
}

/**
 * Get trip data for a given trip ID
 * @param {Object} benchmarkData 
 * @param {string} tripId 
 * @returns {Object} trip data
 */
export function getTripData(benchmarkData, tripId) {
  return benchmarkData.trips[tripId] || {};
}

/**
 * Get naive baseline velocity (m/s) from training set mean
 * @param {Object} benchmarkData 
 * @returns {number} naive velocity in m/s
 */
export function getNaiveBaselineMs(benchmarkData) {
  return benchmarkData.naiveTrainMeanMs;
}