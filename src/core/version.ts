// `version.txt` is the single source of truth for the release version. Bun
// inlines this text import into the compiled binary, so VERSION is fixed at
// build time without any codegen step. CI rewrites version.txt (patch = run
// number) before building, so each push ships a strictly-increasing version.
import versionText from '../../version.txt';

export const VERSION: string = versionText.trim();

/** `owner/repo` used for release checks and downloads. */
export const REPO = 'ohidurbappy/orb';
