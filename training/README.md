# Intelligent Dead Reckoning (IDR) — Model Training & Evaluation Pipeline

This directory provides the complete provenance, training, export, and evaluation pipeline for the on-device **VelocityCNN** model used in the SIH Smartphone-Only Inertial Navigation System.

---

## 1. Model Architecture

The model solves forward speed estimation and stationary detection directly from a sliding window of phone IMU data without GNSS:
- **Input Shape**: `[batch, 6, 200]` (channels-first: $a_x, a_y, a_z, g_x, g_y, g_z$; 200 samples = 2.0 seconds at 100 Hz).
- **Backbone**:
  - `Conv1D(in=6, out=32, kernel=3, padding=1)` + `ReLU`
  - `Conv1D(in=32, out=64, kernel=3, padding=1)` + `ReLU`
  - `GlobalAveragePooling1D` over temporal dimension
  - `Linear(64, 64)` + `ReLU` + `Dropout(0.2)`
- **Multi-Task Heads**:
  - **Head 1 (Velocity Regression)**: `Linear(64, 1)` $\to$ forward vehicle speed ($v \ge 0$ m/s).
  - **Head 2 (Stationary Classification)**: `Linear(64, 1)` $\to$ binary stationary logit / zero-velocity indicator.

---

## 2. Dataset Preprocessing & Normalization

Data is sourced from the **IO-VNBD** (Inertial Odometry Vehicular Navigation Benchmark Dataset), recorded using smartphones mounted in diverse vehicle types (scooters, two-wheelers, cars) across urban road corridors:
- **Sampling Rate**: Standardized to 100 Hz.
- **Vibration Suppression**: Linear acceleration and angular rates are normalized using global empirical dataset parameters stored in `norm_params.json`:
  - Mean: `[-0.009899, -0.002134, 0.031721, 0.000070, 0.003207, 0.000176]`
  - Standard Deviation: `[1.081855, 0.725581, 1.096618, 0.146183, 0.105848, 0.079243]`

---

## 3. Training Regimen

Run the training pipeline:
```bash
python training/train.py --epochs 25 --batch_size 64 --lr 0.001
```

- **Loss Function**: Multi-task joint loss:
  $$\mathcal{L} = \mathcal{L}_{\text{MSE}}(v_{\text{pred}}, v_{\text{gt}}) + 0.5 \cdot \mathcal{L}_{\text{BCE}}(s_{\text{logit}}, s_{\text{label}})$$
- **Optimizer**: Adam ($\beta_1=0.9, \beta_2=0.999$, weight decay $10^{-4}$) with `ReduceLROnPlateau` learning rate scheduling.

---

## 4. On-Device Model Export & Quantization

To deploy on smartphones via Flutter's `tflite_flutter` engine:
```bash
# Export FP32 baseline
python training/export_tflite.py --quantize none

# Export Float16 for mobile GPU/NPU acceleration
python training/export_tflite.py --quantize float16

# Export INT8 post-training quantization for low-power edge DSP
python training/export_tflite.py --quantize int8
```

The exported `.tflite` model produces fixed inference latency of $\le 4$ ms on smartphone hardware.

---

## 5. Evaluation & Drift Benchmarking

Evaluate against held-out IO-VNBD sequences and generate speed and position trajectory plots:
```bash
python training/evaluate.py
```

Generated outputs:
- `evaluation_plots/speed_evaluation.png`: Time-series comparison of predicted forward speed vs. ground-truth speed.
- `evaluation_plots/trajectory_evaluation.png`: 2D horizontal dead-reckoning trajectory vs. ground-truth path under simulated continuous GNSS blackout.
- `evaluation_plots/evaluation_report.json`: Metrics report against competition drift targets.

### Target Performance Benchmarks:
1. **Drift %**: $< 10.0\%$ of total distance traveled during GNSS blackout.
2. **Short Blackout**: $< 5.0$ meters drift over 50 meters distance in $< 1$ minute.
3. **High-Speed Corridor**: $< 100.0$ meters drift over 1 km at 60 km/h.
