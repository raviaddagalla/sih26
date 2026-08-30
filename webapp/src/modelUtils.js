import * as tf from '@tensorflow/tfjs';

/**
 * Load the live CNN model (cnn_feature_c) and normalization parameters.
 * Other models are handled via replayed data from benchmark.json.
 */
export async function loadModelAndNorm() {
  // Load normalization params (used by all models)
  const normRes = await fetch('/model/norm_params.json');
  const normParams = await normRes.json();
  
  // Load weights for the live CNN model (cnn_feature_c)
  // This is the only model we verify works in browser via TF.js
  const weightsRes = await fetch('/model/model_weights.json');
  const weightsData = await weightsRes.json();
  
  // Reconstruct the CNN model structure (Functional API for Two Heads)
  // Input: [batch, 20, 6] (Feature Set C: 6 channels)
  const input = tf.input({shape: [20, 6]});
  
  const conv1 = tf.layers.conv1d({
    filters: 32, kernelSize: 3, padding: 'same', activation: 'relu'
  }).apply(input);
  
  const conv2 = tf.layers.conv1d({
    filters: 64, kernelSize: 3, padding: 'same', activation: 'relu'
  }).apply(conv1);
  
  const gap = tf.layers.globalAveragePooling1d({}).apply(conv2);
  
  const fc1 = tf.layers.dense({
    units: 64, activation: 'relu'
  }).apply(gap);
  
  // Velocity Regression Head
  const velHead = tf.layers.dense({
    units: 1, activation: 'linear', name: 'velHead'
  }).apply(fc1);
  
  // Stationary Classification Head
  const statHead = tf.layers.dense({
    units: 1, activation: 'linear', name: 'statHead'
  }).apply(fc1);
  
  const model = tf.model({inputs: input, outputs: [velHead, statHead]});
  
  // Initialize layers so we can set weights
  model.predict(tf.zeros([1, 20, 6])).map(t => t.dispose());
  
  // Set weights
  const l0 = model.layers.find(l => l.name.startsWith('conv1d') && l.filters === 32);
  l0.setWeights([
    tf.tensor3d(weightsData['conv1/kernel'], [3, 6, 32]),
    tf.tensor1d(weightsData['conv1/bias'])
  ]);
  
  const l1 = model.layers.find(l => l.name.startsWith('conv1d') && l.filters === 64);
  l1.setWeights([
    tf.tensor3d(weightsData['conv2/kernel'], [3, 32, 64]),
    tf.tensor1d(weightsData['conv2/bias'])
  ]);
  
  const l_fc1 = model.layers.find(l => l.name.startsWith('dense') && l.units === 64);
  l_fc1.setWeights([
    tf.tensor2d(weightsData['fc1/kernel'], [64, 64]),
    tf.tensor1d(weightsData['fc1/bias'])
  ]);
  
  const l_vel = model.layers.find(l => l.name === 'velHead');
  l_vel.setWeights([
    tf.tensor2d(weightsData['fc2/kernel'], [64, 1]),
    tf.tensor1d(weightsData['fc2/bias'])
  ]);
  
  const l_stat = model.layers.find(l => l.name === 'statHead');
  l_stat.setWeights([
    tf.tensor2d(weightsData['fc_stat/kernel'], [64, 1]),
    tf.tensor1d(weightsData['fc_stat/bias'])
  ]);
  
  return { model, normParams };
}

/**
 * Preprocess a window for the live CNN model (Feature Set C)
 * @param {Array<Array<number>>} windowData - 20x12 raw IMU window
 * @param {Object} normParams - normalization parameters
 * @returns {tf.Tensor} preprocessed tensor [1, 20, 6]
 */
export function preprocessWindow(windowData, normParams) {
  // Set C uses only these 6 channels from the 12-channel normParams
  // [0]=Linear Accel X, [1]=Y, [2]=Z, [6]=Gyro Yaw, [7]=Pitch, [8]=Roll
  const indicesC = [0, 1, 2, 6, 7, 8];
  const means = indicesC.map(i => normParams.means[i]);
  const stds = indicesC.map(i => normParams.stds[i]);
  
  const normalized = windowData.map(row => {
    return row.map((val, colIdx) => {
      return (val - means[colIdx]) / stds[colIdx];
    });
  });
  
  return tf.tensor3d([normalized], [1, 20, 6]);
}