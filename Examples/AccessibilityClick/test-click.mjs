import assert from 'node:assert/strict';
import { execFile, spawn } from 'node:child_process';
import { once } from 'node:events';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execute = promisify(execFile);
const binary = process.env.ALFALFA_DESKTOP ?? join(homedir(), '.local', 'bin', 'alfalfa-desktop');
const runner = process.argv[2] ?? 'terminal';

async function desktop(...args) {
    const { stdout } = await execute(binary, args, { timeout: 10_000 });
    return JSON.parse(stdout);
}

const permissions = await desktop('permissions');
assert.equal(permissions.accessibility, true, 'Accessibility permission is required in the host running the CLI.');
const scratch = mkdtempSync(join(tmpdir(), 'alfalfa-accessibility-click-'));
let demo;

try {
    const contents = join(scratch, 'Alfalfa Click Test.app', 'Contents');
    mkdirSync(join(contents, 'MacOS'), { recursive: true });
    copyFileSync(new URL('./Info.plist', import.meta.url), join(contents, 'Info.plist'));
    const executable = join(contents, 'MacOS', 'Demo');
    const source = fileURLToPath(new URL('./Demo.swift', import.meta.url));
    await execute('swiftc', ['-module-cache-path', join(scratch, 'cache'), source, '-o', executable], { timeout: 120_000 });

    demo = spawn(executable, [], { stdio: 'ignore' });
    await once(demo, 'spawn');
    const target = [`--pid=${demo.pid}`, '--window=0', '--approve'];
    let before;

    for (let attempt = 0; attempt < 30; attempt++) {
        before = await desktop('inspect', ...target).catch(() => null);
        if (before?.title) break;
        await delay(150);
    }

    assert.equal(before?.title, 'Prueba de AlfalfaDesktop — Botón');
    assert.match(before.tree, /Pendiente/);
    const button = before.elements.find(({ title, role }) => title === 'Verificar control' && role === 'AXButton');
    assert(button, 'Expected the button inside the temporary fixture.');
    const click = await desktop('action', ...target, '--kind=click', `--path=${button.path}`, `--role=${button.role}`);
    assert.equal(click.performed, true);
    assert.equal(click.method, 'AXPress');

    const after = await desktop('inspect', ...target);
    assert.equal(after.title, before.title);
    assert.match(after.tree, /Control confirmado/);
    console.log(JSON.stringify({
        runner,
        test: 'desktop',
        permissions,
        captureRequested: false,
        before: 'Pendiente',
        method: click.method,
        after: 'Control confirmado',
    }, null, 2));
} finally {
    if (demo?.pid && demo.exitCode === null && demo.signalCode === null) {
        const finished = once(demo, 'exit');
        demo.kill('SIGTERM');
        await finished;
    }
    rmSync(scratch, { recursive: true, force: true });
}
