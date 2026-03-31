# راهنمای فارسی BWLimiter

این پروژه برای کنترل پهنای باند روی پورت‌های سرور لینوکسی نوشته شده و از `tc` و `ifb` استفاده می‌کند. اگر روی سرور سرویس‌هایی مثل x-ui/xray دارید، می‌توانید برای پورت‌های inbound محدودیت سرعت آپلود و دانلود بگذارید.

## این ابزار چه کارهایی انجام می‌دهد؟

- محدود کردن سرعت بر اساس پورت
- جدا کردن محدودیت Upload و Download
- پشتیبانی از `tcp`، `udp` یا هر دو
- تعریف یک Rule برای چند پورت هم‌زمان
- شناسایی خودکار پورت‌های listening
- مدیریت کامل Rule: ساخت، ویرایش، فعال/غیرفعال، حذف
- اعمال خودکار Ruleها بعد از ریبوت (با systemd)
- مانیتور لحظه‌ای وضعیت `tc`
- ویزارد سریع برای راه‌اندازی اولیه

## نکته مهم قبل از استفاده

این پروژه «پورت‌محور» است، نه «کاربرمحور».

یعنی اگر چند کاربر VPN روی یک پورت مشترک باشند، محدودیت همان پورت بین همه آن کاربران مشترک می‌شود. برای محدودیت دقیق per-user باید معماری جداگانه (مثلا پورت جدا برای هر کاربر یا روش‌های mark/ip اختصاصی) پیاده شود.

## نصب سریع (توصیه‌شده)

```bash
curl -fsSL https://raw.githubusercontent.com/B3hnamR/BWLimiter/main/bootstrap.sh | sudo bash
```

این دستور:

- وابستگی‌ها را چک/نصب می‌کند
- اسکریپت را در `/usr/local/bin/limit-tc-port` نصب یا آپدیت می‌کند
- اگر `systemd` فعال باشد سرویس را هم آماده می‌کند
- در آخر منوی تعاملی را اجرا می‌کند

## نصب دستی

```bash
git clone https://github.com/B3hnamR/BWLimiter.git
cd BWLimiter
chmod +x limit-tc-port.sh install.sh
sudo ./install.sh
```

## استفاده روزمره

اجرای منو:

```bash
sudo limit-tc-port
```

گزینه‌های منوی اصلی:

- `[1]` Rules Studio
- `[2]` Inbound Discovery
- `[3]` Service Ops
- `[4]` Live Monitor
- `[5]` Maintenance Toolkit
- `[6]` Quick Wizard
- `[7]` Apply Active
- `[0]` Quit

## دستورات مستقیم CLI

```bash
sudo limit-tc-port --apply
sudo limit-tc-port --clear
sudo limit-tc-port --status
sudo limit-tc-port --list
sudo limit-tc-port --install-service
```

## مسیر فایل‌ها

- تنظیمات: `/etc/limit-tc-port/config`
- دیتابیس Ruleها: `/etc/limit-tc-port/rules.db`
- لاگ: `/var/log/limit-tc-port.log`

## مسیر پیشنهادی برای تنظیم روی سرور VPN

1. اول وارد `Inbound Discovery` شوید و پورت‌های فعال را ببینید.
2. در `Rules Studio` یک Rule بسازید.
3. برای تست اولیه، محدودیت را محافظه‌کارانه بگذارید (مثلا 10 تا 20 مگابیت).
4. گزینه `[7] Apply Active` را بزنید.
5. از `Live Monitor` خروجی کلاس‌ها را بررسی کنید.

## عیب‌یابی سریع

- اگر اثری نمی‌بینید، اول `Selected Interface` را چک کنید.
- اگر دانلود محدود نمی‌شود، وضعیت `ifb` را بررسی کنید.
- اگر بعد از ریبوت Ruleها نمی‌آیند، وضعیت سرویس را ببینید:

```bash
sudo systemctl status limit-tc-port.service
```

## محدودیت فعلی

فیلترهای پورت این نسخه روی IPv4 اعمال می‌شوند (`protocol ip` با `u32`).

## توسعه‌دهنده

Developed by: Behnam (`@b3hnamrjd`)
