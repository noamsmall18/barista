const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {spawnSync} = require('node:child_process');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'barista-install-test-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  const repo = path.resolve(__dirname, '../..');
  for (const dir of ['bin', '.build/release', 'Barista/Web', 'Branding', 'scripts', 'Applications']) {
    fs.mkdirSync(path.join(root, dir), {recursive: true});
  }
  fs.copyFileSync(path.join(repo, 'build-app.sh'), path.join(root, 'build-app.sh'));
  fs.copyFileSync(path.join(repo, 'scripts/bundle-research.sh'), path.join(root, 'scripts/bundle-research.sh'));
  for (const name of ['Info.plist', 'Info-Marketbar.plist', 'Barista.entitlements']) {
    fs.copyFileSync(path.join(repo, 'Barista', name), path.join(root, 'Barista', name));
  }
  fs.writeFileSync(path.join(root, 'Branding/MarketbarIcon.icns'), 'test-icon');
  fs.writeFileSync(path.join(root, '.build/release/Barista'), 'latest-test-binary');
  fs.writeFileSync(path.join(root, 'Barista/Web/index.html'), 'test-assets');
  const command = (name, body) => fs.writeFileSync(path.join(root, 'bin', name), '#!/bin/sh\n' + body + '\n', {mode: 0o755});
  command('swift', 'exit 0');
  command('codesign', '[ "${TEST_CODESIGN_FAIL:-0}" = "0" ]');
  command('mv', '[ "${TEST_MV_FAIL:-0}" != "1" ] || case "$1" in */Marketbar.app) exit 1 ;; esac\nexec /bin/mv "$@"');
  for (const name of ['open', 'pgrep', 'pkill']) command(name, 'echo "unexpected live app action" >&2; exit 90');
  const apps = path.join(root, 'Applications');
  const run = (args, env = {}) => spawnSync('/bin/sh', [path.join(root, 'build-app.sh'), ...args], {
    encoding: 'utf8', env: {...process.env, PATH: path.join(root, 'bin') + ':' + process.env.PATH,
      BARISTA_TEST_MODE: '1', BARISTA_APPLICATIONS_DIR: apps, ...env}
  });
  const installed = path.join(apps, 'Marketbar.app');
  function existing(identifier = 'com.noam.marketbar.app') {
    fs.mkdirSync(path.join(installed, 'Contents/MacOS'), {recursive: true});
    const plist = fs.readFileSync(path.join(root, 'Barista/Info-Marketbar.plist'), 'utf8');
    fs.writeFileSync(path.join(installed, 'Contents/Info.plist'), plist.replace('com.noam.marketbar.app', identifier));
    fs.writeFileSync(path.join(installed, 'Contents/MacOS/Marketbar'), 'previous-test-binary');
  }
  return {root, apps, installed, run, existing};
}

test('build-only creates no app bundles or alternate installed copies', t => {
  const f = fixture(t);
  const result = f.run(['marketbar']);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /No app copies created/);
  assert.deepEqual(fs.readdirSync(f.apps), []);
  assert.equal(fs.existsSync(path.join(f.root, 'dist/Marketbar.app')), false);
});

test('install replaces the canonical app and leaves no staging or dist copies', t => {
  const f = fixture(t); f.existing();
  const result = f.run(['marketbar', '--install']);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(path.join(f.installed, 'Contents/MacOS/Marketbar'), 'utf8'), 'latest-test-binary');
  assert.deepEqual(fs.readdirSync(f.apps), ['Marketbar.app']);
  assert.equal(fs.existsSync(path.join(f.root, 'dist/Marketbar.app')), false);
});

test('failed signature verification preserves the existing app and cleans staging', t => {
  const f = fixture(t); f.existing();
  const result = f.run(['marketbar', '--install'], {TEST_CODESIGN_FAIL: '1'});
  assert.notEqual(result.status, 0);
  assert.equal(fs.readFileSync(path.join(f.installed, 'Contents/MacOS/Marketbar'), 'utf8'), 'previous-test-binary');
  assert.deepEqual(fs.readdirSync(f.apps), ['Marketbar.app']);
});

test('a failed final move restores the previous app instead of deleting it', t => {
  const f = fixture(t); f.existing();
  const result = f.run(['marketbar', '--install'], {TEST_MV_FAIL: '1'});
  assert.notEqual(result.status, 0);
  assert.equal(fs.readFileSync(path.join(f.installed, 'Contents/MacOS/Marketbar'), 'utf8'), 'previous-test-binary');
  assert.deepEqual(fs.readdirSync(f.apps), ['Marketbar.app']);
});

test('an unrelated bundle at the installation path is never replaced', t => {
  const f = fixture(t); f.existing('com.example.unrelated');
  const result = f.run(['marketbar', '--install']);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /refusing to replace unrelated app/);
  assert.equal(fs.readFileSync(path.join(f.installed, 'Contents/MacOS/Marketbar'), 'utf8'), 'previous-test-binary');
});

test('production cannot install to another directory', t => {
  const f = fixture(t);
  const result = f.run(['marketbar', '--install'], {BARISTA_TEST_MODE: '0'});
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /alternate installation directories.*only in isolated tests/);
  assert.deepEqual(fs.readdirSync(f.apps), []);
});
