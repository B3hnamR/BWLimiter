# BWLimiter (Linux tc/ifb Port Bandwidth Manager)

اسکریپت عملی برای مدیریت پهنای باند پورت روی لینوکس با `tc` و `ifb`.

## قابلیت‌ها

- محدودسازی سرعت بر اساس پورت
- Upload و Download جداگانه
- پشتیبانی از `tcp`، `udp` یا `both`
- یک Rule روی چند پورت به‌صورت همزمان
- شناسایی خودکار inboundها (پورت‌های listening با `ss`)
- مدیریت Rule حرفه‌ای: ذخیره، ویرایش، فعال/غیرفعال، حذف
- تغییر سرعت Rule بدون حذف آن
- بازگشت خودکار تنظیمات بعد از reboot با `systemd`
- مانیتورینگ لحظه‌ای وضعیت `tc`
- Quick Wizard برای ساخت سریع Rule

## فایل‌ها

- `limit-tc-port.sh`: اسکریپت اصلی
- `bootstrap.sh`: نصب/آپدیت از GitHub + اجرای مستقیم منوی مدیریتی
- `install.sh`: نصب سریع روی سرور
- `systemd/limit-tc-port.service`: نمونه یونیت سرویس

## پیش‌نیاز

- Linux با دسترسی root
- `iproute2` (فرمان‌های `tc` و `ip`)
- `ss`
- `systemd`
- ماژول `ifb`

روی Debian/Ubuntu:

```bash
apt update
apt install -y iproute2 iproute2-doc
```

## نصب سریع

```bash
chmod +x limit-tc-port.sh install.sh
sudo ./install.sh
```

نصب/آپدیت و اجرای منو با `curl` (تک‌خطی):

```bash
curl -fsSL https://raw.githubusercontent.com/B3hnamR/BWLimiter/main/bootstrap.sh | sudo bash
```

یا نصب دستی:

```bash
sudo install -m 0755 ./limit-tc-port.sh /usr/local/bin/limit-tc-port
sudo /usr/local/bin/limit-tc-port --install-service
sudo systemctl enable --now limit-tc-port.service
```

## اجرا

منوی تعاملی:

```bash
sudo limit-tc-port
```

دستورات CLI:

```bash
sudo limit-tc-port --apply
sudo limit-tc-port --clear
sudo limit-tc-port --status
sudo limit-tc-port --list
sudo limit-tc-port --install-service
```

## مسیر ذخیره‌سازی

- تنظیمات: `/etc/limit-tc-port/config`
- دیتابیس Ruleها: `/etc/limit-tc-port/rules.db`
- لاگ: `/var/log/limit-tc-port.log`

## نکات Production

- `INTERFACE` را روی کارت شبکه درست تنظیم کنید (از منوی Maintenance).
- `LINK_CEIL` را نزدیک ظرفیت واقعی لینک بگذارید (مثلا `1000mbit`).
- بعد از هر تغییر مهم، `Apply enabled rules` اجرا کنید.
- با `systemctl status limit-tc-port.service` وضعیت سرویس را چک کنید.

## محدودیت فعلی

- فیلتر پورت‌ها با `tc u32` برای `protocol ip` اعمال می‌شود (IPv4).  
  در صورت نیاز، می‌توان نسخه IPv6 را با `flower` یا مسیر mark-based اضافه کرد.
