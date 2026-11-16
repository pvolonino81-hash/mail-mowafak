# الميلر العام (MailRotator) — دليل التشغيل السريع

> هذا الملف هو **المدخل العملي**. الدليل المصوّر الكامل موجود في: `guide\index.html` (افتحه بأي متصفح).

---

## ما هو «الميلر العام»؟

مفهوم واحد يحكم كل شيء: **الميلر = محرّك واحد محايد، والعميل = ملف تعريف واحد.**

| | |
|---|---|
| المحرك (البرنامج) | هوية محايدة: لا اسم ولا شعار في الرسالة. الشعار هو ملك البرنامج وصاحب الترخيص. |
| العميل (ملف `clients\<id>\client.json`) | يحدّد كل ما يراه المستلم: العلامة، المرسل، نص الرسالة، الجمهور، حسابات SMTP، الروابط، العنوان البريدي. |

نتيجة عملية مهمة: **كل عميل له حالة مستقلة** — نقطة استئناف (`checkpoint`) وقائمة منع (`suppressed`) في `state\<id>\`، فلا يستطيع عميل أن يخاطب عنواناً منعه عميل آخر، وحملة العميل تُستأنف من مكان توقّفت تماماً.

---

## 0) المتطلبات

- Windows 10 أو 11.
- PowerShell 5.1 (موجود أصلاً مع ويندوز).
- **لا شيء آخر**: لا Python ولا Node ولا npm install.
- من عندك: حساب بريد واحد على الأقل، صفحة هبوط، صفحة إلغاء اشتراك، ونطاق جمهور.

---

## 1) جهّز المجلد وتحقّق من سلامة النسخة

```powershell
Expand-Archive -Path .\MailRotator.zip -DestinationPath .\MailRotator
cd .\MailRotator

# فحص سلامة: يجب أن ينتهي بـ "0 failed"
.\tests\Test-Unit.ps1
```

عند كل تشغيل يتحقّق البرنامج من **توقيع RSA-2048** على الملفات المحمية. إذا عدّلتَ ملفاً محمياً سيتوقف البرنامج عمداً:

```
MAILROTATOR - INTEGRITY CHECK FAILED
  - Protected file was modified: lib/Message.ps1
```

---

## 2) أنشئ ملف عميل (هذا هو «العمل على الميلر»)

انسخ المثال وعدّله:

```powershell
Copy-Item .\clients\example .\clients\acme -Recurse
notepad .\clients\acme\client.json
```

| الحقل | ما يضبطه | ملاحظة |
|---|---|---|
| `id` / `name` | معرّف العميل | يظهر في `-ClientId` وفي تقرير الحملة |
| `smtp.provider` | `auto` / `suddenlink` / `optimum` / `outlook` / `office365` | `auto` يكتشف المزوّد من عنوان البريد |
| `smtp.username` | بريد الحساب | يجب أن يطابق `message.fromEmail` |
| `smtp.passwordEnv` | **اسم** متغيّر البيئة لا كلمة المرور نفسها | يطلبها المشغّل مخفية |
| `smtp.accounts[]` | عدة حسابات بالتناوب | ينتقل تلقائياً للحساب التالي إذا توقّف أحدها عن القبول |
| `message.brandName` | اسم العلامة | يظهر في الموضوع كـ `{{brand_name}}` |
| `message.fromName` / `fromEmail` / `replyTo` | اسم المرسل وبريده | `fromEmail` = `smtp.username` إلزامياً وإلا رُفضت الرسالة |
| `message.subject` | سطر الموضوع | يدعم `{{first_name}}` |
| `message.templatePath` | ملف الرسالة | `message.html` بجوار `client.json` |
| `message.landingUrl` | صفحة الهبوط | |
| `message.unsubscribeUrl` / `listUnsubscribe` | رابط الإلغاء | رأس `List-Unsubscribe` + رابط في متن الرسالة |
| `message.messageIdHost` | نطاق رسالتك | يُستخدم في `Message-ID` |
| `message.physicalAddress` | عنوانك البريدي | **إلزامي**: الإرسال يتوقف بدونه |
| `message.requireUnsubscribe` | `true` | اتركه مفعّلاً |
| `message.allowedDomains` | نطاقات الجمهور | من خارجها = `skipped` لا `failed`، ويُطبَّق قبل فتح أي جلسة SMTP |
| `message.variants[]` | إبداعات بديلة | تتبدّل كل `rotateEvery` رسالة، ولكل واحدة رابطها وتقريرها |

---

## 3) جهّز الرسالة وقائمة المستلمين

**الرسالة** (`clients\acme\message.html`) — المتغيّرات المتاحة:

```
{{first_name}}  {{company}}  {{tracking_link}}  {{unsubscribe_link}}
```

(`{{tracking_link}}` يُملأ برابط فريد لكل مستلم على نطاقك، فكل نقرة تُنسب لصاحبها و للإبداع الذي وصله.)

**القائمة** — `data\recipients.txt` (سطر لكل عنوان، واسم بعد فاصلة) أو CSV:

```
jane.doe@charter.net,Jane Doe
john.roe@spectrum.net,John Roe
```

يُتجاهل السطر الفارغ و`#`، ويُحذف غير الصالح، وتُحفظ نسخة واحدة فقط من المكرر.

