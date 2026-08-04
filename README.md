# OCR Configuration System with User Management & Network Settings

ระบบการตั้งค่า OCR ที่ทันสมัยพร้อมระบบจัดการผู้ใช้และการตั้งค่าเครือข่าย

## 🌟 คุณสมบัติหลัก

### 🔐 ระบบรักษาความปลอดภัย

- ระบบเข้าสู่ระบบด้วยชื่อผู้ใช้และรหัสผ่าน
- การจัดการสิทธิ์ผู้ใช้ (Administrator/User)
- Session-based authentication
- UI Lock สำหรับผู้ใช้ธรรมดา (Read-only mode)

### 🌐 การจัดการเครือข่าย (Admin เท่านั้น)

- ตั้งค่า IP แบบ DHCP หรือ Static IP
- การกำหนด Gateway และ DNS
- การสำรองและคืนค่าการตั้งค่าเครือข่าย
- ทดสอบการเชื่อมต่อเครือข่าย

### 👥 การจัดการผู้ใช้ (Admin เท่านั้น)

- เพิ่ม/แก้ไข/ลบผู้ใช้
- กำหนดสิทธิ์การเข้าถึง
- ดูประวัติการเข้าสู่ระบบ

### 📱 UI/UX ที่ทันสมัย

- Sidebar การตั้งค่าพร้อม tooltip
- Modal dialogs แบบ responsive
- Animation และ transition ที่ smooth
- การแสดงสถานะการ lock สำหรับ user ธรรมดา

## 🚀 การติดตั้งและใช้งาน

### สำหรับ Windows

1. **ติดตั้ง Prerequisites:**

   - Python version 3.10.14
   - Node.js 20.14.0
   - Redis Server จาก https://github.com/tporadowski/redis/releases

2. **ติดตั้ง Dependencies:**

   ```bash
   pip install -r requirements.txt
   npm install
   ```

3. **การตั้งค่า:**

   - แก้ไขไฟล์ `.env` ให้ถูกต้อง:
     ```
     PORT=64010
     PYTHON_EXE=python
     NODE_ENV=production
     ```

4. **รันระบบ:**

   ```bash
   # สำหรับพัฒนา
   npm run dev

   # สำหรับ production
   npm run build
   npm run start
   ```

### สำหรับ Linux

1. **ติดตั้ง Prerequisites:**

   - Python version 3.10.14
   - Node.js 20.14.0
   - Redis Server: https://www.digitalocean.com/community/tutorials/how-to-install-and-secure-redis-on-ubuntu-20-04

2. **ติดตั้ง Dependencies:**

   ```bash
   pip install -r requirements.txt
   npm install
   npm i -g pm2
   ```

3. **การตั้งค่า:**

   - แก้ไขไฟล์ `.env`:
     ```
     PORT=64010
     PYTHON_EXE=python3
     NODE_ENV=production
     ```

4. **รันระบบ:**
   ```bash
   npm run build
   pm2 start ecosystem.config.js --env=production
   pm2 startup
   pm2 save
   ```

### การเข้าใช้งาน

เว็บไซต์จะเปิดที่: `http://localhost:64010`

**สำหรับ Administrator:**

```
Username: Admin
Password: Abc123**
```

**สำหรับ User:**

```
Username: STA-SK
Password: Abc123**
```

## 📋 สิทธิ์การเข้าถึง

### 🔑 Administrator

- ✅ ดูและแก้ไขการตั้งค่า OCR
- ✅ ตั้งค่าเครือข่าย (🌐)
- ✅ จัดการผู้ใช้ (👥)
- ✅ เข้าถึงการตั้งค่าระบบ (⚙️)

### 👤 User ธรรมดา

- ✅ ดูการตั้งค่า OCR (Read-only)
- ✅ ดู Live preview และผลลัพธ์ OCR
- ❌ แก้ไขการตั้งค่าใดๆ
- ❌ เข้าถึงการตั้งค่าเครือข่าย
- ❌ จัดการผู้ใช้อื่น

## 🗂️ โครงสร้างโปรเจกต์

