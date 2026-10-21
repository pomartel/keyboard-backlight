const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { EventEmitter } = require('node:events');
const { execFileSync, spawn } = require('node:child_process');

const uint = value => { const b = Buffer.alloc(4); b.writeUInt32LE(value); return b; };
function string(value) {
  const text = Buffer.from(`${value}\0`);
  return Buffer.concat([uint(text.length), text, Buffer.alloc((4 - text.length % 4) % 4)]);
}
function message(object, opcode, ...parts) {
  const payload = Buffer.concat(parts);
  return Buffer.concat([uint(object), uint((payload.length + 8) * 65536 + opcode), payload]);
}

test('native watcher survives both output removal orders and watches a newly added output', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'backlight-hotplug-'));
  const binary = path.join(dir, 'watch');
  execFileSync('cc', ['-std=c11', '-D_GNU_SOURCE', '-Wall', '-Wextra', '-Werror',
    path.resolve(__dirname, '../src/watch-session.c'), '-lwayland-client', '-lsystemd', '-o', binary]);
  const server = net.createServer();
  const socketPath = path.join(dir, 'wayland-test');
  await new Promise(resolve => server.listen(socketPath, resolve));
  const updates = new EventEmitter();
  const powers = new Map();
  const outputs = new Map();
  let connection, buffer = Buffer.alloc(0), registry, manager, syncs = 0, output = '', errors = '';
  server.on('connection', socket => {
    connection = socket;
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 8) {
        const object = buffer.readUInt32LE(0), header = buffer.readUInt32LE(4);
        const size = header >>> 16, opcode = header & 65535;
        if (buffer.length < size) break;
        const payload = buffer.subarray(8, size);
        buffer = buffer.subarray(size);
        if (object === 1 && opcode === 1) {
          registry = payload.readUInt32LE(0);
          socket.write(Buffer.concat([
            message(registry, 0, uint(1), string('zwlr_output_power_manager_v1'), uint(1)),
            message(registry, 0, uint(2), string('wl_output'), uint(1)),
            message(registry, 0, uint(3), string('wl_output'), uint(1)),
          ]));
        } else if (object === 1 && opcode === 0) {
          const callback = payload.readUInt32LE(0);
          socket.write(Buffer.concat([message(callback, 0, uint(1)), message(1, 1, uint(callback))]));
          syncs++;
        } else if (object === registry && opcode === 0) {
          const name = payload.readUInt32LE(0), id = payload.readUInt32LE(payload.length - 4);
          if (name === 1) manager = id;
          else outputs.set(id, name);
        } else if (object === manager && opcode === 0) {
          const power = payload.readUInt32LE(0), wlOutput = payload.readUInt32LE(4);
          powers.set(outputs.get(wlOutput), power);
          socket.write(message(power, 0, uint(1)));
        }
        updates.emit('update');
      }
    });
  });
  const child = spawn(binary, [''], { env: { ...process.env, WAYLAND_DISPLAY: socketPath } });
  child.stdout.on('data', chunk => { output += chunk; updates.emit('update'); });
  child.stderr.on('data', chunk => { errors += chunk; });
  child.on('exit', () => updates.emit('update'));
  const count = value => output.split('\n').filter(line => line === value).length;
  const until = predicate => new Promise((resolve, reject) => {
    const done = error => {
      clearTimeout(timer); updates.removeListener('update', check);
      if (error) reject(error); else resolve();
    };
    const check = () => {
      if (predicate()) done();
      else if (child.exitCode !== null) done(new Error(`watcher exited ${child.exitCode}: ${errors}`));
    };
    const timer = setTimeout(() => done(new Error(`timeout: ${output}; ${errors}`)), 3000);
    updates.on('update', check); check();
  });
  try {
    await until(() => syncs >= 2 && powers.size === 2 && count('clock') > 0);
    // Normal unplug: failed can arrive before registry.global_remove.
    connection.write(message(powers.get(2), 1));
    await until(() => count('outputs-blocked') === 1);
    assert.equal(child.exitCode, null);
    connection.write(message(registry, 1, uint(2)));
    await until(() => count('outputs-ready') === 1);
    const changes = count('change');
    connection.write(message(powers.get(3), 0, uint(0)));
    await until(() => count('change') > changes);
    // The opposite order must safely discard a late event for the dead proxy.
    connection.write(Buffer.concat([message(registry, 1, uint(3)), message(powers.get(3), 1)]));
    await until(() => count('outputs-ready') === 2);
    assert.equal(child.exitCode, null);
    connection.write(message(registry, 0, uint(4), string('wl_output'), uint(1)));
    await until(() => powers.has(4));
    const before = count('change');
    connection.write(message(powers.get(4), 0, uint(0)));
    await until(() => count('change') > before);
    assert.equal(child.exitCode, null);
    assert.equal(errors, '');
    // A genuine manager loss still closes the entire subscription safely.
    connection.write(message(registry, 1, uint(1)));
    await until(() => child.exitCode !== null);
    assert.equal(child.exitCode, 1);
  } finally {
    if (child.exitCode === null) {
      child.kill();
      await new Promise(resolve => child.once('exit', resolve));
    }
    if (connection) connection.destroy();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
