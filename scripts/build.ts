#!/usr/bin/env bun
import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';

interface Target {
  /** Bun cross-compile target triple. */
  bun: string;
  /** Output filename — must match `assetNameFor` in src/core/updater/assets.ts. */
  out: string;
}

const TARGETS: Target[] = [
  { bun: 'bun-darwin-arm64', out: 'orb-darwin-arm64' },
  { bun: 'bun-darwin-x64', out: 'orb-darwin-x64' },
  { bun: 'bun-linux-x64', out: 'orb-linux-x64' },
  { bun: 'bun-linux-arm64', out: 'orb-linux-arm64' },
  { bun: 'bun-windows-x64', out: 'orb-windows-x64.exe' },
];

mkdirSync('dist', { recursive: true });

// Allow building a single target: `bun run scripts/build.ts darwin-arm64`
const filter = process.argv[2];
const targets = filter ? TARGETS.filter((t) => t.out.includes(filter)) : TARGETS;

let failures = 0;
for (const target of targets) {
  console.log(`▶ building ${target.out} (${target.bun})`);
  const result = spawnSync(
    'bun',
    [
      'build',
      'src/cli.tsx',
      '--compile',
      `--target=${target.bun}`,
      `--outfile=dist/${target.out}`,
    ],
    { stdio: 'inherit' },
  );
  if (result.status !== 0) {
    console.error(`✗ failed: ${target.out}`);
    failures++;
  }
}

if (failures > 0) {
  console.error(`\n${failures} target(s) failed.`);
  process.exit(1);
}
console.log(`\n✓ built ${targets.length} target(s) into dist/`);
