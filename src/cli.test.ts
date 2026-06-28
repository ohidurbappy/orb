import { describe, expect, it } from 'bun:test';
import { parseArgs } from './cli.js';
import { findCommand, COMMANDS } from './commands/index.js';

describe('parseArgs', () => {
  it('parses a command name', () => {
    expect(parseArgs(['ip']).commandName).toBe('ip');
  });

  it('parses flags', () => {
    expect(parseArgs(['--version']).version).toBe(true);
    expect(parseArgs(['-h']).help).toBe(true);
  });

  it('takes the first non-flag token as the command', () => {
    expect(parseArgs(['--verbose', 'sysinfo']).commandName).toBe('sysinfo');
  });

  it('returns no command when only flags are given', () => {
    expect(parseArgs([]).commandName).toBeUndefined();
  });

  it('collects positional tokens after the command as commandArgs', () => {
    const parsed = parseArgs(['qr', 'hello', 'world']);
    expect(parsed.commandName).toBe('qr');
    expect(parsed.commandArgs).toEqual(['hello', 'world']);
  });

  it('keeps commandArgs empty when only the command is given', () => {
    expect(parseArgs(['ip']).commandArgs).toEqual([]);
  });
});

describe('findCommand', () => {
  it('resolves by canonical name', () => {
    expect(findCommand('ip')?.name).toBe('ip');
  });

  it('resolves by alias', () => {
    expect(findCommand('neofetch')?.name).toBe('sysinfo');
    expect(findCommand('upgrade')?.name).toBe('update');
  });

  it('returns undefined for unknown commands', () => {
    expect(findCommand('nope')).toBeUndefined();
  });

  it('every command has a unique name', () => {
    const names = COMMANDS.map((c) => c.name);
    expect(new Set(names).size).toBe(names.length);
  });
});
