import { describe, expect, it } from 'bun:test';
import { getLocalIps, getPrimaryIp } from './ip.js';

const fixture = () =>
  ({
    lo0: [{ address: '127.0.0.1', family: 'IPv4', internal: true } as any],
    en0: [
      { address: 'fe80::1', family: 'IPv6', internal: false } as any,
      { address: '192.168.1.5', family: 'IPv4', internal: false } as any,
    ],
  }) as ReturnType<typeof import('node:os').networkInterfaces>;

describe('getLocalIps', () => {
  it('excludes internal addresses', () => {
    const ips = getLocalIps(fixture);
    expect(ips.some((e) => e.address === '127.0.0.1')).toBe(false);
  });

  it('returns both IPv4 and IPv6 non-internal addresses', () => {
    const ips = getLocalIps(fixture);
    expect(ips).toEqual([
      { iface: 'en0', address: 'fe80::1', family: 'IPv6' },
      { iface: 'en0', address: '192.168.1.5', family: 'IPv4' },
    ]);
  });

  it('handles no interfaces', () => {
    expect(getLocalIps(() => ({}))).toEqual([]);
  });
});

describe('getPrimaryIp', () => {
  it('prefers the first IPv4', () => {
    const ips = getLocalIps(fixture);
    expect(getPrimaryIp(ips)?.address).toBe('192.168.1.5');
  });

  it('falls back to the first entry when no IPv4 exists', () => {
    const ipv6Only = getLocalIps(
      () => ({ en0: [{ address: 'fe80::1', family: 'IPv6', internal: false } as any] }) as any,
    );
    expect(getPrimaryIp(ipv6Only)?.family).toBe('IPv6');
  });

  it('returns undefined for an empty list', () => {
    expect(getPrimaryIp([])).toBeUndefined();
  });
});
