# OCR Configuration System

ระบบการตั้งค่า OCR ที่มีระบบการจัดการผู้ใช้และสิทธิ์การเข้าถึง

## คุณสมบัติหลัก

### 🔐 ระบบรักษาความปลอดภัย
- ระบบเข้าสู่ระบบด้วยชื่อผู้ใช้และรหัสผ่าน
- การจัดการสิทธิ์ผู้ใช้ (Admin/User)
- Session management
- UI Lock สำหรับผู้ใช้ธรรมดา

### 🌐 การจัดการเครือข่าย
- ตั้งค่า IP แบบ DHCP หรือ Static IP
- การกำหนด Gateway และ DNS
- การสำรองและคืนค่าการตั้งค่าเครือข่าย
- ทดสอบการเชื่อมต่อเครือข่าย

### 👥 การจัดการผู้ใช้
- เพิ่ม/แก้ไข/ลบผู้ใช้ (เฉพาะ Admin)
- กำหนดสิทธิ์การเข้าถึง
- ดูประวัติการเข้าสู่ระบบ

### 📱 UI/UX ที่ทันสมัย
- Sidebar การตั้งค่าพร้อม tooltip
- Modal dialogs แบบ responsive
- Animation และ transition ที่ smooth
- การแสดงสถานะการ lock สำหรับ user ธรรมดา

## โครงสร้างโปรเจกต์

```
├── config/                 # ไฟล์การตั้งค่า
│   └── users.json          # ข้อมูลผู้ใช้และสิทธิ์
├── src/
│   ├── auth/               # ระบบการรักษาความปลอดภัย
│   │   └── AuthManager.js  # จัดการการยืนยันตัวตนและ session
│   ├── utils/
│   │   └── network/        # การจัดการเครือข่าย
│   │       └── NetworkManager.js
│   ├── index.html          # หน้าหลักของระบบ
│   ├── login.html          # หน้าเข้าสู่ระบบ
│   └── server.js           # เซิร์ฟเวอร์หลัก
├── python/                 # โมดูล OCR และ AI
├── public/                 # ไฟล์ static (CSS, JS, รูปภาพ)
└── docs/                   # เอกสารประกอบ
```

## การติดตั้งและใช้งาน

### 1. ติดตั้ง Dependencies
```bash
npm install
pip install -r requirements.txt
```

### 2. การตั้งค่าผู้ใช้เริ่มต้น
ระบบจะสร้างผู้ใช้เริ่มต้นดังนี้:

- **Admin**
  - Username: `Admin`
  - Password: `Abc123**`
  - Role: `admin`

- **User**
  - Username: `STA-SK`
  - Password: `Abc123**`
  - Role: `user`

### 3. การรันระบบ
```bash
npm run dev
```

เว็บไซต์จะเปิดที่ `http://localhost:64010`

## การใช้งาน

### สำหรับ Administrator
1. เข้าสู่ระบบด้วยบัญชี Admin
2. สามารถเข้าถึงทุกฟังก์ชัน:
   - ตั้งค่า OCR
   - ตั้งค่าเครือข่าย (🌐)
   - จัดการผู้ใช้ (👥)
   - ตั้งค่าระบบ (⚙️)

### สำหรับ User ธรรมดา
1. เข้าสู่ระบบด้วยบัญชี User
2. สามารถดูการตั้งค่าได้อย่างเดียว (Read-only)
3. Sidebar จะถูก lock และแสดงไอคอนกุญแจ 🔒

## การตั้งค่าเครือข่าย

### DHCP Mode
ระบบจะขอ IP อัตโนมัติจาก DHCP Server

### Static IP Mode
กำหนดค่าเครือข่ายดังนี้:
- IP Address: เช่น `192.168.1.100`
- Subnet Mask: เช่น `255.255.255.0`
- Gateway: เช่น `192.168.1.1`
- DNS Servers: เช่น `8.8.8.8, 8.8.4.4`

## การจัดการผู้ใช้

### เพิ่มผู้ใช้ใหม่
1. เข้าสู่หน้าจัดการผู้ใช้
2. คลิก "➕ เพิ่มผู้ใช้ใหม่"
3. กรอกข้อมูล:
   - ชื่อผู้ใช้
   - รหัสผ่าน
   - บทบาท (admin/user)

### แก้ไขผู้ใช้
1. คลิก "✏️ แก้ไข" ในแถวของผู้ใช้
2. แก้ไขข้อมูลที่ต้องการ
3. บันทึกการเปลี่ยนแปลง

## API Endpoints

### Authentication
- `POST /login` - เข้าสู่ระบบ
- `POST /logout` - ออกจากระบบ

### Network Management
- `GET /api/network/current` - ดูการตั้งค่าเครือข่ายปัจจุบัน
- `POST /api/network/configure` - ตั้งค่าเครือข่าย (Admin เท่านั้น)

### User Management
- `GET /api/users` - ดูรายชื่อผู้ใช้ (Admin เท่านั้น)
- `POST /api/users` - เพิ่มผู้ใช้ใหม่ (Admin เท่านั้น)
- `PUT /api/users/:username` - แก้ไขผู้ใช้ (Admin เท่านั้น)
- `DELETE /api/users/:username` - ลบผู้ใช้ (Admin เท่านั้น)

## ความปลอดภัย

- ระบบใช้ session-based authentication
- มีการตรวจสอบสิทธิ์ในทุก API endpoint
- การตั้งค่าเครือข่ายและการจัดการผู้ใช้จำกัดเฉพาะ Admin
- ระบบสำรองการตั้งค่าเครือข่ายอัตโนมัติ

## การพัฒนาต่อ

### เพิ่มฟีเจอร์ใหม่
1. สร้างไฟล์ใน `src/utils/` สำหรับ business logic
2. เพิ่ม API endpoint ใน `server.js`
3. อัปเดต UI ใน `index.html`

### การปรับแต่ง UI
- ไฟล์ CSS หลักอยู่ใน `src/assets/css/`
- ใช้ Tailwind CSS และ DaisyUI components
- ปรับแต่ง animation และ transition ในส่วน `<style>` ของ HTML

## การแก้ไขปัญหา

### ปัญหาการเชื่อมต่อเครือข่าย
1. ตรวจสอบการตั้งค่า netplan ใน `/etc/netplan/`
2. รันคำสั่ง `sudo netplan apply`
3. ตรวจสอบ interface ด้วย `ip addr show`

### ปัญหาการเข้าสู่ระบบ
1. ตรวจสอบไฟล์ `config/users.json`
2. ตรวจสอบ session timeout
3. ลบ cookies และลองใหม่

### ปัญหาสิทธิ์การเข้าถึง
1. ตรวจสอบ role ใน `config/users.json`
2. ตรวจสอบ middleware `requireAuth` ใน server.js

## License

MIT License - ดูไฟล์ LICENSE สำหรับรายละเอียด