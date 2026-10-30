'use strict';

// Evaluate the pinned upstream MIT implementation; do not duplicate the Swift
// formula here. The original source stays in ignored build/MathReference.
const fs = require('node:fs');
const crypto = require('node:crypto');
const vm = require('node:vm');
const [input, output] = process.argv.slice(2);
if (!input || !output) throw new Error('Usage: node generate_insulin_goldens.cjs REFERENCE_JS OUTPUT_JSON');
const source = fs.readFileSync(input, 'utf8');
const sha256 = crypto.createHash('sha256').update(source).digest('hex');
const expectedSHA256 = 'ca8b738cd5c4db037760949c09028448e01b155680f0bac6c3c081e24300d348';
if (sha256 !== expectedSHA256) throw new Error('Pinned OpenAPS source hash mismatch');
const context = { module: { exports: {} }, exports: {}, console };
vm.createContext(context);
vm.runInContext(source, context, { timeout: 1000 });
const vectors = [];
for (let dia = 180; dia <= 600; dia += 30) {
  for (const peak of [75, 55, 45]) {
    for (const units of [0.05, 1, 2.75, 10]) {
      for (const age of [0, 0.000001, peak - 0.000001, peak, peak + 0.000001,
                         dia / 2, dia - 0.000001, dia, dia + 0.000001]) {
        const profile = { curve: peak === 75 ? 'rapid-acting' : 'ultra-rapid',
                          useCustomPeakTime: true, insulinPeakTime: peak };
        const result = context.iobCalcExponential({ insulin: units }, age, dia / 60, peak, profile);
        if (!Number.isFinite(result.iobContrib)) throw new Error('Non-finite oracle output');
        vectors.push([dia, peak, age, units, result.iobContrib]);
      }
    }
  }
}
const metadata = {
  schemaVersion: 1,
  sourceURL: 'https://github.com/openaps/oref0/blob/88cf032aa74ff25f69464a7d9cd601ee3940c0b3/lib/iob/calculate.js',
  sourceSHA256: sha256,
  sourceLicense: 'MIT',
  oracle: 'iobCalcExponential continuous-age helper; outer minute-rounding wrapper intentionally bypassed',
  columns: ['durationMinutes', 'peakMinutes', 'ageMinutes', 'units', 'expectedIOB'],
};
const header = JSON.stringify(metadata, null, 2).slice(0, -2);
fs.writeFileSync(output, `${header},\n  "vectors": [\n${vectors.map(v => '    ' + JSON.stringify(v)).join(',\n')}\n  ]\n}\n`);
process.stdout.write(`Generated ${vectors.length} independent insulin vectors.\n`);
