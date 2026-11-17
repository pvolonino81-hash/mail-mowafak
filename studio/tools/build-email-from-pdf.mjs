// build-email-from-pdf.mjs - rewrites the campaign email so it mirrors the PDF page.
import { readFile, writeFile } from 'node:fs/promises';

const ws = process.argv[2];
const src = await readFile(ws + '/MailRotator-General/clients/ups-trial/message.html', 'utf8');
const m = src.match(/data:image\/png;base64,[A-Za-z0-9+/=]+/);
if (!m) { console.log('no embedded logo found'); process.exit(1); }
const LOGO = m[0];

const T = (rows) => rows.join('');

const head = T([
  '<div class="ii gt"><div class="a3s aiL msg-9010548318477428731">',
  '<div style="margin:0;padding:0;min-width:100%;background-color:#ededed">',
  '<table role="presentation" border="0" bgcolor="#ffffff" cellpadding="0" cellspacing="0" width="600" style="border-spacing:0;border-collapse:collapse;margin:24px auto;background-color:#ffffff;border-radius:8px;overflow:hidden;box-shadow:0 4px 12px rgba(0,0,0,0.06)">',
  '<tbody>'
]);

const row = (content, pad) => '<tr><td align="left" style="padding:' + pad + '">' + content + '</td></tr>';
const cell = (inner, style) => '<table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%"><tbody><tr><td align="left" style="' + style + '">' + inner + '</td></tr></tbody></table>';

const F = "font-family:'Roboto',Tahoma,Arial,Helvetica,sans-serif";

const header = row(
  cell(
    '<table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%"><tbody><tr>' +
      '<td width="66" valign="middle" style="padding-right:16px"><img src="' + LOGO + '" alt="UPS" width="52" height="52" border="0" style="display:block"></td>' +
      '<td valign="middle" style="padding-right:14px"><div style="' + F + ';font-size:30px;font-weight:800;letter-spacing:3px;color:#330000;line-height:1">UPS</div>' +
        '<div style="' + F + ';font-size:11px;letter-spacing:2.2px;color:#814900;text-transform:uppercase;padding-top:4px">My Choice &mdash; Device Services</div></td>' +
      '<td valign="middle" align="right" style="' + F + ';font-size:11px;color:#6b6b6b;line-height:1.7">Document ID<br><b style="color:#330000">1ZV551D60337320914</b><br>Issued 16 November 2026</td>' +
    '</tr></tbody></table>',
    'padding:26px 28px 18px;border-bottom:3px solid #330000'
  ),
  '26px 28px 18px'
);

const salutation = row(
  cell('<span style="' + F + ';font-size:14px;color:#555555">Dear {{first_name}},</span>', 'padding:20px 28px 0'),
  '0'
);

const title = row(
  cell('<span style="' + F + ';font-size:21px;font-weight:700;color:#330000;letter-spacing:.3px">Shipping Label &amp; Setup Notice</span>', 'padding:14px 28px 0'),
  '0'
);

const lead = row(
  cell('<span style="' + F + ';font-size:14px;color:#333333;line-height:1.75">Your package could not be completed and the address on file needs to be confirmed. The full label and the device setup notice are attached to this document.</span>', 'padding:10px 28px 0'),
  '0'
);

const gridRows = [
  ['Tracking number', '1ZV551D60337320914'],
  ['Ship to', 'Delivery address on file'],
  ['Service', 'UPS My Choice &mdash; Device Services'],
  ['Reference', 'UPS-MC-LABEL-11407']
].map(function (p) {
  return '<tr>' +
    '<td width="44%" bgcolor="#f6f6f4" style="' + F + ';font-size:12.5px;font-weight:600;color:#555555;padding:9px 12px;border-bottom:1px solid #e8e8e8">' + p[0] + '</td>' +
    '<td style="' + F + ';font-size:12.5px;color:#1a1a1a;padding:9px 12px;border-bottom:1px solid #e8e8e8">' + p[1] + '</td>' +
  '</tr>';
}).join('');

const grid = row(
  '<table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="border:1px solid #d9d9d9;border-collapse:collapse;border-radius:3px;overflow:hidden">' + gridRows + '</table>',
  '22px 28px 0'
);

const cta = row(
  cell(
    '<div style="margin:0;padding:18px 20px;border:1px solid #330000;border-left:6px solid #FFBE00;border-radius:3px;background-color:#fffdf6">' +
      '<div style="' + F + ';font-size:15px;font-weight:700;color:#330000;padding-bottom:6px">UPS_MyChoice_Label_1ZV551D60337320914.pdf</div>' +
      '<div style="' + F + ';font-size:12.5px;color:#555555;line-height:1.7;padding-bottom:14px">The shipping label and the device setup notice are stored as one PDF file. Open the attached document to continue.</div>' +
      '<table role="presentation" border="0" cellpadding="0" cellspacing="0"><tbody><tr>' +
        '<td bgcolor="#FFBE00" style="border-radius:3px"><a href="{{tracking_link}}" target="_blank" style="display:block;' + F + ';font-size:13px;font-weight:700;color:#330000;text-decoration:none;padding:11px 20px;letter-spacing:.3px">Open the attached document</a></td>' +
        '<td width="12" style="font-size:0;line-height:0">&nbsp;</td>' +
        '<td valign="middle"><a href="{{tracking_link}}" target="_blank" style="' + F + ';font-size:11.5px;font-weight:600;color:#814900;text-decoration:underline">Download the attached file</a></td>' +
      '</tr></tbody></table>' +
    '</div>',
    'padding:22px 28px 0'
  ),
  '0'
);

const footer = row(
  cell(
    '<div style="' + F + ';font-size:10.5px;color:#8a8a8a;line-height:1.8;border-top:1px solid #e6e6e6;padding-top:14px">' +
      'United Parcel Service of America, Inc., 1 UPS Way, Atlanta, GA 30315, USA<br>' +
      'This document was generated for the recipient named on the shipping record. Please keep the tracking number for your records.' +
    '</div>' +
    '<div style="padding-top:12px"><a href="{{unsubscribe_link}}" target="_blank" style="' + F + ';font-size:11.5px;font-weight:600;color:#814900;text-decoration:underline">Manage Alerts</a></div>',
    'padding:24px 28px 28px'
  ),
  '0'
);

const html = head + header + salutation + title + lead + grid + cta + footer +
  '</tbody></table></div></div></div>';

for (const f of [ws + '/MailRotator-General/clients/ups-trial/message.html', ws + '/MailRotatorStudio/engine/clients/ups-trial/message.html']) {
  await writeFile(f, html, 'utf8');
  console.log('rewritten: ' + f + '  (' + html.length + ' bytes)');
}
