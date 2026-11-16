# MAIL MOWAFAK — التشغيل على أي جهاز آخر

## 0) اسم البرنامج

الاسم **MAIL MOWAFAK** ومقفَل: هو جزء من حزمة موقّعة (RSA‑2048)، فمن يحاول تغييره
يجد أن البرنامج يرفض العمل (`INTEGRITY CHECK FAILED`). وهو **لا يظهر أبداً في الرسائل**:
كل رسالة تحمل هوية العميل الذي شُيّنت له.

## 1) ما الذي تحتاجه على الجهاز الآخر

| المتطلب | التفاصيل |
|---|---|
| ويندوز | Windows 10 أو 11 (64-bit) |
| PowerShell 5.1 | موجود أصلا مع ويندوز — لا يثبت شيء |
| Node.js | **لا يحتاج**: Node محمول داخل الحزمة (runtime/node.exe) |
| المتصفح | أي متصفح حديث (البرنامج يفتح اللوحة فيه تلقائيا) |
| المساحة | ~200 ميجابايت (Node 85 MB + المحرك + الواجهة) |

**لا يوجد تنصيب، ولا متطلبات، ولا حساب.**

## 2) النسخ

انسخ مجلد MailRotatorStudio كاملاً إلى الجهاز الآخر (فلاش، شبكة، أو أي وسيلة)،
بما فيه runtime/node.exe و engine.

## 3) التشغيل

انقر مرتين على **Start-Studio.cmd**.

- أول تشغيل: ينسخ محرك البريد إلى %LOCALAPPDATA%\MailRotatorStudio\project
- يفتح المتصفح على http://127.0.0.1:8931/dashboard تلقائيا
- اترك نافذة الأوامر مفتوحة أثناء العمل؛ إغلاقها يوقف البرنامج
- لإيقافه: Ctrl+C في النافذة

## 4) الإعداد الأول

1. **حدد مجلد المشروع** في أعلى اللوحة إن لم يكن معرفا:
   %LOCALAPPDATA%\MailRotatorStudio\project (اكتبه أو الصقه في الحقل)
2. **اضبط حساب البريد** في project\config\config.json:
   - smtp.provider: optimum (أو suddenlink / outlook / office365)
   - smtp.username: بريدك
   - message.fromEmail: **نفس بريدك بالضبط** (وإلا رفض المزود الرسالة)
   - message.physicalAddress: عنوانك البريدي (إلزامي)
   - message.allowedDomains: نطاقات جمهورك
3. **كلمة المرور** لا تكتب في أي ملف — تطلبها اللوحة عند الإرسال وتبقى في ذاكرة العملية فقط

## 5) الذكاء (AI Doctor)

- على جهازك الذي فيه MCode: يقرأ مفتاح MCode تلقائيا (نفس حسابك)
- على جهاز عميل: ضع مفتاح MiniMax في %APPDATA%\MailRotatorStudio\settings.json:

        { "aiKey": "sk-...", "aiModel": "MiniMax-M3.1-Flash" }

- بدون مفتاح: كل شيء يعمل، لكن الذكاء يتعامل مع الأخطاء المعروفة فقط
  (المعدل، الدفعة، منع العناوين، إيقاف عند فشل المصادقة)

## 6) محاكاة بدون إرسال حقيقي

للتجربة على جهاز فيه مزود سكني، وجه الإعداد إلى خادم SMTP محلي:

    # شغل خادما وهميا
    powershell -NoProfile -ExecutionPolicy Bypass -File .\engine\tests\FakeSmtpServer.ps1 -Port 2531 -LogPath $env:TEMP\fake.jsonl

    # ثم في config.json: smtp.host=127.0.0.1 , smtp.port=2531 , smtp.encryption=none

## 7) أين تحفظ البيانات

| المسار | المحتوى |
|---|---|
| %LOCALAPPDATA%\MailRotatorStudio\settings.json | الإعدادات ومفتاح الذكاء |
| %LOCALAPPDATA%\MailRotatorStudio\project | مجلد المشروع (المحرك + الإعدادات + السجلات) |

نقل المشروع إلى جهاز آخر = نسخ هذا المجلد.

## 8) حل المشاكل

| العَرَض | الحل |
|---|---|
| الصفحة لا تفتح | تأكد أن نافذة الأوامر ما زالت مفتوحة، ثم افتح http://127.0.0.1:8931/dashboard |
| المشروع غير صالح | تأكد أن المسار يحتوي Send-Mail.ps1 و config\config.json |
| خطأ 553 عند الإرسال | message.fromEmail مختلف عن smtp.username |
| خطأ 535 | كلمة المرور غير صحيحة للحساب |
| INTEGRITY CHECK FAILED | ملف محمي عدل — استبدله من نسخة engine الأصلية |
