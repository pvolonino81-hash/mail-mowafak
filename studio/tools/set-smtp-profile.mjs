// set-smtp-profile.mjs - switches the sending identity of a client profile.
//
// The engine talks plain SMTP, so any mail provider with an SMTP endpoint works
// (Brevo, SendGrid, Mailgun, Postmark, Amazon SES, ...). Only the profile
// changes: host, port, username, encryption, sender identity and message-id host.
//
// Usage:
//   node tools/set-smtp-profile.mjs --host smtp.brevo.com --port 587 \
//     --username <apikey> --password-env BREVO_SMTP_PASSWORD --encryption starttls \
//     --from ups@agency.tld --from-name 'UPS SERVICES' --domain agency.tld
import { readFile, writeFile } from 'node:fs/promises';

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const files = process.argv.slice(2).filter(function (a) { return a.endsWith('.json'); });
if (!files.length) { console.error('usage: set-smtp-profile.mjs --host ... --port ... <client.json ...>'); process.exit(2); }

const host = arg('--host', '');
const port = Number(arg('--port', '587'));
const username = arg('--username', '');
const passwordEnv = arg('--password-env', '');
const encryption = arg('--encryption', 'starttls');
const helo = arg('--helo', '');
const fromEmail = arg('--from', '');
const fromName = arg('--from-name', '');
const domain = arg('--domain', '');

for (const file of files) {
  const raw = await readFile(file, 'utf8');
  const j = JSON.parse(raw);
  if (host) { j.smtp.host = host; j.smtp.port = port; j.smtp.encryption = encryption; }
  if (username) { j.smtp.username = username; }
  if (passwordEnv) { j.smtp.passwordEnv = passwordEnv; }
  if (helo) { j.smtp.heloDomain = helo; }
  if (username || fromEmail) {
    const accounts = [{
      provider: j.smtp.provider || 'custom',
      username: username || j.smtp.username,
      passwordEnv: passwordEnv || j.smtp.passwordEnv,
      label: 'primary'
    }];
    j.smtp.accounts = accounts;
  }
  if (fromEmail) { j.message.fromEmail = fromEmail; j.message.replyTo = fromEmail; }
  if (fromName) { j.message.fromName = fromName; j.message.brandName = fromName; }
  if (domain) { j.message.messageIdHost = domain; }
  await writeFile(file, JSON.stringify(j, null, 2) + '\n', 'utf8');
  console.log('updated ' + file + '  ->  ' + j.smtp.host + ':' + j.smtp.port + ' (' + j.smtp.encryption + ') as ' + j.message.fromEmail + ' @' + j.message.messageIdHost);
}
