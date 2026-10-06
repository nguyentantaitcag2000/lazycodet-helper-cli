#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  rmdirSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HOME = process.env.HOME || os.homedir();
const INSTALL_DIR = path.join(HOME, '.local', 'share', 'lazy', 'agent-notify');
const INSTALLED_SCRIPT = path.join(INSTALL_DIR, 'agent-notify.mjs');
const STATE_FILE = path.join(INSTALL_DIR, 'state.json');
const SOURCE_SCRIPT = fileURLToPath(import.meta.url);
const POWERSHELL = process.env.LAZY_AGENT_NOTIFY_POWERSHELL || 'powershell.exe';

const targets = [
  {
    id: 'claude',
    label: 'Claude Code',
    configPath: path.join(HOME, '.claude', 'settings.json'),
  },
  {
    id: 'codex',
    label: 'Codex',
    configPath: path.join(HOME, '.codex', 'hooks.json'),
  },
];

function usage() {
  console.log(`Usage:
  lazy agent.notify
  lazy agent.notify --check
  lazy agent.notify --test
  lazy agent.notify --uninstall

Install a global Stop hook for Claude Code and Codex. The hook uses Windows'
built-in English text-to-speech voice and does not call an AI model or API.

Options:
  --check      Verify the runtime, both global hooks, and Windows TTS
  --test       Speak a short test sentence without changing configuration
  --uninstall  Remove only the hooks and runtime managed by this command
  -h, --help   Show this help`);
}

function fail(message) {
  console.error(`Error: ${message}`);
  process.exitCode = 1;
}

function readJson(filePath, { optional = false } = {}) {
  if (!existsSync(filePath)) {
    if (optional) return null;
    throw new Error(`File not found: ${filePath}`);
  }

  let value;
  try {
    value = JSON.parse(readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`Cannot parse JSON in ${filePath}: ${error.message}`);
  }

  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`Expected a JSON object in ${filePath}`);
  }

  return value;
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function atomicWrite(filePath, content, mode = 0o600) {
  const directory = path.dirname(filePath);
  mkdirSync(directory, { recursive: true });
  const tempPath = path.join(directory, `.${path.basename(filePath)}.tmp-${process.pid}`);

  try {
    writeFileSync(tempPath, content, { mode });
    renameSync(tempPath, filePath);
    chmodSync(filePath, mode);
  } finally {
    rmSync(tempPath, { force: true });
  }
}

function jsonMode(filePath) {
  return existsSync(filePath) ? statSync(filePath).mode & 0o777 : 0o600;
}

function writeJson(filePath, value) {
  atomicWrite(filePath, `${JSON.stringify(value, null, 2)}\n`, jsonMode(filePath));
}

function commandFor(provider) {
  return `node "$HOME/.local/share/lazy/agent-notify/agent-notify.mjs" --hook ${provider}`;
}

function isManagedHandler(handler, provider) {
  if (!handler || typeof handler !== 'object' || handler.type !== 'command') return false;
  if (typeof handler.command !== 'string') return false;

  return handler.command === commandFor(provider);
}

function removeManagedHook(config, provider) {
  const result = clone(config);
  const groups = result.hooks?.Stop;
  let removed = 0;

  if (!Array.isArray(groups)) return { config: result, removed };

  result.hooks.Stop = groups.flatMap((group) => {
    if (!group || typeof group !== 'object' || !Array.isArray(group.hooks)) return [group];
    const handlers = group.hooks.filter((handler) => {
      if (!isManagedHandler(handler, provider)) return true;
      removed += 1;
      return false;
    });
    return handlers.length > 0 ? [{ ...group, hooks: handlers }] : [];
  });

  if (result.hooks.Stop.length === 0) delete result.hooks.Stop;
  if (Object.keys(result.hooks).length === 0) delete result.hooks;

  return { config: result, removed };
}

function addManagedHook(config, provider) {
  const { config: result } = removeManagedHook(config, provider);
  result.hooks ??= {};
  result.hooks.Stop ??= [];
  result.hooks.Stop.push({
    hooks: [
      {
        type: 'command',
        command: commandFor(provider),
        async: true,
        timeout: 20,
      },
    ],
  });
  return result;
}

function countManagedHooks(config, provider) {
  const groups = config?.hooks?.Stop;
  if (!Array.isArray(groups)) return 0;
  return groups.reduce((count, group) => {
    if (!Array.isArray(group?.hooks)) return count;
    return count + group.hooks.filter((handler) => isManagedHandler(handler, provider)).length;
  }, 0);
}

function encodePowerShell(script) {
  return Buffer.from(script, 'utf16le').toString('base64');
}

