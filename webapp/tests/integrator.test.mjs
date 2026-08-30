import { DeadReckoner } from '../src/experiment/integrator.js';
import { haversine } from '../src/experiment/integrator.js';

console.log('Testing DeadReckoner integrator...');

// Test 1: Basic movement north
console.log('\nTest 1: Basic movement north');
const dr1 = new DeadReckoner(0, 0, 0); // start at equator, prime meridian, heading north
const [lat1, lon1] = dr1.step(25.0, 0.0); // 25 m/s north, no turn
const dist1 = haversine(0, 0, lat1, lon1);
console.log(`Expected: ~25.0m, Got: ${dist1.toFixed(3)}m`);
console.log(`PASS: ${Math.abs(dist1 - 25.0) < 1.0}`);

// Test 2: Heading integration (turn right)
console.log('\nTest 2: Heading integration');
const dr2 = new DeadReckoner(0, 0, 0); // start north
// Apply 0.01 rad/s gyro for 1 sec (about 0.573°/sec)
const [lat2, lon2] = dr2.step(0.0, 0.01); // no forward motion, just turn
const headingDeg = dr2.getHeadingDeg();
console.log(`Expected: ~0.573°, Got: ${headingDeg.toFixed(3)}°`);
console.log(`PASS: ${Math.abs(headingDeg - 0.573) < 0.01}`);

// Test 3: Combined movement and turn
console.log('\nTest 3: Combined movement and turn');
const dr3 = new DeadReckoner(0, 0, 0); // start at origin, heading north
// Go 10 m/s north while turning right at 0.02 rad/s
const [lat3, lon3] = dr3.step(10.0, 0.02);
const dist3 = haversine(0, 0, lat3, lon3);
const heading3 = dr3.getHeadingDeg();
console.log(`Distance: ${dist3.toFixed(3)}m (should be ~10m)`);
console.log(`Heading: ${heading3.toFixed(3)}° (should be ~1.146°)`);
console.log(`Distance PASS: ${Math.abs(dist3 - 10.0) < 0.5}`);
console.log(`Heading PASS: ${Math.abs(heading3 - 1.146) < 0.05}`);

// Test 4: ZUPT (Zero Velocity Update)
console.log('\nTest 4: ZUPT');
const dr4 = new DeadReckoner(0, 0, 0);
const [lat4a, lon4a] = dr4.step(10.0, 0.0); // move 10m
const [lat4b, lon4b] = dr4.step(10.0, 0.0, true); // ZUPT - should not move
const dist4 = haversine(lat4a, lon4a, lat4b, lon4b);
console.log(`Expected: ~0.0m (ZUPT), Got: ${dist4.toFixed(3)}m`);
console.log(`PASS: ${dist4 < 0.1}`);

// Test 5: Independence
console.log('\nTest 5: Independence of instances');
const dr5a = new DeadReckoner(10, 10, 45);
const dr5b = new DeadReckoner(10, 10, 45);
// Apply same inputs
const [lat5a, lon5a] = dr5a.step(5.0, 0.01);
const [lat5b, lon5b] = dr5b.step(5.0, 0.01);
const dist5 = haversine(lat5a, lon5a, lat5b, lon5b);
console.log(`Expected: ~0.0m (same state), Got: ${dist5.toFixed(6)}m`);
console.log(`PASS: ${dist5 < 0.000001}`);

// Test 6: Heading wrapping
console.log('\nTest 6: Heading wrapping (0-360 degrees)');
const dr6 = new DeadReckoner(0, 0, 350); // start at 350° (almost north)
// Add enough gyro to wrap past 360
const [lat6, lon6] = dr6.step(0.0, 0.1); // 0.1 rad/s ≈ 5.73°/sec
const heading6 = dr6.getHeadingDeg();
console.log(`Expected: ~355.73°, Got: ${heading6.toFixed(3)}°`);
console.log(`PASS: ${heading6 >= 0 && heading6 < 360 && Math.abs(heading6 - 355.73) < 0.01}`);

console.log('\nAll tests completed!');