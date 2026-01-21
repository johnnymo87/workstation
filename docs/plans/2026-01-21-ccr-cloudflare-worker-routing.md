# CCR Cloudflare Worker Routing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace random Cloudflare Tunnel load balancing with deterministic webhook routing via a Cloudflare Worker + Durable Objects architecture, enabling simultaneous Claude Code sessions on multiple machines (macOS + devbox) to receive commands correctly.

**Architecture:** Cloudflare Worker receives all Telegram webhooks and stores session→machine mappings in Durable Objects. Each machine runs a "machine agent" that maintains an outbound WebSocket connection to the Worker. Commands are pushed over WebSocket to the correct machine for local nvim/PTY injection.

**Tech Stack:** Cloudflare Workers, Durable Objects (SQLite), WebSocket, Node.js, existing CCR infrastructure

---

## Architecture Overview

```
┌─────────────────┐     ┌─────────────────┐
│ macOS (work)    │     │ devbox (side)   │
│                 │     │                 │
│ Claude sessions │     │ Claude sessions │
│ CCR webhook srv │     │ CCR webhook srv │
│ Machine Agent ──┼─────┼── Machine Agent │
│   (WebSocket)   │     │   (WebSocket)   │
└────────┬────────┘     └────────┬────────┘
         │                       │
         │  outbound WebSocket   │
         └───────────┬───────────┘
                     │
         ┌───────────▼───────────┐
         │ Cloudflare Worker     │
         │ + Durable Object      │
         │                       │
         │ - Session registry    │
         │ - Message→Session map │
         │ - Command queue       │
         │ - WebSocket hub       │
         └───────────┬───────────┘
                     │
         ┌───────────▼───────────┐
         │ Telegram Bot API      │
         │ (webhook endpoint)    │
         └───────────────────────┘
```

---

## Phase 1: Cloudflare Worker + Durable Object (Tasks 1-6)

**Run on:** Devbox (or any machine with `wrangler` CLI)

### Task 1: Set up Cloudflare Workers project

**Files:**
- Create: `~/projects/ccr-worker/wrangler.toml`
- Create: `~/projects/ccr-worker/package.json`
- Create: `~/projects/ccr-worker/src/index.js`

**Step 1: Create project directory**

```bash
mkdir -p ~/projects/ccr-worker/src
cd ~/projects/ccr-worker
```

**Step 2: Initialize package.json**

```bash
npm init -y
```

**Step 3: Create wrangler.toml**

```toml
name = "ccr-router"
main = "src/index.js"
compatibility_date = "2024-01-01"

[durable_objects]
bindings = [
  { name = "ROUTER", class_name = "RouterDO" }
]

[[migrations]]
tag = "v1"
new_classes = ["RouterDO"]

[vars]
# Set via wrangler secret
# TELEGRAM_WEBHOOK_SECRET = ""
# TELEGRAM_BOT_TOKEN = ""
```

**Step 4: Create minimal Worker entry point**

```javascript
// src/index.js
export { RouterDO } from './router-do.js';

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // Health check
    if (url.pathname === '/health') {
      return new Response('ok', { status: 200 });
    }

    // All other requests go to the Durable Object
    const id = env.ROUTER.idFromName('global');
    const stub = env.ROUTER.get(id);
    return stub.fetch(request);
  }
};
```

**Step 5: Create placeholder Durable Object**

```javascript
// src/router-do.js
export class RouterDO {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    return new Response('RouterDO placeholder', { status: 200 });
  }
}
```

**Step 6: Commit**

```bash
git init
git add -A
git commit -m "Initial Cloudflare Worker project structure"
```

---

### Task 2: Implement Durable Object SQLite schema

**Files:**
- Modify: `~/projects/ccr-worker/src/router-do.js`

**Step 1: Add SQLite initialization**

```javascript
// src/router-do.js
export class RouterDO {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.sql = state.storage.sql;

    // WebSocket connections by machineId
    this.machines = new Map();
  }

  async initialize() {
    // Sessions: which machine owns which session
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY,
        machine_id TEXT NOT NULL,
        label TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    `);

    // Messages: map Telegram message_id to session for reply routing
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS messages (
        chat_id INTEGER NOT NULL,
        message_id INTEGER NOT NULL,
        session_id TEXT NOT NULL,
        token TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (chat_id, message_id)
      )
    `);

    // Command queue: pending commands for offline machines
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS command_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        machine_id TEXT NOT NULL,
        session_id TEXT NOT NULL,
        command TEXT NOT NULL,
        chat_id INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    `);

    // Indexes
    this.sql.exec(`
      CREATE INDEX IF NOT EXISTS idx_sessions_machine ON sessions(machine_id)
    `);
    this.sql.exec(`
      CREATE INDEX IF NOT EXISTS idx_queue_machine ON command_queue(machine_id)
    `);
    this.sql.exec(`
      CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(created_at)
    `);
  }

  async fetch(request) {
    // Ensure tables exist
    await this.initialize();

    return new Response('RouterDO initialized', { status: 200 });
  }
}
```

**Step 2: Commit**

```bash
git add src/router-do.js
git commit -m "Add Durable Object SQLite schema

