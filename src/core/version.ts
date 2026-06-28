// Bun inlines this JSON import into the compiled binary, so VERSION is fixed at
// build time without any codegen step.
import pkg from '../../package.json' with { type: 'json' };

export const VERSION: string = pkg.version;

/** `owner/repo` used for release checks and downloads. */
export const REPO = 'ohidurbappy/orb';
