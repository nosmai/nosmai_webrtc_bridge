// Local signalling fixture: one publisher (phone) + one viewer (browser) per room.
// Relays offer/answer/candidate verbatim. NOT a production signalling service (no auth/TLS).
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { WebSocketServer } = require('ws');

const PORT = process.env.PORT || 8080;
const rooms = new Map(); // room -> { publisher, viewer }

const server = http.createServer((req, res) => {
  const url = req.url === '/' ? '/viewer.html' : req.url.split('?')[0];
  const file = path.join(__dirname, 'public', path.normalize(url).replace(/^(\.\.[/\\])+/, ''));
  if (!file.startsWith(path.join(__dirname, 'public'))) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); return res.end('not found'); }
    res.writeHead(200, { 'Content-Type': file.endsWith('.html') ? 'text/html' : 'text/plain' });
    res.end(data);
  });
});

const wss = new WebSocketServer({ server });
const log = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a);
const send = (ws, obj) => { if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj)); };

wss.on('connection', (ws) => {
  let room = null, role = null;
  ws.on('message', (raw) => {
    let msg; try { msg = JSON.parse(raw); } catch { return; }
    if (msg.type === 'join') {
      room = msg.room || 'qa'; role = msg.role;
      const r = rooms.get(room) || {}; rooms.set(room, r);
      if (role === 'publisher') {
        if (r.publisher && r.publisher !== ws) r.publisher.close();
        r.publisher = ws;
        log(`[${room}] publisher joined`);
        if (r.viewer) send(ws, { type: 'viewer-joined' });
      } else {
        if (r.viewer && r.viewer !== ws) { r.viewer.close(); send(r.publisher, { type: 'viewer-left' }); }
        r.viewer = ws;
        log(`[${room}] viewer joined`);
        send(ws, { type: 'publisher-present', present: !!r.publisher });
        if (r.publisher) send(r.publisher, { type: 'viewer-joined' });
      }
      return;
    }
    const r = rooms.get(room); if (!r) return;
    const peer = role === 'publisher' ? r.viewer : r.publisher;
    if (['offer', 'answer', 'candidate', 'viewer-stats'].includes(msg.type)) {
      if (msg.type !== 'viewer-stats') log(`[${room}] ${role} -> ${msg.type}`);
      send(peer, msg);
    }
  });
  ws.on('close', () => {
    const r = rooms.get(room); if (!r) return;
    if (role === 'publisher' && r.publisher === ws) { r.publisher = null; send(r.viewer, { type: 'publisher-left' }); log(`[${room}] publisher left`); }
    if (role === 'viewer' && r.viewer === ws) { r.viewer = null; send(r.publisher, { type: 'viewer-left' }); log(`[${room}] viewer left`); }
    if (!r.publisher && !r.viewer) rooms.delete(room);
  });
});

server.listen(PORT, '0.0.0.0', () => {
  const ips = Object.values(os.networkInterfaces()).flat().filter(i => i.family === 'IPv4' && !i.internal).map(i => i.address);
  console.log(`Signalling + viewer on port ${PORT}`);
  console.log(`  Viewer (open on THIS Mac):  http://localhost:${PORT}/viewer.html?room=qa`);
  ips.forEach(ip => console.log(`  Phone signalling URL:       ws://${ip}:${PORT}`));
});
