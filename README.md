# ميدان الحي: الخادم

خادم الحسابات والبيانات لتطبيق ميدان الحي (Node.js + PostgreSQL، مع HTTPS تلقائي عبر Caddy).

## التثبيت على Ubuntu (أمر واحد)

```bash
curl -fsSL https://raw.githubusercontent.com/AxLo2001/maydan-server/main/install.sh | sudo bash
```

في آخر التثبيت يطبع رابط الخادم، مثل `https://203-0-113-5.sslip.io`. نفس الأمر يحدّث الخادم لاحقاً ويحافظ على البيانات.

## التثبيت على Windows Server (أمر واحد)

افتح PowerShell كمسؤول (Run as Administrator) والصق:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; [Net.ServicePointManager]::SecurityProtocol = 'Tls12'; iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/AxLo2001/maydan-server/main/install-windows.ps1'))
```

على Windows: الخادم يشتغل على المنفذ 3100 داخلياً (ما يلمس البرامج الثانية)، والملفات في `C:\maydan`، والنسخ الاحتياطية في `C:\maydan\backups`، وتغيير كلمة مرور مستخدم: `C:\maydan\maydan-password.ps1 user@email.com NewPass123`.

## أوامر مفيدة (Linux)

| الغرض | الأمر |
| --- | --- |
| حالة الخادم | `sudo systemctl status maydan` |
| آخر الرسائل | `sudo journalctl -u maydan -n 50` |
| تغيير كلمة مرور مستخدم | `sudo maydan-password user@email.com NewPass123` |
| النسخ الاحتياطية (يومياً، آخر 14 يوم) | `/var/backups/maydan` |

## الأمان

- كلمات المرور مشفرة بـ bcrypt داخل قاعدة البيانات.
- الأسرار (كلمة مرور قاعدة البيانات ومفتاح التوقيع) تُولَّد عند التثبيت في `/etc/maydan.env` ولا تُرفع هنا.
- قاعدة البيانات لا تقبل اتصالات من خارج الخادم.
- النقاط واحتلال الخلايا تُحسب داخل قاعدة البيانات، والتطبيق لا يقدر يكتب نقاط بنفسه.
