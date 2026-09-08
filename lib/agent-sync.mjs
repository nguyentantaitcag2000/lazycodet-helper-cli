#!/usr/bin/env node

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  lstat,
  mkdir,
  readFile,
  readdir,
  readlink,
  realpath,
  rename,
  rm,
  stat,
  symlink,
  unlink,
} from "node:fs/promises";
import path from "node:path";

function printUsage() {
  console.log(`Usage:
  lazy agent.sync [project] [--check]

Create portable relative symlinks from Codex agent files to their Claude sources.

Arguments:
  project   Git repository or a directory inside it (default: current directory)

Options:
  --check   Verify the links without changing anything
  -h, --help
            Show this help`);
}

function parseArguments(argv) {
  let check = false;
  let project;
  let positionalOnly = false;

  for (const argument of argv) {
    if (!positionalOnly && argument === "--") {
      positionalOnly = true;
    } else if (!positionalOnly && argument === "--check") {
      check = true;
    } else if (!positionalOnly && new Set(["-h", "--help"]).has(argument)) {
      printUsage();
      process.exit(0);
    } else if (!positionalOnly && argument.startsWith("-")) {
      console.error(`Error: Unknown option -> ${argument}\n`);
      printUsage();
      process.exit(2);
    } else if (project === undefined) {
      project = argument;
    } else {
      console.error(`Error: agent.sync accepts at most one project path -> ${argument}\n`);
      printUsage();
      process.exit(2);
    }
  }

  return { check, project: project ?? process.cwd() };
}

const options = parseArguments(process.argv.slice(2));
let repoRoot;
let sourceInstructions;
let codexInstructions;
let sourceSkills;
let codexSkills;

function fail(message, cause) {
  const detail = cause instanceof Error ? `\n${cause.message}` : "";
  throw new Error(`[agent.sync] ${message}${detail}`);
}

function portablePath(value) {
  return value.replaceAll("\\", "/");
}

function comparablePath(value) {
  const normalized = path.normalize(value);
  return process.platform === "win32" ? normalized.toLowerCase() : normalized;
}

