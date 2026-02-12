#!/usr/bin/env node
/**
 * Modify .releaserc config for PR changelog generation:
 * 1. Override branches to treat current branch as stable release branch
 * 2. Remove @semantic-release/github plugin (no actual releases)
 * 3. Remove @semantic-release/git plugin (no commits pushed)
 *
 * Usage: node modify-releaserc.js <config-file> <branch-name>
 */

const fs = require('fs');

const configPath = process.argv[2];
const branchName = process.argv[3];

if (!configPath || !branchName) {
  console.error('Usage: node modify-releaserc.js <config-file> <branch-name>');
  process.exit(1);
}

let content = fs.readFileSync(configPath, 'utf8');

if (configPath.endsWith('.yml') || configPath.endsWith('.yaml')) {
  // Try array-style first (branches:\n  - main\n  - develop\n)
  // This MUST come before the inline check, because inline replacement
  // would leave the array items dangling
  const arrayPattern = /^branches:\s*\n(\s+-\s+.+\n)+/m;
  if (arrayPattern.test(content)) {
    content = content.replace(arrayPattern, 'branches: ["' + branchName + '"]\n');
  } else {
    // Inline style: branches: [main] or branches: main
    content = content.replace(/^branches:.*$/m, 'branches: ["' + branchName + '"]');
  }
} else if (configPath.endsWith('.json')) {
  const config = JSON.parse(content);
  config.branches = [branchName];
  content = JSON.stringify(config, null, 2);
}

// Remove @semantic-release/github plugin (we don't want to create actual releases)
content = content.replace(/^\s*-\s*["']?@semantic-release\/github["']?\s*$/m, '');

// Remove @semantic-release/git plugin (we don't want to push commits)
// Handle both simple string and array format
content = content.replace(/^\s*-\s*-\s*["']?@semantic-release\/git["']?\s*\n(\s+-\s+.*\n)*/gm, '');
content = content.replace(/^\s*-\s*["']?@semantic-release\/git["']?\s*$/m, '');

fs.writeFileSync(configPath, content);
console.log('Modified ' + configPath + ' for branch: ' + branchName);
