# راهنمای فارسی BWLimiter

این پروژه برای مدیریت پهنای باند روی سرور لینوکسی ساخته شده و از `tc` و `ifb` استفاده می‌کند. هدفش این است که بدون پیچیدگی اضافه، بتوانی روی پورت‌های سرویس‌ات محدودیت دقیق بگذاری، زمان‌بندی تعریف کنی، و بعد از ریبوت هم همه چیز خودکار بالا بیاید.

نسخه انگلیسی: `README.md`

---

## 1) این ابزار دقیقاً چه کاری انجام می‌دهد؟

با BWLimiter می‌توانی:

- برای هر پورت، سرعت Upload و Download جدا تعریف کنی
- روی چند پورت با یک Rule محدودیت بگذاری
- برای `tcp`، `udp` یا هر دو Rule بسازی
- Ruleها را ذخیره، ویرایش، فعال/غیرفعال یا حذف کنی
- محدودیت‌های زمانی تعریف کنی (مثلاً صبح کم، شب زیاد)
- همه تنظیمات را با `systemd` بعد از ریبوت خودکار برگردانی
- وضعیت `tc` را زنده ببینی و گزارش Debug بگیری

---

## 2) قابلیت‌ها به زبان ساده

| بخش | خروجی |
|---|---|
| کنترل ترافیک | محدودیت بر پایه پورت با `tc`/`ifb` |
| Rule Management | ساخت، ویرایش، حذف، فعال/غیرفعال، اعمال مجدد |
| تشخیص Inbound | تشخیص هوشمند با اولویت محیط VPN/3x-ui |
| زمان‌بندی | تعداد نامحدود پنجره زمانی برای هر Rule |
| ایمنی | Conflict Guard + محافظت پورت‌های حیاتی + Safe Apply با Snapshot/Rollback |
| مانیتورینگ | مشاهده زنده کلاس‌ها + گزارش کامل عیب‌یابی |
| اتوماسیون | سرویس اصلی + تایمر هر دقیقه برای بررسی زمان‌بندی |

---

## 3) ترتیب تشخیص پورت‌ها

برای اینکه پورت‌های مهم‌تر زودتر و دقیق‌تر پیدا شوند، اسکریپت این ترتیب را رعایت می‌کند:

1. دیتابیس 3x-ui (`x-ui.db`)
2. فایل کانفیگ xray (`config.json`)
3. پردازش‌های VPN (`xray`, `x-ui`, `sing-box`, `v2ray`)
4. همه پورت‌های listening سیستم

به همین خاطر روی سرورهای 3x-ui معمولاً خروجی دقیق‌تری می‌گیری.

---

## 4) پیش‌نیازها

الزامی:

- Linux
- دسترسی root یا `sudo`
- `iproute2` (`tc`, `ip`, `ss`)
- `kmod` (`modprobe`)
- `systemd` (برای اجرای خودکار)

پیشنهادی:

- `sqlite3`
- `jq`

---

## 5) نصب

### 5.1 نصب سریع (پیشنهادی)

```bash
curl -fsSL https://raw.githubusercontent.com/B3hnamR/BWLimiter/main/bootstrap.sh | sudo bash
```

این روش:

1. وابستگی‌ها را نصب می‌کند
2. اسکریپت را در `/usr/local/bin/limit-tc-port` آپدیت می‌کند
3. فایل‌های سرویس/تایمر را می‌سازد
4. سرویس اصلی و تایمر زمان‌بندی را فعال می‌کند
5. منوی تعاملی را اجرا می‌کند

### 5.2 نصب دستی

```bash
git clone https://github.com/B3hnamR/BWLimiter.git
cd BWLimiter
chmod +x limit-tc-port.sh install.sh
sudo ./install.sh
```

---

## 6) نقشه منوی تعاملی

اجرا:

```bash
sudo limit-tc-port
```

منوی اصلی:

- `[1]` Rules Studio
- `[2]` Inbound Discovery
- `[3]` Service Ops
- `[4]` Live Monitor
- `[5]` Maintenance Toolkit
- `[6]` Quick Wizard
- `[7]` Apply Active
- `[8]` Time Schedules
- `[0]` Quit

بخش‌های مهم:

- `Service Ops`: مدیریت سرویس اصلی + تایمر زمان‌بندی
- `Maintenance Toolkit`: انتخاب اینترفیس، تنظیم IFB، گزارش Debug، Safe Apply، بررسی Conflict، Snapshot/Rollback
- `Time Schedules`: تعریف پنجره‌های زمانی روی Ruleها