function runPowerShell(script, { capture = false, timeout = 15_000 } = {}) {
  return spawnSync(
    POWERSHELL,
    ['-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', encodePowerShell(script)],
    {
      encoding: capture ? 'utf8' : undefined,
      stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'ignore',
      timeout,
      windowsHide: true,
    },
  );
}

function probeSpeech() {
  const script = String.raw`
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
  $synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name }
} finally {
  $synth.Dispose()
}`;
  const result = runPowerShell(script, { capture: true, timeout: 10_000 });

  if (result.error) throw new Error(`Cannot start powershell.exe: ${result.error.message}`);
  if (result.status !== 0) {
    const detail = String(result.stderr || '').trim();
    throw new Error(`Windows text-to-speech probe failed${detail ? `: ${detail}` : ''}`);
  }

  const voices = String(result.stdout || '')
    .split(/\r?\n/)
    .map((voice) => voice.trim())
    .filter(Boolean);
  if (voices.length === 0) throw new Error('Windows did not report an installed text-to-speech voice');

  const preferred = ['Microsoft Zira Desktop', 'Microsoft Hazel Desktop'];
  return preferred.find((voice) => voices.includes(voice)) || voices[0];
}

function powerShellLiteral(value) {
  return `'${value.replaceAll("'", "''")}'`;
}

function speak(text) {
  const script = String.raw`
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
  $voices = $synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name }
  foreach ($candidate in @('Microsoft Zira Desktop', 'Microsoft Hazel Desktop')) {
    if ($voices -contains $candidate) {
      $synth.SelectVoice($candidate)
      break
    }
  }
  $synth.Rate = 0
  $synth.Volume = 100
  $synth.Speak(${powerShellLiteral(text)})
} finally {
  $synth.Dispose()
}`;
  const result = runPowerShell(script, { timeout: 20_000 });
  return !result.error && result.status === 0;
}

