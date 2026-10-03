import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const files = [
  ['index.html', 'docs/index.html'],
  ['style.css', 'docs/site/style.css'],
  ['app.js', 'docs/site/app.js'],
];

for (const [source, output] of files) {
  const contents = readFileSync(join(root, 'site-source', source), 'utf8');
  if (source.endsWith('.js') && /^\s*\/\//m.test(contents)) {
    throw new Error('Line comments in JavaScript must be removed before flattening.');
  }
  writeFileSync(join(root, output), contents.replace(/\r?\n[ \t]*/g, ' ').trim(), 'utf8');
}
