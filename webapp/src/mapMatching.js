export function haversine(lon1, lat1, lon2, lat2) {
  const R = 6371000; // Earth radius in meters
  const toRad = Math.PI / 180;
  
  const dLat = (lat2 - lat1) * toRad;
  const dLon = (lon2 - lon1) * toRad;
  
  const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2);
            
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

export function pointToLineDistance(pt, lineStart, lineEnd) {
  const R = 6371000;
  const latRad = pt[1] * (Math.PI / 180.0);
  
  function toXY(p) {
    const x = p[0] * (Math.PI / 180.0) * R * Math.cos(latRad);
    const y = p[1] * (Math.PI / 180.0) * R;
    return [x, y];
  }
  
  function toLonLat(xy) {
    const lon = xy[0] / (R * Math.cos(latRad) * (Math.PI / 180.0));
    const lat = xy[1] / (R * (Math.PI / 180.0));
    return [lon, lat];
  }

  const p = toXY(pt);
  const v = toXY(lineStart);
  const w = toXY(lineEnd);
  
  const dx = w[0] - v[0];
  const dy = w[1] - v[1];
  const l2 = dx*dx + dy*dy;
  
  if (l2 === 0) return { dist: haversine(pt[0], pt[1], lineStart[0], lineStart[1]), proj: lineStart };
  
  let t = ((p[0] - v[0]) * dx + (p[1] - v[1]) * dy) / l2;
  
  let proj;
  if (t < 0.0) {
    proj = lineStart;
  } else if (t > 1.0) {
    proj = lineEnd;
  } else {
    proj = toLonLat([v[0] + t * dx, v[1] + t * dy]);
  }
  
  const dist = haversine(pt[0], pt[1], proj[0], proj[1]);
  return { dist, proj };
}

export class SimpleMapMatcher {
  constructor(roadSegments) {
    this.segments = roadSegments;
  }
  
  snap(lat, lon) {
    if (!this.segments || this.segments.length === 0) return [lat, lon];
    
    let minDist = Infinity;
    let bestProj = [lon, lat];
    
    const pt = [lon, lat];
    
    for (const segment of this.segments) {
      const { dist, proj } = pointToLineDistance(pt, segment[0], segment[1]);
      if (dist < minDist) {
        minDist = dist;
        bestProj = proj;
      }
    }
    
    return [bestProj[1], bestProj[0]];
  }
}
\n
export class HMMMapMatcher {
  constructor(roadSegments, emissionSigma = 10.0, transBeta = 20.0) {
    this.segments = roadSegments;
    this.emissionSigma = emissionSigma;
    this.transBeta = transBeta;
    this.V = {}; // previous step probabilities
    this.path = {}; // previous step paths
    this.prevPt = null;
  }
  
  emissionProb(dist) {
    return (1.0 / (Math.sqrt(2 * Math.PI) * this.emissionSigma)) * Math.exp(-0.5 * Math.pow(dist / this.emissionSigma, 2));
  }
  
  transProb(p1, p2, p1Proj, p2Proj) {
    const gcDist = haversine(p1[0], p1[1], p2[0], p2[1]);
    const routeDist = haversine(p1Proj[0], p1Proj[1], p2Proj[0], p2Proj[1]);
    const diff = Math.abs(gcDist - routeDist);
    return (1.0 / this.transBeta) * Math.exp(-diff / this.transBeta);
  }
  
  snap(lat, lon) {
    if (!this.segments || this.segments.length === 0) return [lat, lon];
    
    const pt = [lon, lat];
    const newV = {};
    const newPath = {};
    
    // Candidates
    const candidates = [];
    let fallbackMinDist = Infinity;
    let fallbackBest = null;
    let fallbackIndex = -1;
    
    for (let i = 0; i < this.segments.length; i++) {
      const segment = this.segments[i];
      const { dist, proj } = pointToLineDistance(pt, segment[0], segment[1]);
      if (dist < 100.0) {
        candidates.push({ i, dist, proj });
      }
      if (dist < fallbackMinDist) {
        fallbackMinDist = dist;
        fallbackBest = proj;
        fallbackIndex = i;
      }
    }
    
    if (candidates.length === 0) {
      candidates.push({ i: fallbackIndex, dist: fallbackMinDist, proj: fallbackBest });
    }
    
    if (!this.prevPt) {
      // Initialize
      for (const cand of candidates) {
        newV[cand.i] = Math.log(this.emissionProb(cand.dist) + 1e-12);
        newPath[cand.i] = [cand.proj];
      }
    } else {
      // Step
      for (const cand of candidates) {
        let maxProb = -Infinity;
        let maxState = null;
        
        for (const [y0Str, prob0] of Object.entries(this.V)) {
          const y0 = parseInt(y0Str);
          // If we lost track of this path, ignore
          if (!this.path[y0]) continue;
          
          const prevProj = this.path[y0][this.path[y0].length - 1];
          const transP = this.transProb(this.prevPt, pt, prevProj, cand.proj);
          const prob = prob0 + Math.log(transP + 1e-12) + Math.log(this.emissionProb(cand.dist) + 1e-12);
          
          if (prob > maxProb) {
            maxProb = prob;
            maxState = y0;
          }
        }
        
        newV[cand.i] = maxProb;
        // Memory leak prevention: only store the latest point for online matching
        newPath[cand.i] = [cand.proj]; 
      }
    }
    
    this.V = newV;
    this.path = newPath;
    this.prevPt = pt;
    
    // Return best current state
    let maxProb = -Infinity;
    let bestProj = [lon, lat];
    
    for (const [y, prob] of Object.entries(this.V)) {
      if (prob > maxProb) {
        maxProb = prob;
        bestProj = this.path[y][0];
      }
    }
    
    return [bestProj[1], bestProj[0]];
  }
}