function cleanSummary(message) {
  if (typeof message !== 'string') return '';

  const cleaned = message
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/`([^`]+)`/g, '$1')
    .split(/\r?\n/)
    .map((line) => line.replace(/^\s{0,3}(?:#{1,6}|[-*+]\s+|\d+[.)]\s+)/, '').trim())
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();

  if (!cleaned) return '';
  const sentence = cleaned.match(/^.{1,180}?[.!?](?:\s|$)/u)?.[0] || cleaned.slice(0, 180);
  return sentence.trim();
}

function spokenMessage(payload, provider) {
  const label = provider === 'claude' ? 'Claude' : 'Codex';
  const fallback = `${label} has finished the task.`;
  const summary = cleanSummary(payload?.last_assistant_message);

  // The built-in voices on the target machines are English. Reading Vietnamese
  // with them is much less useful than a short, accurate English fallback.
  if (!summary || /[^\x00-\x7F]/u.test(summary)) return fallback;
  return `${label} has finished. ${summary}`;
}

async function readStdin() {
  let input = '';
  process.stdin.setEncoding('utf8');
  for await (const chunk of process.stdin) input += chunk;
  return input;
}

async function runHook(provider) {
  let payload = {};
  try {
    const input = await readStdin();
    if (input.trim()) payload = JSON.parse(input);

    // Claude can stop temporarily while a background task is still running.
    // Announcing at that point would claim completion too early.
    if (!Array.isArray(payload.background_tasks) || payload.background_tasks.length === 0) {
      speak(spokenMessage(payload, provider));
    }
  } catch {
    // Notifications are best effort. They must never change or block the agent's
    // completed response, including when a future hook payload adds new fields.
  }

  // Codex Stop hooks require JSON on stdout when they exit successfully.
  process.stdout.write('{}');
}

function captureOriginal(filePath) {
  if (!existsSync(filePath)) return { exists: false, content: null, mode: 0o600 };
  return {
    exists: true,
    content: readFileSync(filePath),
    mode: statSync(filePath).mode & 0o777,
  };
}

function restoreOriginal(filePath, original) {
  if (!original.exists) {
    rmSync(filePath, { force: true });
    return;
  }
  atomicWrite(filePath, original.content, original.mode);
}

function install() {
  const voice = probeSpeech();
  const existingState = readJson(STATE_FILE, { optional: true }) || {};
  const originals = new Map();
  const planned = new Map();

  for (const target of targets) {
    const original = captureOriginal(target.configPath);
    originals.set(target.configPath, original);
    const config = original.exists ? readJson(target.configPath) : {};
    planned.set(target.configPath, addManagedHook(config, target.id));
  }

  const state = {
    version: 1,
    createdConfigs: {},
  };
  for (const target of targets) {
    const wasCreated = existingState.createdConfigs?.[target.id] === true;
    state.createdConfigs[target.id] = wasCreated || !originals.get(target.configPath).exists;
  }

  try {
    mkdirSync(INSTALL_DIR, { recursive: true });
    atomicWrite(INSTALLED_SCRIPT, readFileSync(SOURCE_SCRIPT), 0o755);
    for (const target of targets) writeJson(target.configPath, planned.get(target.configPath));
    writeJson(STATE_FILE, state);
  } catch (error) {
    for (const target of targets) {
      try {
        restoreOriginal(target.configPath, originals.get(target.configPath));
      } catch {
        // Preserve the original installation error; the recovery failure will be
        // visible from the affected config path in the message below.
      }
    }
    throw error;
  }

  console.log('Installed global completion announcements:');
  for (const target of targets) console.log(`  ${target.label}: ${target.configPath}`);
  console.log(`  Runtime:     ${INSTALLED_SCRIPT}`);
  console.log(`  Voice:       ${voice}`);
  console.log('');
  console.log('Codex: run /hooks once and trust the new global hook.');
  console.log("Run 'lazy agent.notify --test' to hear a test sentence.");
}

function check() {
  let healthy = true;

  if (existsSync(INSTALLED_SCRIPT)) {
    console.log(`ok   Runtime: ${INSTALLED_SCRIPT}`);
  } else {
    console.log(`miss Runtime: ${INSTALLED_SCRIPT}`);
    healthy = false;
  }

  for (const target of targets) {
    let count = 0;
    try {
      const config = readJson(target.configPath, { optional: true });
      count = countManagedHooks(config, target.id);
    } catch (error) {
      console.log(`bad  ${target.label}: ${error.message}`);
      healthy = false;
      continue;
    }

    if (count === 1) {
      console.log(`ok   ${target.label}: ${target.configPath}`);
    } else {
      console.log(`miss ${target.label}: expected one managed Stop hook, found ${count}`);
      healthy = false;
    }
  }

  try {
    console.log(`ok   Windows TTS: ${probeSpeech()}`);
  } catch (error) {
    console.log(`bad  Windows TTS: ${error.message}`);
    healthy = false;
  }

  if (!healthy) process.exitCode = 1;
}

function uninstall() {
  const state = readJson(STATE_FILE, { optional: true }) || {};
  const changes = [];

  // Parse every existing config before changing any of them. A malformed file
  // must not leave one provider uninstalled and the other still active.
  for (const target of targets) {
    if (!existsSync(target.configPath)) continue;
    const current = readJson(target.configPath);
    const { config, removed } = removeManagedHook(current, target.id);
    changes.push({ target, config, removed });
  }

  for (const change of changes) {
    if (change.removed === 0) continue;
    const createdByUs = state.createdConfigs?.[change.target.id] === true;
    if (createdByUs && Object.keys(change.config).length === 0) {
      rmSync(change.target.configPath, { force: true });
    } else {
      writeJson(change.target.configPath, change.config);
    }
  }

  rmSync(INSTALLED_SCRIPT, { force: true });
  rmSync(STATE_FILE, { force: true });
  try {
    rmdirSync(INSTALL_DIR);
  } catch {
    // Leave the directory alone if the user placed another file in it.
  }

  console.log('Removed the managed Claude Code and Codex completion hooks.');
  console.log('Unrelated settings and hooks were preserved.');
}

function testSpeech() {
  const voice = probeSpeech();
  if (!speak('Lazy agent notifications are working.')) {
    throw new Error('Windows text-to-speech could not play the test sentence');
  }
  console.log(`Spoke the test sentence with Windows TTS (${voice}).`);
}

async function main() {
  const [command, extra, ...rest] = process.argv.slice(2);
  if (rest.length > 0 || (extra !== undefined && command !== '--hook')) {
    usage();
    fail(`Unexpected argument: ${rest[0] || extra}`);
    return;
  }

  try {
    switch (command) {
      case '--hook': {
        const provider = extra;
        if (!['claude', 'codex'].includes(provider)) {
          process.stdout.write('{}');
          return;
        }
        await runHook(provider);
        return;
      }
      case undefined:
        install();
        return;
      case '--check':
        check();
        return;
      case '--test':
        testSpeech();
        return;
      case '--uninstall':
        uninstall();
        return;
      case '-h':
      case '--help':
        usage();
        return;
      default:
        usage();
        fail(`Unknown option: ${command}`);
    }
  } catch (error) {
    fail(error.message);
  }
}

await main();
