# Installation Script Usage Guide

## สคริปต์สำหรับติดตั้งบน Linux

มี 2 สคริปต์สำหรับการติดตั้ง:

### 1. install.sh (แบบมี User Interaction)
สคริปต์นี้จะถามคำถามระหว่างติดตั้ง เหมาะสำหรับการติดตั้งครั้งแรก

```bash
# ให้สิทธิ์ execute
chmod +x install.sh

# รันสคริปต์
./install.sh
```

**ขั้นตอนการรัน:**
1. สคริปต์จะตรวจสอบ Node.js ถ้ายังไม่มีหรือ version ไม่ตรง จะถามว่าต้องการติดตั้งหรือไม่
2. ถ้าตอบ 'y' จะติดตั้ง Node.js จากไฟล์ `node-v24.14.0-linux-arm64.tar.xz` (ต้องมีในโฟลเดอร์เดียวกัน)
3. ติดตั้ง dependencies และ build โปรเจกต์
4. เมื่อถึงขั้นตอน PM2 startup จะแสดงคำสั่งที่ต้องรันด้วย sudo
5. คัดลอกคำสั่งนั้นแล้วรันในหน้าต่างใหม่ด้วย sudo
6. กลับมาที่สคริปต์แล้วกด 'y' เพื่อดำเนินการต่อ
7. สคริปต์จะทำ pm2 save อัตโนมัติ

---

### 2. install-auto.sh (แบบอัตโนมัติเต็มที่) ⭐ แนะนำ
สคริปต์นี้จะติดตั้งแบบอัตโนมัติโดยไม่ถามคำถาม

```bash
# ให้สิทธิ์ execute
chmod +x install-auto.sh

# รันสคริปต์
./install-auto.sh
```

**สคริปต์จะติดตั้ง Node.js อัตโนมัติ** หากยังไม่มีหรือ version ไม่ตรง โดยใช้ไฟล์ `node-v24.14.0-linux-arm64.tar.xz`

**หมายเหตุ:** หลังจากรันเสร็จ ถ้าต้องการให้แอพพลิเคชันเปิดอัตโนมัติเมื่อ boot ระบบ ให้รันคำสั่ง:
```bash
pm2 startup
# แล้วรันคำสั่งที่แสดงด้วย sudo
pm2 save
```

---

## ติดตั้ง Node.js แบบออฟไลน์

สคริปต์จะติดตั้ง Node.js v24.14.0 อัตโนมัติจากไฟล์:
- ชื่อไฟล์: `node-v24.14.0-linux-arm64.tar.xz`
- ต้องวางไฟล์นี้ในโฟลเดอร์เดียวกันกับสคริปต์

**การติดตั้ง Node.js:**
- จะติดตั้งไปที่ `$HOME/.local/`
- จะเพิ่ม PATH ใน `~/.bashrc` อัตโนมัติ
- หลังติดตั้งเสร็จต้อง reload shell: `source ~/.bashrc` หรือเปิด terminal ใหม่

**ถ้าต้องการดาวน์โหลด Node.js:**
```bash
# ดาวน์โหลดจาก official site (ARM64 สำหรับ Raspberry Pi)
wget https://nodejs.org/dist/v24.14.0/node-v24.14.0-linux-arm64.tar.xz

# หรือใช้ curl
curl -O https://nodejs.org/dist/v24.14.0/node-v24.14.0-linux-arm64.tar.xz
```

---

## สิ่งที่สคริปต์จะทำ

0. ✅ ตรวจสอบและติดตั้ง Node.js v24.14.0 (ถ้าจำเป็น)
1. ✅ ล้าง npm cache
2. ✅ ติดตั้ง dependencies
3. ✅ ให้สิทธิ์ execute กับ node modules
4. ✅ Build โปรเจกต์
5. ✅ ติดตั้ง PM2 (ถ้ายังไม่มี)
6. ✅ เคลียร์ PM2 processes เก่า
7. ✅ เริ่มต้นแอพพลิเคชันด้วย PM2
8. ✅ บันทึกการตั้งค่า PM2

---

## คำสั่ง PM2 ที่เป็นประโยชน์

```bash
# ดูสถานะ
pm2 status

# ดู logs
pm2 logs ocr

# Restart แอพ
pm2 restart ocr

# หยุดแอพ
pm2 stop ocr

# ลบแอพออกจาก PM2
pm2 delete ocr

# Monitor real-time
pm2 monit

# ดูข้อมูลละเอียด
pm2 show ocr
```

---

## Troubleshooting

### ถ้าเจอ Permission Denied
```bash
chmod +x install.sh
# หรือ
chmod +x install-auto.sh
```

### ถ้า PM2 ยังไม่ติดตั้ง
```bash
sudo npm install -g pm2
```

### ถ้าต้องการติดตั้งใหม่ทั้งหมด
```bash
# ลบ node_modules เก่า
rm -rf node_modules package-lock.json

# รันสคริปต์ติดตั้งใหม่
./install-auto.sh
```

### ถ้า Build ล้มเหลว
ตรวจสอบว่า:
- มี Node.js version ที่รองรับ (แนะนำ v18 หรือสูงกว่า)
- มี Python สำหรับ build native modules
- มี build-essential สำหรับ Linux

```bash
# ติดตั้ง build tools
sudo apt-get install build-essential python3
```

---

## Requirements

- Node.js v18 หรือสูงกว่า
- npm v8 หรือสูงกว่า
- Linux OS (Ubuntu, Debian, Raspberry Pi OS, etc.)
- sudo access (สำหรับติดตั้ง PM2)