```
📁 OCR-NEW/
├── 📁 config/                 # ไฟล์การตั้งค่า
│   └── 📄 users.json          # ข้อมูลผู้ใช้และสิทธิ์
├── 📁 src/
│   ├── 📁 auth/               # ระบบการรักษาความปลอดภัย
│   │   └── 📄 AuthManager.js  # จัดการการยืนยันตัวตนและ session
│   ├── 📁 utils/
│   │   └── 📁 network/        # การจัดการเครือข่าย
│   │       └── 📄 NetworkManager.js
│   ├── 📄 index.html          # หน้าหลักของระบบ
│   ├── 📄 login.html          # หน้าเข้าสู่ระบบ
│   └── 📄 server.js           # เซิร์ฟเวอร์หลัก
├── 📁 python/                 # โมดูล OCR และ AI
├── 📁 public/                 # ไฟล์ static (CSS, JS, รูปภาพ)
├── 📁 docs/                   # เอกสารประกอบ
│   ├── 📄 README.md           # คู่มือหลัก
│   ├── 📄 USER_GUIDE.md       # คู่มือการจัดการผู้ใช้
│   └── 📄 NETWORK_GUIDE.md    # คู่มือการตั้งค่าเครือข่าย
└── 📄 package.json
```

## 🎯 การใช้งานระบบ

### สำหรับ Administrator

1. **เข้าสู่ระบบ** ด้วยบัญชี Admin
2. **ตั้งค่า OCR** - กำหนดพารามิเตอร์ทั้งหมด
3. **ตั้งค่าเครือข่าย** - คลิก 🌐 เพื่อเปลี่ยน IP
4. **จัดการผู้ใช้** - คลิก 👥 เพื่อเพิ่ม/แก้ไข/ลบผู้ใช้

### สำหรับ User ธรรมดา

1. **เข้าสู่ระบบ** ด้วยบัญชี User
2. **ดูการตั้งค่า** - เฉพาะโหมดดูอย่างเดียว
3. **ติดตาม OCR** - ดูผลลัพธ์และ live preview

## 🔧 การตั้งค่าเครือข่าย

### DHCP Mode (อัตโนมัติ)

ระบบจะขอ IP อัตโนมัติจาก DHCP Server

### Static IP Mode (กำหนดเอง)

ตัวอย่างการตั้งค่า:

```
IP Address: 192.168.1.100
Subnet Mask: 255.255.255.0
Gateway: 192.168.1.1
DNS Servers: 8.8.8.8, 8.8.4.4
```

## 📡 API Endpoints

### Authentication

- `POST /login` - เข้าสู่ระบบ
- `POST /logout` - ออกจากระบบ

### Network Management (Admin Only)

- `GET /api/network/current` - ดูการตั้งค่าเครือข่ายปัจจุบัน
- `POST /api/network/configure` - ตั้งค่าเครือข่าย

### User Management (Admin Only)

- `GET /api/users` - ดูรายชื่อผู้ใช้
- `POST /api/users` - เพิ่มผู้ใช้ใหม่
- `PUT /api/users/:username` - แก้ไขผู้ใช้
- `DELETE /api/users/:username` - ลบผู้ใช้

## 🛡️ ความปลอดภัย

- ✅ Session-based authentication
- ✅ Role-based access control (RBAC)
- ✅ API endpoint protection
- ✅ Network configuration backup
- ✅ Input validation and sanitization

## 📚 เอกสารเพิ่มเติม

- [📖 คู่มือการจัดการผู้ใช้](docs/USER_GUIDE.md)
- [🌐 คู่มือการตั้งค่าเครือข่าย](docs/NETWORK_GUIDE.md)

## 🔧 การพัฒนาต่อ

### เพิ่มฟีเจอร์ใหม่

1. สร้างไฟล์ใน `src/utils/` สำหรับ business logic
2. เพิ่ม API endpoint ใน `server.js`
3. อัปเดต UI ใน `index.html`

### การปรับแต่ง UI

- ไฟล์ CSS หลักอยู่ใน `src/assets/css/`
- ใช้ Tailwind CSS และ DaisyUI components
- ปรับแต่ง animation และ transition ในส่วน `<style>` ของ HTML

## 🐛 การแก้ไขปัญหา

### ปัญหาการเชื่อมต่อเครือข่าย

```bash
# ตรวจสอบการตั้งค่า
ip addr show
sudo netplan apply

# ทดสอบการเชื่อมต่อ
ping google.com
```

### ปัญหาการเข้าสู่ระบบ

1. ตรวจสอบไฟล์ `config/users.json`
2. ลบ cookies และลองใหม่
3. รีสตาร์ทเซิร์ฟเวอร์

## 📝 License

MIT License - ดูไฟล์ LICENSE สำหรับรายละเอียด

---

**🎉 ระบบพร้อมใช้งาน!** เข้าใช้งานได้ที่ `http://localhost:64010`

_สร้างโดย: STA-SK Development Team | 2025_
