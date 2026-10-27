// Renders design/aether-icon.svg into the app's AppIcon set. Only needed
// after changing the icon; the rendered set is checked in.
//   npm install --no-save playwright && npx playwright install chromium
//   node scripts/render-icon.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const { chromium } = await import('playwright').catch(() => {
  console.error('render-icon needs Playwright: npm install --no-save playwright && npx playwright install chromium');
  process.exit(1);
});

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const svg = readFileSync(join(root, 'design/aether-icon.svg'), 'utf8');
const set = join(root, 'App/Assets.xcassets/AppIcon.appiconset');
mkdirSync(set, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1024, height: 1024 } });
await page.setContent(`<!doctype html><html><body style="margin:0;background:transparent">${svg}</body></html>`);
const master = join(set, 'icon_1024.png');
await page.screenshot({ path: master, omitBackground: true, clip: { x: 0, y: 0, width: 1024, height: 1024 } });
await browser.close();

const images = [];
for (const points of [16, 32, 128, 256, 512]) {
  for (const scale of [1, 2]) {
    const px = points * scale;
    const name = `icon_${points}${scale === 2 ? '@2x' : ''}.png`;
    if (px === 1024) execFileSync('cp', [master, join(set, name)]);
    else execFileSync('sips', ['-z', String(px), String(px), master, '--out', join(set, name)], { stdio: 'ignore' });
    images.push({ idiom: 'mac', size: `${points}x${points}`, scale: `${scale}x`, filename: name });
  }
}
writeFileSync(join(set, 'Contents.json'), JSON.stringify({ images, info: { version: 1, author: 'xcode' } }, null, 2));
writeFileSync(join(root, 'App/Assets.xcassets/Contents.json'), JSON.stringify({ info: { version: 1, author: 'xcode' } }, null, 2));
console.log('AppIcon: rendered', images.length, 'sizes');