---

## 7) زمان‌بندی پیشرفته (بخش ویژه)

هر پنجره زمانی این اطلاعات را دارد:

- `rule_id`
- روزها (`all` / `weekday` / `weekend` / `mon,tue,...`)
- ساعت شروع و پایان (`HH:MM`)
- سرعت‌های `down/up` و `burst`
- `priority` برای وقتی چند پنجره همزمان فعال باشند

رفتار سیستم:

- اگر پنجره‌ای فعال باشد، سرعت همان پنجره اعمال می‌شود
- اگر هیچ پنجره‌ای فعال نباشد، سرعت پایه Rule برمی‌گردد
- بازه عبوری از نیمه‌شب هم پشتیبانی می‌شود (`23:00` تا `06:00`)
- برای هر Rule می‌توانی 3 پنجره، 10 پنجره یا بیشتر تعریف کنی

---

## 8) دستورات CLI

```bash
sudo limit-tc-port --apply
sudo limit-tc-port --safe-apply
sudo limit-tc-port --tick
sudo limit-tc-port --clear
sudo limit-tc-port --status
sudo limit-tc-port --list
sudo limit-tc-port --list-schedules
sudo limit-tc-port --conflict-check
sudo limit-tc-port --list-snapshots
sudo limit-tc-port --rollback-latest
sudo limit-tc-port --rollback-snapshot <snapshot_id>
sudo limit-tc-port --install-service
sudo limit-tc-port --debug-report
sudo limit-tc-port --help
```

توضیح سریع:

- `--apply`: اعمال فوری تنظیمات موثر فعلی
- `--safe-apply`: قبل از Apply از تنظیمات Snapshot می‌گیرد و در صورت خطا rollback می‌کند
- `--tick`: فقط در صورت تغییر واقعی زمان‌بندی دوباره apply می‌کند
- `--conflict-check`: تداخل Ruleها و ریسک پورت‌های محافظت‌شده را قبل از Apply بررسی می‌کند
- `--rollback-*`: بازگردانی تنظیمات از Snapshotهای قبلی
- `--debug-report`: گزارش کامل در `/tmp` می‌سازد

---

## 9) مدیریت systemd

سرویس اصلی:

```bash
sudo systemctl enable --now limit-tc-port.service
sudo systemctl status limit-tc-port.service
```

تایمر زمان‌بندی:

```bash
sudo systemctl enable --now limit-tc-port-scheduler.timer
sudo systemctl status limit-tc-port-scheduler.timer
```

مدل اجرا:

- سرویس اصلی چرخه `apply/clear` را مدیریت می‌کند
- تایمر هر دقیقه `--tick` را اجرا می‌کند

---

## 10) مسیر فایل‌ها

- تنظیمات: `/etc/limit-tc-port/config`
- دیتابیس Ruleها: `/etc/limit-tc-port/rules.db`
- دیتابیس زمان‌بندی: `/etc/limit-tc-port/schedules.db`
- وضعیت اجرایی: `/run/limit-tc-port/`
- لاگ: `/var/log/limit-tc-port.log`

---

## 11) سناریوی شروع سریع (عملی)

1. از `Rules Studio` یک Rule برای پورت سرویس‌ات بساز (مثلاً `8080`).
2. سرعت پایه بده (مثلاً حدود 3MB/s برابر `24576` kbit).
3. گزینه `Apply Active` را بزن.
4. وارد `Time Schedules` شو و چند پنجره زمانی بساز:
   - ساعات کاری: کمتر
   - عصر: متوسط
   - نیمه‌شب: بیشتر
5. تایمر را از `Service Ops` فعال کن.

---

## 12) عیب‌یابی

گزارش بگیر:

```bash
sudo limit-tc-port --debug-report
```

گزارش را ببین:

```bash
cat /tmp/limit-tc-port-debug-*.log
```

اول این موارد را چک کن:

1. اینترفیس انتخابی درست باشد
2. بعد از Apply، IFB بالا آمده باشد
3. سرویس و تایمر فعال باشند
4. Rule و Scheduleهای موردنظر فعال باشند
5. منبع تشخیص Inbound منطقی باشد (`3xui-db`, `xray-config`, ...)

---

## 13) محدوده فعلی پروژه

- مسیر فیلترینگ فعلی روی IPv4 متمرکز است (`protocol ip` + `u32`).
- محدودسازی این پروژه per-port است، نه per-user واقعی.

---

Developed by: Behnam (`@b3hnamrjd`)
