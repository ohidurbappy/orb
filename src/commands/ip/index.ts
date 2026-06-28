import type { Command } from '../types.js';
import { IpCommand } from './IpCommand.js';

export const ipCommand: Command = {
  name: 'ip',
  description: 'Print local IP address(es)',
  aliases: ['ipaddr'],
  Component: IpCommand,
};
