import { spawn, execSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const canaryScript = path.join(__dirname, 'test-pigeon-auth-canary.sh');

function runStubServerProcess(code) {
  return new Promise((resolve, reject) => {
    const proc = spawn('node', ['-e', code], {
      stdio: ['pipe', 'pipe', 'inherit']
    });
    let output = '';
    proc.stdout.on('data', (chunk) => {
      output += chunk.toString();
      if (output.includes('READY')) {
        const match = output.match(/PIGEON:(\d+);FRONTDOOR:(\d+)/);
        if (match) {
          resolve({
            pigeonPort: parseInt(match[1], 10),
            frontdoorPort: parseInt(match[2], 10),
            kill: () => proc.kill()
          });
        }
      }
    });
    proc.on('error', reject);
    proc.on('exit', (exitCode) => {
      if (!output.includes('READY')) {
        reject(new Error(`Stub process exited prematurely with code ${exitCode}`));
      }
    });
  });
}

async function runHarness() {
  console.log("=== RUNNING PERTURBATION & PASS HARNESS FOR TEST-PIGEON-AUTH-CANARY ===");

  // --- Case 1: Perturbation - Pigeon Auth Regressed (returns 200 for anonymous GET /sessions) ---
  console.log("\n>>> CASE 1: Perturbation - Pigeon auth regressed (anonymous GET returns 200)");
  const server1Script = `
    const http = require('node:http');
    const pigeon = http.createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    });
    const frontdoor = http.createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        status: "ok", degraded: false, pigeon: true, anchor: true,
        degradedRequests: 0, notRoutedMutationToAnchor: 0, htmlPoisonBlocked: 0, version: "test-ver"
      }));
    });
    pigeon.listen(0, '127.0.0.1', () => {
      frontdoor.listen(0, '127.0.0.1', () => {
        console.log(\`READY PIGEON:\${pigeon.address().port};FRONTDOOR:\${frontdoor.address().port}\`);
      });
    });
  `;
  const s1 = await runStubServerProcess(server1Script);
  try {
    const out = execSync(`PIGEON_URL=http://127.0.0.1:${s1.pigeonPort} FRONTDOOR_URL=http://127.0.0.1:${s1.frontdoorPort} STRICT_AUTH=1 bash "${canaryScript}"`, { encoding: 'utf-8' });
    console.log("UNEXPECTED PASS:\n" + out);
  } catch (err) {
    console.log("EXPECTED FAILURE OUTPUT (exit non-zero):\n" + err.stdout);
  } finally {
    s1.kill();
  }

  // --- Case 2: Perturbation - Frontdoor Aggregate Degrade (pigeon unreachable / degraded: true) ---
  console.log("\n>>> CASE 2: Perturbation - Frontdoor aggregate degrade (degraded: true, pigeon: false)");
  const server2Script = `
    const http = require('node:http');
    const pigeon = http.createServer((req, res) => {
      if (req.url === '/health') { res.writeHead(200); res.end("OK"); }
      else { res.writeHead(401); res.end("Unauthorized"); }
    });
    const frontdoor = http.createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        status: "ok", degraded: true, pigeon: false, anchor: true,
        degradedRequests: 15, notRoutedMutationToAnchor: 0, htmlPoisonBlocked: 0, version: "test-ver"
      }));
    });
    pigeon.listen(0, '127.0.0.1', () => {
      frontdoor.listen(0, '127.0.0.1', () => {
        console.log(\`READY PIGEON:\${pigeon.address().port};FRONTDOOR:\${frontdoor.address().port}\`);
      });
    });
  `;
  const s2 = await runStubServerProcess(server2Script);
  try {
    const out = execSync(`PIGEON_URL=http://127.0.0.1:${s2.pigeonPort} FRONTDOOR_URL=http://127.0.0.1:${s2.frontdoorPort} STRICT_AUTH=1 bash "${canaryScript}"`, { encoding: 'utf-8' });
    console.log("UNEXPECTED PASS:\n" + out);
  } catch (err) {
    console.log("EXPECTED FAILURE OUTPUT (exit non-zero):\n" + err.stdout);
  } finally {
    s2.kill();
  }

  // --- Case 3: Perturbation - Frontdoor unrouted mutation leak (notRoutedMutationToAnchor > 0) ---
  console.log("\n>>> CASE 3: Perturbation - Frontdoor unrouted mutation leak (notRoutedMutationToAnchor: 3)");
  const server3Script = `
    const http = require('node:http');
    const pigeon = http.createServer((req, res) => {
      if (req.url === '/health') { res.writeHead(200); res.end("OK"); }
      else { res.writeHead(401); res.end("Unauthorized"); }
    });
    const frontdoor = http.createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        status: "ok", degraded: false, pigeon: true, anchor: true,
        degradedRequests: 0, notRoutedMutationToAnchor: 3, htmlPoisonBlocked: 0, version: "test-ver"
      }));
    });
    pigeon.listen(0, '127.0.0.1', () => {
      frontdoor.listen(0, '127.0.0.1', () => {
        console.log(\`READY PIGEON:\${pigeon.address().port};FRONTDOOR:\${frontdoor.address().port}\`);
      });
    });
  `;
  const s3 = await runStubServerProcess(server3Script);
  try {
    const out = execSync(`PIGEON_URL=http://127.0.0.1:${s3.pigeonPort} FRONTDOOR_URL=http://127.0.0.1:${s3.frontdoorPort} STRICT_AUTH=1 bash "${canaryScript}"`, { encoding: 'utf-8' });
    console.log("UNEXPECTED PASS:\n" + out);
  } catch (err) {
    console.log("EXPECTED FAILURE OUTPUT (exit non-zero):\n" + err.stdout);
  } finally {
    s3.kill();
  }

  // --- Case 4: Simulated Fully-Armed Pigeon & Healthy Frontdoor (PASS STATE) ---
  console.log("\n>>> CASE 4: Simulated fully-armed pigeon & healthy frontdoor (PASS STATE)");
  const server4Script = `
    const http = require('node:http');
    const pigeon = http.createServer((req, res) => {
      if (req.url === '/health') { res.writeHead(200); res.end("OK"); }
      else { res.writeHead(401); res.end("Unauthorized"); }
    });
    const frontdoor = http.createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        status: "ok", degraded: false, pigeon: true, anchor: true,
        degradedRequests: 0, notRoutedMutationToAnchor: 0, htmlPoisonBlocked: 0, version: "test-ver"
      }));
    });
    pigeon.listen(0, '127.0.0.1', () => {
      frontdoor.listen(0, '127.0.0.1', () => {
        console.log(\`READY PIGEON:\${pigeon.address().port};FRONTDOOR:\${frontdoor.address().port}\`);
      });
    });
  `;
  const s4 = await runStubServerProcess(server4Script);
  try {
    const out = execSync(`PIGEON_URL=http://127.0.0.1:${s4.pigeonPort} FRONTDOOR_URL=http://127.0.0.1:${s4.frontdoorPort} STRICT_AUTH=1 bash "${canaryScript}"`, { encoding: 'utf-8' });
    console.log("SUCCESS PASS OUTPUT:\n" + out);
  } catch (err) {
    console.log("UNEXPECTED FAILURE:\n" + err.stdout);
  } finally {
    s4.kill();
  }
}

runHarness().catch(err => {
  console.error("Harness error:", err);
  process.exit(1);
});