async function pathState(candidate) {
  try {
    return await lstat(candidate);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

async function resolveRepository(candidate) {
  const absoluteCandidate = path.resolve(candidate);
  const state = await pathState(absoluteCandidate);
  if (!state?.isDirectory()) {
    fail(`Project directory does not exist: ${absoluteCandidate}`);
  }

  try {
    const root = execFileSync("git", ["rev-parse", "--show-toplevel"], {
      cwd: absoluteCandidate,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    return path.resolve(root);
  } catch (error) {
    fail(`Not inside a Git repository: ${absoluteCandidate}`, error);
  }
}

function initializePaths(root) {
  repoRoot = root;
  sourceInstructions = path.join(repoRoot, "CLAUDE.md");
  codexInstructions = path.join(repoRoot, "AGENTS.md");
  sourceSkills = path.join(repoRoot, ".claude", "skills");
  codexSkills = path.join(repoRoot, ".agents", "skills");
}

function assertManagedPath(candidate) {
  const relative = path.relative(repoRoot, candidate);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    fail(`Refusing to modify a path outside the repository: ${candidate}`);
  }
}

async function resolvesTo(linkPath, targetPath) {
  try {
    const [resolvedLink, resolvedTarget] = await Promise.all([
      realpath(linkPath),
      realpath(targetPath),
    ]);
    return comparablePath(resolvedLink) === comparablePath(resolvedTarget);
  } catch {
    return false;
  }
}

function relativeTarget(linkPath, targetPath) {
  return portablePath(path.relative(path.dirname(linkPath), targetPath));
}

async function snapshotTree(root, relative = "") {
  const current = path.join(root, relative);
  const entries = await readdir(current, { withFileTypes: true });
  entries.sort((left, right) => left.name.localeCompare(right.name));

  const snapshot = [];
  for (const entry of entries) {
    const entryRelative = path.join(relative, entry.name);
    const entryPath = path.join(root, entryRelative);
    const portableRelative = portablePath(entryRelative);

    if (entry.isSymbolicLink()) {
      snapshot.push(`L ${portableRelative} ${portablePath(await readlink(entryPath))}`);
    } else if (entry.isDirectory()) {
      snapshot.push(`D ${portableRelative}`);
      snapshot.push(...(await snapshotTree(root, entryRelative)));
    } else if (entry.isFile()) {
      const contents = await readFile(entryPath);
      const hash = createHash("sha256").update(contents).digest("hex");
      snapshot.push(`F ${portableRelative} ${hash}`);
    } else {
      snapshot.push(`O ${portableRelative}`);
    }
  }

  return snapshot;
}

async function directoriesMatch(left, right) {
  const [leftSnapshot, rightSnapshot] = await Promise.all([
    snapshotTree(left),
    snapshotTree(right),
  ]);
  return JSON.stringify(leftSnapshot) === JSON.stringify(rightSnapshot);
}

async function replaceWithLink(linkPath, targetPath, type) {
  assertManagedPath(linkPath);
  const target = relativeTarget(linkPath, targetPath);
  const state = await pathState(linkPath);

  if (!state) {
    await symlink(target, linkPath, type);
    return;
  }

  if (state.isSymbolicLink()) {
    const currentTarget = portablePath(await readlink(linkPath));
    if (currentTarget === target && (await resolvesTo(linkPath, targetPath))) return;
  } else {
    let safeToReplace = false;
    if (state.isFile()) {
      const contents = portablePath((await readFile(linkPath, "utf8")).trim());
      safeToReplace = contents === target;
    } else if (type === "dir" && state.isDirectory()) {
      safeToReplace = await directoriesMatch(linkPath, targetPath);
    }

    if (!safeToReplace) {
      fail(
        `Refusing to replace ${path.relative(repoRoot, linkPath)} because it is not a symlink or an unchanged generated copy.`,
      );
    }
  }

  const backup = `${linkPath}.agent-link-backup-${process.pid}`;
  assertManagedPath(backup);
  await rename(linkPath, backup);
  try {
    await symlink(target, linkPath, type);
  } catch (error) {
    await rename(backup, linkPath);
    throw error;
  }
  await rm(backup, { recursive: !state.isSymbolicLink() && state.isDirectory(), force: false });
}

async function verifyLink(linkPath, targetPath, label) {
  const state = await pathState(linkPath);
  if (!state?.isSymbolicLink()) {
    fail(`${label} is not a real symbolic link: ${path.relative(repoRoot, linkPath)}`);
  }
  const currentTarget = portablePath(await readlink(linkPath));
  const expectedTarget = relativeTarget(linkPath, targetPath);
  if (currentTarget !== expectedTarget) {
    fail(`${label} uses ${currentTarget}, not the portable relative target ${expectedTarget}`);
  }
  if (!(await resolvesTo(linkPath, targetPath))) {
    fail(`${label} points to ${currentTarget}, not ${path.relative(repoRoot, targetPath)}`);
  }
}

async function discoverSkills() {
  const state = await pathState(sourceSkills);
  if (!state) return [];
  if (!state.isDirectory()) {
    fail(`Source skill path is not a directory: ${sourceSkills}`);
  }

  const entries = await readdir(sourceSkills, { withFileTypes: true });
  const skills = [];
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    const skillPath = path.join(sourceSkills, entry.name);
    const skillState = entry.isSymbolicLink() ? await stat(skillPath).catch(() => null) : null;
    if (!entry.isDirectory() && !skillState?.isDirectory()) continue;
    if ((await pathState(path.join(skillPath, "SKILL.md")))?.isFile()) {
      skills.push(entry.name);
    }
  }
  return skills;
}

function setRepositorySymlinkSupport() {
  try {
    execFileSync("git", ["config", "--local", "core.symlinks", "true"], {
      cwd: repoRoot,
      stdio: "ignore",
    });
  } catch (error) {
    fail("Could not set the repository-local Git option core.symlinks=true.", error);
  }
}

function verifyGitSymlinkSupport() {
  try {
    const value = execFileSync("git", ["config", "--bool", "--get", "core.symlinks"], {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (value !== "true") fail("Git core.symlinks must be true for this checkout.");
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("[agent.sync]")) throw error;
    fail("Git core.symlinks must be true for this checkout.", error);
  }
}

async function probeSymlinkSupport(skills) {
  const probeDirectory = path.join(repoRoot, ".agents");
  const probes = [
    {
      linkPath: path.join(probeDirectory, `.file-link-probe-${process.pid}`),
      targetPath: sourceInstructions,
      type: "file",
    },
  ];

  if (skills.length > 0) {
    probes.push({
      linkPath: path.join(probeDirectory, `.dir-link-probe-${process.pid}`),
      targetPath: path.join(sourceSkills, skills[0]),
      type: "dir",
    });
  }

  try {
    for (const probe of probes) {
      await symlink(relativeTarget(probe.linkPath, probe.targetPath), probe.linkPath, probe.type);
      await verifyLink(probe.linkPath, probe.targetPath, "Symlink probe");
      await unlink(probe.linkPath);
    }
  } catch (error) {
    for (const probe of probes) await unlink(probe.linkPath).catch(() => {});
    const platformHint = process.platform === "win32"
      ? " Enable Windows Developer Mode (or grant the Create symbolic links privilege), then retry."
      : " Check the directory permissions, then retry.";
    fail(`Could not create symbolic links.${platformHint}`, error);
  }
}

async function reconcileUnexpectedSkillEntries(skills) {
  const directoryState = await pathState(codexSkills);
  if (!directoryState) return;
  if (!directoryState.isDirectory()) {
    fail(`Managed skill path is not a directory: ${path.relative(repoRoot, codexSkills)}`);
  }

  const expected = new Set(skills);
  const entries = await readdir(codexSkills, { withFileTypes: true });
  const unexpected = entries.map((entry) => entry.name).filter((name) => !expected.has(name));
  if (unexpected.length === 0) return;

  if (options.check) {
    fail(`Unexpected entries in .agents/skills: ${unexpected.join(", ")}`);
  }

  for (const name of unexpected) {
    const linkPath = path.join(codexSkills, name);
    const expectedOldTarget = path.join(sourceSkills, name);
    const expectedRelativeTarget = relativeTarget(linkPath, expectedOldTarget);
    const state = await pathState(linkPath);
    let safeToRemove = false;

    if (state?.isSymbolicLink()) {
      const currentTarget = portablePath(await readlink(linkPath));
      safeToRemove = currentTarget === expectedRelativeTarget;
    } else if (state?.isFile()) {
      const contents = portablePath((await readFile(linkPath, "utf8")).trim());
      safeToRemove = contents === expectedRelativeTarget;
    }

    if (!safeToRemove) {
      fail(
        `Refusing to remove unexpected entry .agents/skills/${name} because it is not a managed skill symlink.`,
      );
    }
    await unlink(linkPath);
  }
}

async function main() {
  initializePaths(await resolveRepository(options.project));

  if (!(await pathState(sourceInstructions))?.isFile()) {
    fail(`Source instruction file does not exist: ${sourceInstructions}`);
  }

  const skills = await discoverSkills();

  if (options.check) {
    verifyGitSymlinkSupport();
    await verifyLink(codexInstructions, sourceInstructions, "Codex instruction file");
    for (const skill of skills) {
      await verifyLink(
        path.join(codexSkills, skill),
        path.join(sourceSkills, skill),
        `Codex skill ${skill}`,
      );
    }
    await reconcileUnexpectedSkillEntries(skills);
    console.log(`[agent.sync] Verified ${repoRoot}: AGENTS.md and ${skills.length} skill symlink(s).`);
    return;
  }

  setRepositorySymlinkSupport();
  await mkdir(path.join(repoRoot, ".agents"), { recursive: true });
  await mkdir(codexSkills, { recursive: true });
  await probeSymlinkSupport(skills);
  await reconcileUnexpectedSkillEntries(skills);

  await replaceWithLink(codexInstructions, sourceInstructions, "file");
  for (const skill of skills) {
    await replaceWithLink(
      path.join(codexSkills, skill),
      path.join(sourceSkills, skill),
      "dir",
    );
  }

  await reconcileUnexpectedSkillEntries(skills);
  await verifyLink(codexInstructions, sourceInstructions, "Codex instruction file");
  for (const skill of skills) {
    await verifyLink(
      path.join(codexSkills, skill),
      path.join(sourceSkills, skill),
      `Codex skill ${skill}`,
    );
  }

  console.log(
    `[agent.sync] Ready ${repoRoot}: AGENTS.md and ${skills.length} skill symlink(s) use the Claude files as their source of truth.`,
  );
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
