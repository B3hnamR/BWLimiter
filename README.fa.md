# راهنمای فارسی BWLimiter

این پروژه برای کنترل پهنای باند روی پورت‌های سرور لینوکسی نوشته شده و از `tc` و `ifb` استفاده می‌کند. اگر روی سرور سرویس‌هایی مثل x-ui/xray دارید، می‌توانید برای پورت‌های inbound محدودیت سرعت آپلود و دانلود بگذارید.

## این ابزار چه کارهایی انجام می‌دهد؟

- محدود کردن سرعت بر اساس پورت
- جدا کردن محدودیت Upload و Download
- پشتیبانی از `tcp`، `udp` یا هر دو
- تعریف یک Rule برای چند پورت هم‌زمان
- شناسایی خودکار inboundها با اولویت پردازش‌های VPN (`xray`، `x-ui`، `sing-box`، `v2ray`)
- پشتیبانی از parse مستقیم دیتابیس/کانفیگ `MHSanaei/3x-ui` (در صورت موجود بودن)
- مدیریت کامل Rule: ساخت، ویرایش، فعال/غیرفعال، حذف
- زمان‌بندی پیشرفته سرعت (چند بازه برای هر Rule با اولویت)
- اعمال خودکار Ruleها بعد از ریبوت (با systemd)
- مانیتور لحظه‌ای وضعیت `tc`
- خروجی Debug Report برای عیب‌یابی سریع
- ویزارد سریع برای راه‌اندازی اولیه

برای شناسایی عمیق inboundها بهتر است `sqlite3` و `jq` هم روی سیستم نصب باشد (اختیاری).

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
- اگر `systemd` فعال باشد سرویس و تایمر زمان‌بندی را هم فعال می‌کند
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
- `[8]` Time Schedules
- `[0]` Quit

در بخش `Time Schedules` می‌توانید برای هر Rule چند پنجره زمانی تعریف کنید:

- روزها: `all` یا `weekday` یا `weekend` یا لیست روزها مثل `mon,tue,fri`
- بازه ساعت با پشتیبانی از عبور از نیمه‌شب (مثلا `23:00` تا `06:00`)
- اولویت برای تداخل بازه‌ها (هرکدام priority بالاتر داشته باشد اعمال می‌شود)

## دستورات مستقیم CLI

```bash
sudo limit-tc-port --apply
sudo limit-tc-port --tick
sudo limit-tc-port --clear
sudo limit-tc-port --status
sudo limit-tc-port --list
sudo limit-tc-port --list-schedules
sudo limit-tc-port --install-service
sudo limit-tc-port --debug-report
```

در منوی Maintenance هم گزینه `[8]` برای تولید گزارش عیب‌یابی اضافه شده و فایل را داخل `/tmp` ذخیره می‌کند.

برای اعمال خودکار تغییرات زمان‌بندی در طول روز، تایمر سیستم‌دی را هم فعال کنید:

```bash
sudo systemctl enable --now limit-tc-port-scheduler.timer
sudo systemctl status limit-tc-port-scheduler.timer
```

## مسیر فایل‌ها

- تنظیمات: `/etc/limit-tc-port/config`
- دیتابیس Ruleها: `/etc/limit-tc-port/rules.db`
- دیتابیس زمان‌بندی: `/etc/limit-tc-port/schedules.db`
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