Tables: sessions, messages, command_queue
Indexes for machine lookups and cleanup"
```

---

### Task 3: Implement session registration API

**Files:**
- Modify: `~/projects/ccr-worker/src/router-do.js`

**Step 1: Add session registration handler**

Add these methods to the `RouterDO` class:

```javascript
  // Inside RouterDO class, after initialize()

  async handleRegisterSession(body) {
    const { sessionId, machineId, label } = body;

    if (!sessionId || !machineId) {
      return new Response(JSON.stringify({ error: 'sessionId and machineId required' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    const now = Date.now();

    this.sql.exec(`
      INSERT INTO sessions (session_id, machine_id, label, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(session_id) DO UPDATE SET
        machine_id = excluded.machine_id,
        label = excluded.label,
        updated_at = excluded.updated_at
    `, sessionId, machineId, label || null, now, now);

    console.log(`Session registered: ${sessionId} → ${machineId} (${label || 'no label'})`);

    return new Response(JSON.stringify({ ok: true, sessionId, machineId }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  async handleUnregisterSession(body) {
    const { sessionId } = body;

    if (!sessionId) {
      return new Response(JSON.stringify({ error: 'sessionId required' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    this.sql.exec(`DELETE FROM sessions WHERE session_id = ?`, sessionId);
    this.sql.exec(`DELETE FROM messages WHERE session_id = ?`, sessionId);

    console.log(`Session unregistered: ${sessionId}`);

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  }
```

**Step 2: Update fetch handler to route requests**

Replace the `fetch` method:

```javascript
  async fetch(request) {
    await this.initialize();

    const url = new URL(request.url);
    const path = url.pathname;

    try {
      // Session management
      if (path === '/sessions/register' && request.method === 'POST') {
        const body = await request.json();
        return this.handleRegisterSession(body);
      }

      if (path === '/sessions/unregister' && request.method === 'POST') {
        const body = await request.json();
        return this.handleUnregisterSession(body);
      }

      // List sessions (for debugging)
      if (path === '/sessions' && request.method === 'GET') {
        const rows = this.sql.exec(`SELECT * FROM sessions`).toArray();
        return new Response(JSON.stringify(rows), {
          headers: { 'Content-Type': 'application/json' }
        });
      }

      return new Response('Not found', { status: 404 });

    } catch (err) {
      console.error('Error:', err);
      return new Response(JSON.stringify({ error: err.message }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' }
      });
    }
  }
```

**Step 3: Commit**

```bash
git add src/router-do.js
git commit -m "Add session registration API

POST /sessions/register - register session with machine
POST /sessions/unregister - remove session
GET /sessions - list all sessions (debug)"
```

---

### Task 4: Implement Telegram notification send-through

**Files:**
- Modify: `~/projects/ccr-worker/src/router-do.js`

**Step 1: Add notification sending method**

```javascript
  // Inside RouterDO class

  async handleSendNotification(body) {
    const { sessionId, chatId, text, replyMarkup } = body;

    if (!sessionId || !chatId || !text) {
      return new Response(JSON.stringify({ error: 'sessionId, chatId, and text required' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    // Get session to verify it exists
    const session = this.sql.exec(
      `SELECT * FROM sessions WHERE session_id = ?`, sessionId
    ).toArray()[0];

    if (!session) {
      return new Response(JSON.stringify({ error: 'Session not found' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    // Generate token for this notification
    const token = this.generateToken();

    // Send to Telegram
    const telegramResponse = await fetch(
      `https://api.telegram.org/bot${this.env.TELEGRAM_BOT_TOKEN}/sendMessage`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          chat_id: chatId,
          text: text,
          parse_mode: 'Markdown',
          reply_markup: replyMarkup || undefined
        })
      }
    );

    const telegramResult = await telegramResponse.json();

    if (!telegramResult.ok) {
      console.error('Telegram error:', telegramResult);
      return new Response(JSON.stringify({ error: 'Telegram API error', details: telegramResult }), {
        status: 502,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    const messageId = telegramResult.result.message_id;

    // Store message → session mapping for reply routing
    const now = Date.now();
    this.sql.exec(`
      INSERT INTO messages (chat_id, message_id, session_id, token, created_at)
      VALUES (?, ?, ?, ?, ?)
    `, chatId, messageId, sessionId, token, now);

    console.log(`Notification sent: msg ${messageId} → session ${sessionId}`);

    return new Response(JSON.stringify({
      ok: true,
      messageId,
      token
    }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  generateToken() {
    const bytes = new Uint8Array(12);
    crypto.getRandomValues(bytes);
    return btoa(String.fromCharCode(...bytes))
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=/g, '');
  }
```

**Step 2: Add route to fetch handler**

Add to the `fetch` method's try block:

```javascript
      // Notification sending (proxied through Worker)
      if (path === '/notifications/send' && request.method === 'POST') {
        const body = await request.json();
        return this.handleSendNotification(body);
      }
```

**Step 3: Commit**

```bash
git add src/router-do.js
git commit -m "Add notification send-through API

POST /notifications/send - send Telegram notification
Stores message_id → session mapping for reply routing"
```

---

### Task 5: Implement Telegram webhook handler

**Files:**
- Modify: `~/projects/ccr-worker/src/router-do.js`

**Step 1: Add webhook verification**

```javascript
  // Inside RouterDO class

  verifyWebhookSecret(request) {
    const secret = request.headers.get('X-Telegram-Bot-Api-Secret-Token');
    return secret === this.env.TELEGRAM_WEBHOOK_SECRET;
  }
```

**Step 2: Add webhook handler**

```javascript
  async handleTelegramWebhook(request) {
    // Verify webhook secret
    if (!this.verifyWebhookSecret(request)) {
      console.warn('Invalid webhook secret');
      return new Response('Unauthorized', { status: 401 });
    }

    const update = await request.json();
    console.log('Webhook received:', JSON.stringify(update).slice(0, 200));

    // Handle message (including replies)
    if (update.message) {
      return this.handleTelegramMessage(update.message);
    }

    // Handle callback query (button clicks)
    if (update.callback_query) {
      return this.handleTelegramCallback(update.callback_query);
    }

    // Acknowledge other update types
    return new Response('ok', { status: 200 });
  }

  async handleTelegramMessage(message) {
    const chatId = message.chat.id;
    const text = message.text || '';
    const replyToMessage = message.reply_to_message;

    // Try to route via reply-to-message
    let sessionId = null;
    let token = null;

    if (replyToMessage) {
      const mapping = this.sql.exec(`
        SELECT session_id, token FROM messages
        WHERE chat_id = ? AND message_id = ?
      `, chatId, replyToMessage.message_id).toArray()[0];

      if (mapping) {
        sessionId = mapping.session_id;
        token = mapping.token;
      }
    }

    // If no reply-to match, try parsing /cmd TOKEN format
    if (!sessionId) {
      const cmdMatch = text.match(/^\/cmd\s+(\S+)\s+(.+)$/s);
      if (cmdMatch) {
        token = cmdMatch[1];
        // Look up session by token
        const mapping = this.sql.exec(`
          SELECT session_id FROM messages WHERE token = ?
        `, token).toArray()[0];
        if (mapping) {
          sessionId = mapping.session_id;
        }
      }
    }

    if (!sessionId) {
      // Can't route - send error
      await this.sendTelegramMessage(chatId,
        '⏰ Could not find session for this message. Please reply to a recent notification or use /cmd TOKEN command format.');
      return new Response('ok', { status: 200 });
    }

    // Get the command text
    let command = text;
    if (text.startsWith('/cmd')) {
      command = text.replace(/^\/cmd\s+\S+\s+/, '');
    }

    // Route command to machine
    return this.routeCommandToMachine(sessionId, command, chatId);
  }

  async handleTelegramCallback(callbackQuery) {
    const chatId = callbackQuery.message?.chat.id;
    const messageId = callbackQuery.message?.message_id;
    const data = callbackQuery.data; // e.g., "cmd:TOKEN:continue"

    // Parse callback data
    const parts = data.split(':');
    if (parts[0] !== 'cmd' || parts.length < 3) {
      return new Response('ok', { status: 200 });
    }

    const token = parts[1];
    const action = parts.slice(2).join(':');

    // Look up session
    const mapping = this.sql.exec(`
      SELECT session_id FROM messages WHERE token = ?
    `, token).toArray()[0];

    if (!mapping) {
      await this.answerCallbackQuery(callbackQuery.id, 'Session expired');
      return new Response('ok', { status: 200 });
    }

    // Map action to command
    const commandMap = {
      'continue': '',
      'yes': 'y',
      'no': 'n',
      'exit': '/exit'
    };

    const command = commandMap[action] ?? action;

    // Acknowledge the button press
    await this.answerCallbackQuery(callbackQuery.id, `Sending: ${command || '(continue)'}`);

    // Route to machine
    return this.routeCommandToMachine(mapping.session_id, command, chatId);
  }

  async sendTelegramMessage(chatId, text) {
    await fetch(`https://api.telegram.org/bot${this.env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: chatId, text })
    });
  }

  async answerCallbackQuery(callbackQueryId, text) {
    await fetch(`https://api.telegram.org/bot${this.env.TELEGRAM_BOT_TOKEN}/answerCallbackQuery`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ callback_query_id: callbackQueryId, text })
    });
  }
```

**Step 3: Add placeholder for command routing**

```javascript
  async routeCommandToMachine(sessionId, command, chatId) {
    // Get machine for this session
    const session = this.sql.exec(`
      SELECT machine_id, label FROM sessions WHERE session_id = ?
    `, sessionId).toArray()[0];

    if (!session) {
      await this.sendTelegramMessage(chatId, '❌ Session not found');
      return new Response('ok', { status: 200 });
    }

    const machineId = session.machine_id;

    // Check if machine is connected via WebSocket
    const ws = this.machines.get(machineId);

    if (ws && ws.readyState === 1) { // WebSocket.OPEN
      // Send command over WebSocket
      ws.send(JSON.stringify({
        type: 'command',
        sessionId,
        command,
        chatId
      }));

      console.log(`Command sent to ${machineId}: ${command.slice(0, 50)}`);
      return new Response('ok', { status: 200 });
    }

    // Machine offline - queue command
    const now = Date.now();
    this.sql.exec(`
      INSERT INTO command_queue (machine_id, session_id, command, chat_id, created_at)
      VALUES (?, ?, ?, ?, ?)
    `, machineId, sessionId, command, chatId, now);

    await this.sendTelegramMessage(chatId,
      `📥 Command queued - ${session.label || machineId} is offline. Will deliver when it reconnects.`);

    return new Response('ok', { status: 200 });
  }
```

**Step 4: Add route to fetch handler**

Add to the `fetch` method's try block:

```javascript
      // Telegram webhook
      if (path.startsWith('/webhook/telegram') && request.method === 'POST') {
        return this.handleTelegramWebhook(request);
      }
```

**Step 5: Commit**

```bash
git add src/router-do.js
git commit -m "Add Telegram webhook handler

- Verify webhook secret
- Route replies via message_id mapping
- Parse /cmd TOKEN format as fallback
- Handle callback queries (button clicks)
- Queue commands for offline machines"
```

---

### Task 6: Implement WebSocket handler for machine agents

**Files:**
- Modify: `~/projects/ccr-worker/src/router-do.js`

**Step 1: Add WebSocket handling**

```javascript
  // Inside RouterDO class

  async handleWebSocket(request) {
    const url = new URL(request.url);
    const machineId = url.searchParams.get('machineId');

    if (!machineId) {
      return new Response('machineId required', { status: 400 });
    }

    // Accept WebSocket upgrade
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    // Store connection
    this.machines.set(machineId, server);

    server.accept();

    console.log(`Machine connected: ${machineId}`);

    // Send queued commands
    this.flushCommandQueue(machineId, server);

    server.addEventListener('message', async (event) => {
      try {
        const msg = JSON.parse(event.data);
        await this.handleMachineMessage(machineId, msg);
      } catch (err) {
        console.error('Error handling machine message:', err);
      }
    });

    server.addEventListener('close', () => {
      console.log(`Machine disconnected: ${machineId}`);
      this.machines.delete(machineId);
    });

    server.addEventListener('error', (err) => {
      console.error(`WebSocket error for ${machineId}:`, err);
      this.machines.delete(machineId);
    });

    return new Response(null, {
      status: 101,
      webSocket: client
    });
  }

  async flushCommandQueue(machineId, ws) {
    const commands = this.sql.exec(`
      SELECT id, session_id, command, chat_id
      FROM command_queue
      WHERE machine_id = ?
      ORDER BY created_at ASC
    `, machineId).toArray();

    if (commands.length === 0) return;

    console.log(`Flushing ${commands.length} queued commands to ${machineId}`);

    for (const cmd of commands) {
      ws.send(JSON.stringify({
        type: 'command',
        sessionId: cmd.session_id,
        command: cmd.command,
        chatId: cmd.chat_id
      }));

      // Delete from queue
      this.sql.exec(`DELETE FROM command_queue WHERE id = ?`, cmd.id);
    }
  }

  async handleMachineMessage(machineId, msg) {
    // Handle messages from machine agents
    if (msg.type === 'ping') {
      const ws = this.machines.get(machineId);
      if (ws) ws.send(JSON.stringify({ type: 'pong' }));
      return;
    }

    if (msg.type === 'commandResult') {
      // Machine reporting command execution result
      const { sessionId, success, error, chatId } = msg;

      if (!success && chatId) {
        await this.sendTelegramMessage(chatId, `❌ Command failed: ${error}`);
      }
      return;
    }

    console.log(`Unknown message from ${machineId}:`, msg);
  }
```

**Step 2: Update fetch handler for WebSocket upgrade**

Add at the beginning of the `fetch` method's try block:

```javascript
      // WebSocket upgrade for machine agents
      if (path === '/ws' && request.headers.get('Upgrade') === 'websocket') {
        return this.handleWebSocket(request);
      }
```

**Step 3: Add cleanup method**

```javascript
  // Inside RouterDO class

  async cleanup() {
    const oneDayAgo = Date.now() - 24 * 60 * 60 * 1000;

    // Clean old messages
    const msgResult = this.sql.exec(`
      DELETE FROM messages WHERE created_at < ?
    `, oneDayAgo);

    // Clean old queued commands (shouldn't happen if machines reconnect)
    const queueResult = this.sql.exec(`
      DELETE FROM command_queue WHERE created_at < ?
    `, oneDayAgo);

    // Clean stale sessions (no activity in 24h)
    const sessionResult = this.sql.exec(`
      DELETE FROM sessions WHERE updated_at < ?
    `, oneDayAgo);

    console.log(`Cleanup: ${msgResult.changes} messages, ${queueResult.changes} queued, ${sessionResult.changes} sessions`);
  }
```

**Step 4: Add cleanup route**

Add to the `fetch` method's try block:

```javascript
      // Cleanup (call periodically via cron or manually)
      if (path === '/cleanup' && request.method === 'POST') {
        await this.cleanup();
        return new Response(JSON.stringify({ ok: true }), {
          headers: { 'Content-Type': 'application/json' }
        });
      }
```

**Step 5: Commit**

```bash
git add src/router-do.js
git commit -m "Add WebSocket handler for machine agents

- Accept machine connections with machineId
- Flush queued commands on connect
- Handle ping/pong and commandResult messages
- Add cleanup for old data"
```

---

## Phase 2: Deploy Worker (Tasks 7-9)

**Run on:** Devbox (has wrangler CLI)

### Task 7: Install wrangler and authenticate

**Step 1: Install wrangler globally**

```bash
npm install -g wrangler
```

**Step 2: Login to Cloudflare**

```bash
wrangler login
```

This opens a browser for OAuth. Complete the authentication.

**Step 3: Verify authentication**

```bash
wrangler whoami
```

Expected: Shows your Cloudflare account info.

---

### Task 8: Set Worker secrets

**Step 1: Get your Telegram bot token and webhook secret**

From your existing CCR `.env` file:
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_WEBHOOK_SECRET`

**Step 2: Set secrets in Cloudflare**

```bash
cd ~/projects/ccr-worker

# Set bot token
wrangler secret put TELEGRAM_BOT_TOKEN
# Paste your token when prompted

# Set webhook secret
wrangler secret put TELEGRAM_WEBHOOK_SECRET
# Paste your secret when prompted
```

**Step 3: Verify secrets are set**

```bash
wrangler secret list
```

Expected: Shows both secrets (values hidden).

---

### Task 9: Deploy Worker and update Telegram webhook

**Step 1: Deploy the Worker**

```bash
cd ~/projects/ccr-worker
wrangler deploy
```

Note the Worker URL (e.g., `https://ccr-router.<account>.workers.dev`).

**Step 2: Get your webhook path secret**

From your CCR `.env`:
- `TELEGRAM_WEBHOOK_PATH_SECRET` (e.g., `980f1e0b42aa018d9fa8863c7e5c70c2`)

**Step 3: Update Telegram webhook to point to Worker**

```bash
# Replace with your actual values
WORKER_URL="https://ccr-router.<account>.workers.dev"
PATH_SECRET="980f1e0b42aa018d9fa8863c7e5c70c2"
BOT_TOKEN="your-bot-token"
WEBHOOK_SECRET="your-webhook-secret"

curl -X POST "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
  -H "Content-Type: application/json" \
  -d "{
    \"url\": \"${WORKER_URL}/webhook/telegram/${PATH_SECRET}\",
    \"secret_token\": \"${WEBHOOK_SECRET}\",
    \"drop_pending_updates\": true
  }"
```

Expected: `{"ok":true,"result":true,"description":"Webhook was set"}`

**Step 4: Verify webhook is set**

```bash
curl "https://api.telegram.org/bot${BOT_TOKEN}/getWebhookInfo" | jq
```

Expected: Shows your Worker URL as the webhook.

**Step 5: Commit wrangler.toml updates (if any)**

```bash
git add wrangler.toml
git commit -m "Configure Worker deployment" || echo "Nothing to commit"
```

---

## Phase 3: CCR Machine Agent (Tasks 10-14)

**Run on:** Devbox (CCR development)

### Task 10: Create machine agent module

**Files:**
- Create: `~/projects/claude-code-remote/src/worker-client/machine-agent.js`

**Step 1: Create directory**

```bash
mkdir -p ~/projects/claude-code-remote/src/worker-client
```

**Step 2: Create machine agent**

```javascript
// src/worker-client/machine-agent.js
const WebSocket = require('ws');
const os = require('os');
const { createLogger } = require('../core/logger');

const logger = createLogger('MachineAgent');

class MachineAgent {
  constructor(options = {}) {
    this.workerUrl = options.workerUrl || process.env.CCR_WORKER_URL;
    this.machineId = options.machineId || process.env.CCR_MACHINE_ID || os.hostname();
    this.onCommand = options.onCommand || (() => {});

    this.ws = null;
    this.reconnectDelay = 1000;
    this.maxReconnectDelay = 30000;
    this.pingInterval = null;
  }

  async connect() {
    if (!this.workerUrl) {
      logger.warn('CCR_WORKER_URL not set - machine agent disabled');
      return;
    }

    const wsUrl = this.workerUrl.replace(/^http/, 'ws') + `/ws?machineId=${encodeURIComponent(this.machineId)}`;

    logger.info(`Connecting to Worker: ${wsUrl}`);

    try {
      this.ws = new WebSocket(wsUrl);

      this.ws.on('open', () => {
        logger.info(`Connected to Worker as ${this.machineId}`);
        this.reconnectDelay = 1000; // Reset on successful connect
        this.startPing();
      });

      this.ws.on('message', (data) => {
        this.handleMessage(data);
      });

      this.ws.on('close', () => {
        logger.warn('WebSocket closed, reconnecting...');
        this.stopPing();
        this.scheduleReconnect();
      });

      this.ws.on('error', (err) => {
        logger.error('WebSocket error:', err.message);
      });

    } catch (err) {
      logger.error('Failed to connect:', err.message);
      this.scheduleReconnect();
    }
  }

  handleMessage(data) {
    try {
      const msg = JSON.parse(data);

      if (msg.type === 'pong') {
        return; // Ping response
      }

      if (msg.type === 'command') {
        logger.info(`Received command for session ${msg.sessionId}: ${msg.command.slice(0, 50)}`);
        this.onCommand(msg);
        return;
      }

      logger.debug('Unknown message:', msg);
    } catch (err) {
      logger.error('Error parsing message:', err.message);
    }
  }

  startPing() {
    this.pingInterval = setInterval(() => {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify({ type: 'ping' }));
      }
    }, 30000); // Every 30 seconds
  }

  stopPing() {
    if (this.pingInterval) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }
  }

  scheduleReconnect() {
    setTimeout(() => {
      this.reconnectDelay = Math.min(this.reconnectDelay * 2, this.maxReconnectDelay);
      this.connect();
    }, this.reconnectDelay);
  }

  sendResult(sessionId, success, error, chatId) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({
        type: 'commandResult',
        sessionId,
        success,
        error,
        chatId
      }));
    }
  }

  async registerSession(sessionId, label) {
    if (!this.workerUrl) return;

    try {
      const response = await fetch(`${this.workerUrl}/sessions/register`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          sessionId,
          machineId: this.machineId,
          label
        })
      });

      const result = await response.json();
      logger.info(`Session registered with Worker: ${sessionId} → ${this.machineId}`);
      return result;
    } catch (err) {
      logger.error('Failed to register session with Worker:', err.message);
    }
  }

  async unregisterSession(sessionId) {
    if (!this.workerUrl) return;

    try {
      await fetch(`${this.workerUrl}/sessions/unregister`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ sessionId })
      });
      logger.info(`Session unregistered from Worker: ${sessionId}`);
    } catch (err) {
      logger.error('Failed to unregister session:', err.message);
    }
  }

  async sendNotification(sessionId, chatId, text, replyMarkup) {
    if (!this.workerUrl) {
      throw new Error('CCR_WORKER_URL not configured');
    }

    const response = await fetch(`${this.workerUrl}/notifications/send`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        sessionId,
        chatId,
        text,
        replyMarkup
      })
    });

    return response.json();
  }

  close() {
    this.stopPing();
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
  }
}

module.exports = MachineAgent;
```

**Step 3: Commit**

```bash
git add src/worker-client/machine-agent.js
git commit -m "Add machine agent for Worker communication

- WebSocket connection with auto-reconnect
- Session registration/unregistration
- Notification send-through
- Command receiving and result reporting"
```

---

### Task 11: Add ws dependency to CCR

**Files:**
- Modify: `~/projects/claude-code-remote/package.json`

**Step 1: Install ws package**

```bash
cd ~/projects/claude-code-remote
npm install ws
```

**Step 2: Commit**

```bash
git add package.json package-lock.json
git commit -m "Add ws dependency for WebSocket client"
```

---

### Task 12: Integrate machine agent into webhook server

**Files:**
- Modify: `~/projects/claude-code-remote/start-telegram-webhook.js`

**Step 1: Read current file structure**

First, understand the current initialization in `start-telegram-webhook.js`.

**Step 2: Add machine agent initialization**

Add after the existing requires:

```javascript
const MachineAgent = require('./src/worker-client/machine-agent');
```

Add after creating the TelegramWebhookHandler:

```javascript
// Initialize machine agent for Worker communication
const machineAgent = new MachineAgent({
  onCommand: async (msg) => {
    // Route command to local session
    try {
      const result = await telegramWebhook._processCommandInternal(
        msg.chatId,
        msg.sessionId,
        msg.command
      );
      machineAgent.sendResult(msg.sessionId, result.ok, result.error, msg.chatId);
    } catch (err) {
      logger.error('Error processing Worker command:', err);
      machineAgent.sendResult(msg.sessionId, false, err.message, msg.chatId);
    }
  }
});

// Connect to Worker (if configured)
machineAgent.connect();

// Make agent available to webhook handler
telegramWebhook.setMachineAgent(machineAgent);
```

**Step 3: Commit**

```bash
git add start-telegram-webhook.js
git commit -m "Integrate machine agent into webhook server

- Initialize MachineAgent on startup
- Route Worker commands to local session processor
- Report command results back to Worker"
```

---

### Task 13: Modify webhook handler to use Worker for notifications

**Files:**
- Modify: `~/projects/claude-code-remote/src/channels/telegram/webhook.js`

**Step 1: Add machine agent setter**

Add to TelegramWebhookHandler class:

```javascript
  setMachineAgent(agent) {
    this.machineAgent = agent;
  }
```

**Step 2: Add internal command processor**

This allows the machine agent to call command processing without going through HTTP:

```javascript
  async _processCommandInternal(chatId, sessionId, command) {
    // Similar to _processCommand but takes sessionId directly
    const session = this.registry.getSession(sessionId);

    if (!session) {
      return { ok: false, error: 'Session not found' };
    }

    try {
      await this._injectToSession(session, command);
      return { ok: true };
    } catch (err) {
      this.logger.error(`Command injection failed: ${err.message}`);
      return { ok: false, error: err.message };
    }
  }
```

**Step 3: Modify _handleStopEvent to use Worker when available**

In the `_handleStopEvent` method, after generating the notification text but before sending:

```javascript
    // If machine agent is configured, send via Worker
    if (this.machineAgent && process.env.CCR_WORKER_URL) {
      try {
        const result = await this.machineAgent.sendNotification(
          session.session_id,
          this.chatId,
          text,
          replyMarkup
        );

        if (result.ok) {
          this.logger.info(`Notification sent via Worker: ${result.messageId}`);
          return;
        }
      } catch (err) {
        this.logger.warn(`Worker notification failed, falling back to direct: ${err.message}`);
      }
    }

    // Fall back to direct Telegram API (existing code)
```

**Step 4: Register sessions with Worker**

In session lifecycle methods, add Worker registration:

```javascript
  // When session notifications are enabled
  async _enableNotifications(sessionId, label) {
    // ... existing code ...

    // Register with Worker
    if (this.machineAgent) {
      await this.machineAgent.registerSession(sessionId, label);
    }
  }
```

**Step 5: Commit**

```bash
git add src/channels/telegram/webhook.js
git commit -m "Route notifications through Worker when available

- Add setMachineAgent() for injection
- Add _processCommandInternal() for Worker commands
- Send notifications via Worker for reply routing
- Register sessions with Worker on notify enable"
```

---

### Task 14: Add Worker configuration to .env

**Files:**
- Modify: `~/projects/claude-code-remote/.env.example` (if exists)
- Document in README

**Step 1: Add environment variables**

Add to `.env`:

```bash
# Cloudflare Worker for multi-machine routing (optional)
# If set, notifications route through Worker for reliable reply handling
CCR_WORKER_URL=https://ccr-router.<account>.workers.dev
CCR_MACHINE_ID=devbox  # or 'macbook', etc. - unique per machine
```

**Step 2: Commit**

```bash
git add .env.example README.md
git commit -m "Document Worker configuration

CCR_WORKER_URL - Worker endpoint for multi-machine routing
CCR_MACHINE_ID - Unique identifier for this machine"
```

---

## Phase 4: Configure Both Machines (Tasks 15-17)

### Task 15: Configure devbox

**Run on:** Devbox

**Step 1: Update .env on devbox**

```bash
cd ~/projects/claude-code-remote

# Add to .env
echo "" >> .env
echo "# Cloudflare Worker routing" >> .env
echo "CCR_WORKER_URL=https://ccr-router.<account>.workers.dev" >> .env
echo "CCR_MACHINE_ID=devbox" >> .env
```

**Step 2: Restart webhook server**

```bash
# If running via systemd
sudo systemctl restart ccr-webhooks

# Or if running manually
# Ctrl+C and restart
npm run webhooks:log
```

**Step 3: Verify connection**

Check logs for "Connected to Worker as devbox".

---

### Task 16: Configure macOS

**Run on:** macOS

**Step 1: Pull latest CCR changes**

```bash
cd ~/Code/claude-code-remote
git pull origin master
npm install  # Get ws dependency
```

**Step 2: Update .env on macOS**

```bash
# Add to .env
echo "" >> .env
echo "# Cloudflare Worker routing" >> .env
echo "CCR_WORKER_URL=https://ccr-router.<account>.workers.dev" >> .env
echo "CCR_MACHINE_ID=macbook" >> .env
```

**Step 3: Restart webhook server**

```bash
npm run webhooks:log
```

**Step 4: Verify connection**

Check logs for "Connected to Worker as macbook".

---

### Task 17: Test end-to-end flow

**Run on:** Either machine

**Step 1: Start a Claude session on devbox**

```bash
ssh devbox
claude
# In Claude, run /notify-telegram
```

**Step 2: Complete a task to trigger notification**

Let Claude complete something. You should receive a Telegram notification.

**Step 3: Reply to the notification**

Reply to the notification with a command like "continue" or "y".

**Step 4: Verify command was received**

Check devbox webhook logs - should show command received from Worker.

**Step 5: Repeat from macOS**

Start a session on macOS, trigger notification, reply - verify it reaches macOS.

**Step 6: Test cross-machine (the key test)**

1. Have sessions on BOTH machines with notifications enabled
2. Reply to a devbox notification
3. Verify it goes to devbox (not macOS)
4. Reply to a macOS notification
5. Verify it goes to macOS (not devbox)

---

## Phase 5: Cleanup Old Architecture (Tasks 18-19)

**Run on:** Devbox

### Task 18: Remove direct Telegram webhook from machines

Once Worker routing is confirmed working, the local webhook servers no longer need to receive Telegram webhooks directly (they only receive commands via WebSocket).

**Step 1: Update local webhook to not register with Telegram**

In `start-telegram-webhook.js`, skip webhook registration when Worker is configured:

```javascript
// Only register webhook directly if NOT using Worker
if (!process.env.CCR_WORKER_URL) {
  await telegramWebhook.registerWebhook();
}
```

**Step 2: Commit**

```bash
git add start-telegram-webhook.js
git commit -m "Skip direct webhook registration when using Worker

When CCR_WORKER_URL is set, Worker handles all incoming webhooks.
Local server only needs to handle WebSocket commands."
```

---

### Task 19: Optional - Remove Cloudflare Tunnel from CCR path

Since webhooks no longer need to reach machines directly, you can simplify:

**Option A: Keep tunnel for other uses**
- Tunnel remains for SSH, other services
- CCR doesn't use it for webhooks

**Option B: Remove CCR from tunnel routing**
- Update Cloudflare dashboard to remove `ccr.mohrbacher.dev` route
- Keep tunnel for SSH only

This is optional and depends on whether you have other uses for the tunnel hostname.

---

## Summary

| Phase | Tasks | Run On | Description |
|-------|-------|--------|-------------|
| 1 | 1-6 | Devbox | Create Cloudflare Worker + DO |
| 2 | 7-9 | Devbox | Deploy Worker, set secrets, update Telegram webhook |
| 3 | 10-14 | Devbox | Add machine agent to CCR |
| 4 | 15-17 | Both | Configure and test both machines |
| 5 | 18-19 | Devbox | Cleanup old architecture |

**Key files created/modified:**

Worker (`~/projects/ccr-worker/`):
- `wrangler.toml` - Worker configuration
- `src/index.js` - Entry point
- `src/router-do.js` - Durable Object with all logic

CCR (`~/projects/claude-code-remote/`):
- `src/worker-client/machine-agent.js` - WebSocket client
- `start-telegram-webhook.js` - Integration
- `src/channels/telegram/webhook.js` - Use Worker for notifications
- `.env` - Add CCR_WORKER_URL and CCR_MACHINE_ID
