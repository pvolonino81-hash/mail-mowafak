import { readFile, writeFile } from 'node:fs/promises';

const args = process.argv.slice(2);
function value(name, fallback) {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
}

const total = Number(value('--total', '10000'));
const accounts = Math.max(1, Number(value('--accounts', '1')));
const perHourPerAccount = Number(value('--per-hour', '50'));
const batch = Math.max(1, Number(value('--batch', '500')));
const warmupHours = Number(value('--warmup-hours', '48'));

const capacity = accounts * perHourPerAccount;
const hours = total / capacity;
const delay = Math.round(3600000 / capacity);
const batches = Math.ceil(total / batch);
const warmupMessages = Math.round(capacity * warmupHours);
const hoursPerBatch = batch / capacity;

console.log('list            : ' + total + ' recipients');
console.log('accounts        : ' + accounts + ' x ' + perHourPerAccount + '/hour = ' + capacity + ' messages/hour');
console.log('delay           : ' + delay + ' ms between messages');
console.log('batch size      : ' + batch + '   (' + batches + ' batches)');
console.log('per batch       : ' + hoursPerBatch.toFixed(1) + ' hours  -> the AI verifies once per batch');
console.log('warm-up         : ' + warmupMessages + ' messages over ' + warmupHours + ' hours');
console.log('total duration  : ' + hours.toFixed(1) + ' hours  (' + (hours / 24).toFixed(1) + ' days)');
console.log('accounts for 48h : ' + Math.ceil((total / 48 / perHourPerAccount)));
console.log('accounts for 7d  : ' + Math.ceil((total / 168 / perHourPerAccount)));