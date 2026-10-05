#!/usr/bin/env node
// Runs install.sh from this package with the arguments given: "npx agent-redline-ios" installs or
// updates Redline, and "npx agent-redline-ios uninstall" removes it.
'use strict';

const { spawnSync } = require('node:child_process');
const path = require('node:path');

const root = path.join(__dirname, '..');
const result = spawnSync('/bin/bash', [path.join(root, 'install.sh'), ...process.argv.slice(2)], {
  cwd: root,
  stdio: 'inherit',
});
if (result.error) {
  console.error(`Couldn't run install.sh: ${result.error.message}`);
  process.exit(1);
}
process.exit(result.status === null ? 1 : result.status);