---

## 4) كلمة المرور — لا تكتبها في أي ملف

**الطريقة الأفضل**: المشغّل يسأل عنها بنفسه، مخفية على الشاشة، ويُمسح من الذاكرة بعد الانتهاء:

```powershell
.\tools\Run-MailRotator.ps1 -ClientId acme -RecipientsPath .\data\recipients.txt -DryRun
```

**أو** اضبطها بنفسك في متغيّر بيئة:

```powershell
$env:OPTONLINE_SMTP_PASSWORD = 'كلمة-المرور'
# ليبقى بعد إغلاق النافذة:
[Environment]::SetEnvironmentVariable('OPTONLINE_SMTP_PASSWORD','كلمة-المرور','User')
```

لا تضعها في `config\config.json` ولا في أي ملف ولا في لقطة شاشة.

---

## 5) جفّ ثم أرسل

```powershell
# اعرف العملاء الموجودين
.\tools\Send-Campaign.ps1 -List

# 1) جفّ: يتحقّق من كل شيء ولا يرسل شيئاً
.\tools\Send-Campaign.ps1 -ClientId acme -RecipientsPath .\data\recipients.txt -DryRun

# 2) الإرسال الحقيقي: نفس الأمر بلا -DryRun
.\tools\Send-Campaign.ps1 -ClientId acme -RecipientsPath .\data\recipients.txt
```

الأمر يطبع **ملخّص الحملة** قبل التنفيذ:

```
  client        : acme
  brand         : My Account
  sender        : lynorr@suddenlink.net
  subject       : Hi {{first_name}}, your {{brand_name}} order is ready
  template      : message.html
  landing page  : https://...
  audience      : charter.net, spectrum.net
  batch size    : 150
  smtp account  : suddenlink-1 (lynorr@suddenlink.net)
  state folder  : ...\state\acme
```

ثم يكتب: `logs\plan-*.json` (خطة الجفّ) و `preview\preview-*.eml` (رسالة نموذجية).

---

## 6) أثناء الحملة وبعدها

```powershell
# لوحة متابعة حية
.\tools\Monitor-MailRotator.ps1 -IntervalSeconds 5
.\tools\Monitor-MailRotator.ps1 -Once

# استئناف حملة توقّفت
.\tools\Send-Campaign.ps1 -ClientId acme -RecipientsPath .\data\recipients.txt -Resume

# حدّ أعلى لعدد الرسائل في هذه الجلسة
.\tools\Send-Campaign.ps1 -ClientId acme -RecipientsPath .\data\recipients.txt -MaxMessages 500
```

| الملف | المحتوى |
|---|---|
| `logs\run-<stamp>.jsonl` | سجل أحداث منظّم (سطر JSON لكل حدث) |
| `logs\report-<stamp>.json` | تقرير الحملة آلياً (لكل إبداع على حدة) |
| `state\<id>\checkpoint.json` | نقطة الاستئناف — يمنع إعادة إرسال نفس الرسالة |
| `state\<id>\suppressed.json` | عناوين يجب ألا تُخاطَب مرة أخرى |

---

## 7) البروكسي وتبديل عنوان الخروج

```powershell
.\tools\Test-Proxy.ps1 -ClientId acme -Count 3
```

يقرأ عنوان الخروج فعلياً عبر النفق ويبدّله، فتتأكد أن الحساب والاستهداف يعطيان الـIP المتوقّع.

- `proxy.mode = "gateway"` — سكني بالـGB، بلا تطبيق: يصنع السكربت جلسة `ssid-<id>` جديدة عند كل تبديل.
- `proxy.mode = "local"` — سكني بالـIP عبر تطبيق 9Proxy (يجب أن يكون يعمل والمنفذ مُحوَّلاً).
- `proxy.rotationEvery = 150` — عدد الرسائل لكل عنوان (الافتراضي). الرسالة 151 تخرج من عنوان مختلف.

---

## 8) ما لا تعدّله

