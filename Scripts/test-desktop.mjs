import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { appendFileSync, readFileSync, rmSync } from 'node:fs';
import { dirname } from 'node:path';
import { createInterface } from 'node:readline';

const [binary, pid, fixtureLog, ...flags] = process.argv.slice(2);
assert(binary && /^\d+$/.test(pid ?? ''), 'Expected a binary path and a real fixture PID.');

const listOnly = flags.includes('--list-only');
const requireCapture = flags.includes('--capture');
const stdout = (...args) => JSON.parse(execFileSync(binary, args, { encoding: 'utf8', timeout: 20_000 }));
const permissions = stdout('permissions');
const fixture = stdout('list').apps.find(app => String(app.pid) === pid);
assert(fixture, 'CLI did not list the real fixture.');
const child = spawn(binary, ['pacai'], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
const session = randomUUID();
const transcript = process.env.PACAI_TRANSCRIPT;
let clientSequence = 0;
let agentSequence = 0;
const watchdog = setTimeout(() => {
    child.kill('SIGKILL');
    throw new Error('PACAI did not finish within 30 seconds.');
}, 30_000);

function send(type, payload, replyTo) {
    const id = randomUUID();
    const envelope = {
        pacai: '0.3', id, type, session, sender: 'client', seq: ++clientSequence,
        time: new Date().toISOString(), payload
    };
    if (replyTo) envelope.reply_to = replyTo;
    const line = JSON.stringify(envelope) + '\n';
    if (transcript) appendFileSync(transcript, line);
    child.stdin.write(line);
    return id;
}

async function next(type) {
    const item = await lines.next();
    assert(!item.done, `Expected ${type}, found EOF`);
    const message = JSON.parse(item.value);
    if (transcript) appendFileSync(transcript, item.value + '\n');
    assert.equal(message.type, type, JSON.stringify(message));
    assert.equal(message.sender, 'agent');
    assert.equal(message.session, session);
    assert.equal(message.seq, ++agentSequence);
    return message;
}

async function command(name, options, decision = 'approved') {
    const input = send('input', {
        mode: 'new_run',
        blocks: [{ type: 'structured', schema: 'urn:alfalfadesktop:command:v1', data: { command: name, options } }]
    });
    const run = await next('run_started');
    assert.equal(run.payload.input_id, input);
    const tool = await next('tool_start');
    if (name !== 'list') {
        const approval = await next('approval_request');
        assert.equal(approval.payload.tool_call_id, tool.id);
        const args = approval.payload.arguments;
        const canonical = JSON.stringify(Object.fromEntries(Object.keys(args).sort().map(key => [key, args[key]])));
        assert.equal(approval.payload.digest, 'sha256:' + createHash('sha256').update(canonical).digest('hex'));
        if (decision === 'cancelled') {
            send('interrupt', { run_id: run.id });
            const cancelled = await next('approval_result');
            assert.equal(cancelled.reply_to, approval.id);
            assert.equal(cancelled.payload.decision, 'cancelled');
        } else {
            send('approval_result', decision === 'approved' ? { decision, scope: 'once' } : { decision }, approval.id);
        }
    }
    const toolEnd = await next('tool_end');
    assert.equal(toolEnd.payload.tool_call_id, tool.id);
    const finish = await next('run_finished');
    assert.equal(finish.payload.run_id, run.id);
    const outcome = { approved: 'success', denied: 'blocked', cancelled: 'interrupted' }[decision];
    assert.equal(finish.payload.outcome, outcome);
    return toolEnd.payload.output?.[0].data;
}

function captureDigest(observation) {
    assert(observation.capture, observation.captureError ?? 'Expected an actual window capture.');
    const content = readFileSync(observation.capture);
    assert.equal(content.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
    rmSync(dirname(observation.capture), { recursive: true });
    return createHash('sha256').update(content).digest('hex');
}

try {
    const hello = send('hello', { versions: ['0.3'] });
    await next('hello');
    assert.equal((await next('session_started')).reply_to, hello);
    const pacaiList = await command('list', {});
    assert(pacaiList.apps.some(app => String(app.pid) === pid), 'PACAI did not list the same real fixture.');
    console.log(JSON.stringify({ result: 'real fixture listed over CLI and PACAI', pid, permissions }));
    if (listOnly) {
        await command('permissions', { request: 'true' }, 'denied');
        await command('permissions', { request: 'true' }, 'cancelled');
        console.log(JSON.stringify({ result: 'PACAI denial and interruption tested without requesting OS permissions' }));
    } else {
        const lineCount = readFileSync(fixtureLog, 'utf8').trimEnd().split('\n').length;
        const target = { pid, window: '0' };
        const first = stdout('inspect', `--pid=${pid}`, '--approve', ...(requireCapture ? ['--capture'] : []));
        assert(first.tree.includes('Count: 0'));
        const initialCapture = requireCapture ? captureDigest(first) : null;
        const button = first.elements.find(item => item.title === 'Increment');
        assert(button);
        const action = { ...target, kind: 'click', path: button.path, role: button.role };
        stdout('action', `--pid=${pid}`, '--kind=click', `--path=${button.path}`, `--role=${button.role}`, '--approve');
        const afterCLI = await command('inspect', target);
        assert(afterCLI.tree.includes('Count: 1'));
        await command('action', action, 'denied');
        await command('action', action, 'cancelled');
        assert((await command('inspect', target)).tree.includes('Count: 1'));
        await command('action', action);
        const last = await command('inspect', { ...target, ...(requireCapture ? { capture: 'true' } : {}) });
        assert(last.tree.includes('Count: 2'));
        if (requireCapture) assert.notEqual(captureDigest(last), initialCapture);
        const records = readFileSync(fixtureLog, 'utf8').trim().split('\n').slice(lineCount).map(line => JSON.parse(line));
        const clicks = records.filter(record => record.event === 'click');
        assert.deepEqual(clicks.map(click => click.count), [1, 2]);
        assert(clicks.every(click => click.before === click.after && click.before !== Number(pid) && click.before > 0));
        assert(!records.some(record => record.event === 'activation' && record.pid === Number(pid)));
        console.log(JSON.stringify({ result: 'real clicks retained foreground focus', clicks, capturesChanged: requireCapture }));
    }
    send('close', {});
} finally {
    clearTimeout(watchdog);
    child.stdin.end();
}
