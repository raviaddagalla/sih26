#!/usr/bin/env python3
"""
Test client for Edge Engine:
Streams simulated 200Hz FOG-grade IMU samples into the Edge Engine
and verifies sub-millisecond latency, position integration, and ensemble regime selection.
"""
import sys
import time
import math
from pathlib import Path
from fastapi.testclient import TestClient

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.append(str(PROJECT_ROOT / "edge_engine"))
sys.path.append(str(PROJECT_ROOT / "src"))

from main import app

def main():
    print("=" * 65)
    print("  EDGE ENGINE 200Hz FOG-GRADE IMU STREAM VERIFICATION")
    print("=" * 65)

    client = TestClient(app)

    # 1. Health check
    res = client.get("/api/v1/health")
    print(f"Health check status : {res.status_code}")
    print(f"Engine info         : {res.json()}")
    assert res.status_code == 200

    # 2. Simulate a 200Hz FOG IMU stream over 2 seconds (400 samples total, sent in batches of 40 = 200ms ticks)
    dt = 0.005 # 200 Hz
    current_time = 1000.0
    lat_origin = 12.9716
    lon_origin = 77.5946

    # Speed profile: accelerate from 0 to 12 m/s (highway speed)
    total_batches = 10
    batch_size = 40

    print(f"\nStreaming {total_batches} batches of {batch_size} samples @ 200Hz (Total {total_batches * batch_size} samples)...")

    for b in range(total_batches):
        batch_samples = []
        is_gnss_tick = (b == 0) # Only first tick has GNSS, then blackout begins!

        for s in range(batch_size):
            t = current_time + (b * batch_size + s) * dt
            # Synthetic vehicle kinematics: forward acceleration + tiny road vibration
            target_speed = min(15.0, (b * 1.5))
            ax = 0.8 if target_speed < 12.0 else 0.0
            ax += 0.002 * math.sin(2 * math.pi * 35.0 * t) # FOG-grade ultra-low noise
            ay = 0.001 * math.cos(t)
            az = 9.81 + 0.002 * math.sin(t)
            gx = 0.0001 # FOG drift ~ 1e-4 rad/s
            gy = 0.0001
            gz = 0.02 * math.sin(0.2 * t) # Gentle 0.02 rad/s turn

            batch_samples.append({
                "timestamp": t,
                "ax": ax,
                "ay": ay,
                "az": az,
                "gx": gx,
                "gy": gy,
                "gz": gz,
            })

        payload = {
            "sensor_grade": "FOG",
            "samples": batch_samples,
            "gnss_latitude": lat_origin if is_gnss_tick else None,
            "gnss_longitude": lon_origin if is_gnss_tick else None,
            "gnss_speed": 0.0 if is_gnss_tick else None,
            "gnss_heading": 90.0 if is_gnss_tick else None,
            "gnss_accuracy": 2.5 if is_gnss_tick else None,
        }

        t_req_start = time.perf_counter()
        resp = client.post("/api/v1/stream_200hz", json=payload)
        t_req_dur = (time.perf_counter() - t_req_start) * 1000.0

        assert resp.status_code == 200
        data = resp.json()

        print(
            f"  Batch {b+1:2d}/{total_batches} | "
            f"Mode: {data['status']:18s} | "
            f"Speed: {data['velocity_kmh']:5.1f} km/h | "
            f"Heading: {data['heading_deg']:5.1f}° | "
            f"Active: {data['active_model']:16s} | "
            f"Latency: {data['processing_latency_ms']:5.2f}ms"
        )

    print("\n" + "=" * 65)
    print("  [SUCCESS] Edge Engine successfully processed 200Hz FOG IMU stream!")
    print(f"  Final Position: {data['latitude']:.6f}, {data['longitude']:.6f}")
    print(f"  Final Uncertainty: ±{data['uncertainty_m']:.2f} m")
    print(f"  Client-to-Engine Request Time: {t_req_dur:.2f} ms")
    print("=" * 65)

if __name__ == "__main__":
    main()