| محميّ (تعديله يوقف البرنامج) | حرّ للتعديل |
|---|---|
| `README.md`, `Send-Mail.ps1`, `lib\*.ps1`, `tests\*.ps1` | `config\`, `data\`, `clients\`, `logs\`, `state\` |

إن غيّرت ملفاً محمياً عن قصد، أعد التوقيع (تحتاج **المفتاح الخاص** الذي لا يُوزَّع مع الحزمة):

```powershell
.\tools\Protect-MailRotator.ps1 -Brand "اسم علامتك"
```

---

## 9) عند مواجهة مشكلة

| العَرَض | السبب | الحل |
|---|---|---|
| `553 ... does not match authenticated name` | `fromEmail` ≠ `smtp.username` | وحّدهما |
| `535 Authentication credentials invalid` | كلمة مرور خاطئة أو المتغيّر غير مضبوط في نفس الجلسة | `$env:OPTONLINE_SMTP_PASSWORD` قبل التشغيل |
| `454 TLS not available` | الخادم رفض STARTTLS | `encryption: "ssl"` و `port: 465` |
| `MAIL FROM` يعلق | مصادقة غير متحققة | المحرك يصادق أولاً تلقائياً — تأكد أن `passwordEnv` مضبوط |
| `INTEGRITY CHECK FAILED` | تعديل ملف محمي | أعد نسخ الملف من الحزمة الأصلية، أو أعد التوقيع |
| لا إرسال رغم قوائم صحيحة | النطاق خارج `allowedDomains` | يُسجَّل `skipped` لا `failed` — وسّع النطاق أو صحّح القائمة |
| فشل فحص الرابط | رابط الهبوط غير موجود | انشر الصفحات أولاً أو استخدم `-SkipUrlChecks` للتجربة |

---

## 10) قائمة تحقّق قبل أول إرسال حقيقي

- [ ] `dryRun` نجح وأظهر الرسالة النموذجية بشكل صحيح.
- [ ] `fromEmail` = `smtp.username`، واسم المرسل صحيح.
- [ ] `physicalAddress` عنوان حقيقي، و `requireUnsubscribe` مفعّل.
- [ ] رابط الإلغاء يعمل ويوصل إلى صفحة فعلية.
- [ ] صفحة الهبوط تعمل، ورابط التتبّع فريد لكل مستلم.
- [ ] `allowedDomains` يطابق الجمهور الفعلي.
- [ ] القائمة موافقة صريحة (opt-in) وموثّقة.
- [ ] غيّرت بريدك وكلمة مروره قبل الحملة.
- [ ] تبدأ الجولة الأولى بأعداد صغيرة (`-MaxMessages 20`) للتأكد من الوصول.

---

## 11) تحذيرات مهمة

1. **الموافقة (opt-in) شرط.** القائمة المشتراة أو المجمّعة ليست أساساً قانونياً، وشرط `requireUnsubscribe` و `List-Unsubscribe` مفعّلان افتراضياً. لا تعطّلهما.
2. **سياسة مزوّد البريد.** مزوّدات السكني (Optimum / SuddenLink) تمنع البريد الجماعي غير المصرّح به وتطبّق عدم تسامح — الحساب أول ما يخسر.
3. **تدوير الـIP لا يغيّر ما يراه المزوّد.** تغيير عنوان جهازك يحسّن سمعتك أنت، لكنه لا يغيّر عنوان مرحل المزوّد الذي يراه مزوّد الاستقبال. الوصول إلى صندوق الوارد يعتمد على **سمعة نطاقك** (SPF/DKIM/DMARC + تدرّج في الإرسال) أكثر من أي شيء آخر.
4. **هذا البناء لا ينتحل ولا يخفي.** لا يدوّر نطاقاتك ولا يغشّ الترويسات؛ قياس النقرة على نطاقك أنت فقط.

---

## خريطة الملفات

```
MailRotator\
  Send-Mail.ps1              المحرك: يرسل، يدير التبديل، يكتب التقرير
  lib\                       Common, Client, Message, Smtp, Proxy, ProxyPool, State, Supervisor, Preflight, Integrity
  config\                    config.json, self-test.json, template.html, variant-2.html
  clients\<id>\             client.json + message.html  (ملف العميل)
  data\                      recipients.csv / recipients.txt / self-test.csv
  tools\                     Send-Campaign.ps1 (الباب), Run-MailRotator.ps1 (يطلب كلمة المرور),
                              Monitor-MailRotator.ps1, Test-Proxy.ps1, Protect-MailRotator.ps1
  tests\                     Test-Unit.ps1, Test-Integration.ps1, Test-Launcher.ps1, خوادم وهمية
  integrity\                 manifest.sig — التوقيع الذي يمنع التعديل
  logs\ state\ preview\    مخرجات التشغيل (لا تُنشر)
  guide\index.html           الدليل المصوّر الكامل
```
