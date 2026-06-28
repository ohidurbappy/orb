import os from 'node:os';

export interface IpEntry {
  /** Network interface name, e.g. `en0`, `eth0`. */
  iface: string;
  /** The assigned address. */
  address: string;
  /** Address family. Node reports `'IPv4'`/`'IPv6'` (older Node used `4`/`6`). */
  family: 'IPv4' | 'IPv6';
}

type NetworkInterfaces = typeof os.networkInterfaces;

/**
 * Collect non-internal (loopback excluded) IP addresses for every interface.
 *
 * The `networkInterfaces` function is injected so tests can pass a fixture
 * instead of mocking the `os` module.
 */
export function getLocalIps(
  networkInterfaces: NetworkInterfaces = os.networkInterfaces,
): IpEntry[] {
  const interfaces = networkInterfaces();
  const entries: IpEntry[] = [];

  for (const [iface, addrs] of Object.entries(interfaces)) {
    if (!addrs) continue;
    for (const addr of addrs) {
      if (addr.internal) continue;
      const family = normalizeFamily(addr.family);
      entries.push({ iface, address: addr.address, family });
    }
  }

  return entries;
}

/**
 * The single most useful "this machine's IP" — the first non-internal IPv4,
 * or the first IPv6 if no IPv4 exists. Returns undefined when offline.
 */
export function getPrimaryIp(entries: IpEntry[]): IpEntry | undefined {
  return entries.find((e) => e.family === 'IPv4') ?? entries[0];
}

function normalizeFamily(family: string | number): 'IPv4' | 'IPv6' {
  if (family === 'IPv6' || family === 6) return 'IPv6';
  return 'IPv4';
}
