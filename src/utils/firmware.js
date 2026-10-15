import fs from 'fs';
import path from 'path';
import { execFileSync } from 'child_process';

/*
 * Which build of this program is running - read once, when the program
 * starts, and never again.
 *
 * That is the point: what is reported is the code in memory, not the files on
 * disk. After a firmware update the two only agree once the program has been
 * restarted, so a camera still showing the old version after an update is a
 * camera that was not restarted - which is exactly what someone checking the
 * update needs to see.
 *
 * Sources, best first:
 *   .firmware.json  written into every bundle the OCR Center builds
 *   git             cameras installed by cloning the repository
 *   package.json    nothing better is known
 */
const read = () => {
  const root = process.cwd();
  try {
    const meta = JSON.parse(fs.readFileSync(path.join(root, '.firmware.json'), 'utf8'));
    if (meta.version) {
      return {
        version: meta.version,
        sha: meta.sha ? String(meta.sha).slice(0, 7) : null,
        commitDate: meta.commitDate || null,
        source: 'bundle',
      };
    }
  } catch (e) { /* not installed from a bundle */ }

  try {
    const out = execFileSync('git', ['-C', root, 'log', '-1', '--format=%h|%cI'], {
      encoding: 'utf8', timeout: 3000, stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    const [sha, commitDate] = out.split('|');
    if (sha) {
      return {
        version: `git-${commitDate.slice(0, 10).replace(/-/g, '')}-${sha}`,
        sha,
        commitDate,
        source: 'git',
      };
    }
  } catch (e) { /* not a git checkout, or no git */ }

  let pkg = '0.0.0';
  try {
    // eslint-disable-next-line global-require
    pkg = require('../../package.json').version || pkg;
  } catch (e) { /* keep the default */ }
  return { version: pkg, sha: null, commitDate: null, source: 'package' };
};

const firmware = { ...read(), startedAt: new Date().toISOString() };

export default firmware;
