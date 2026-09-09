# อัพเดตโปรแกรม OCR บนกล้อง CM4

**2 คำสั่งจบ** — สคริปต์จัดการให้ทั้งหมด: ตั้งเวลา → เซ็ต proxy → ดาวน์โหลดโค้ดใหม่ → เคลียร์ pm2 เดิม → ติดตั้ง → ตั้ง auto-start → ตรวจผล
(ไม่แตะโฟลเดอร์โปรแกรมเก่า — ลบเองตามสะดวก)

---

## กรณีที่ 1: ไซต์ที่ต้องผ่าน proxy

```bash
curl -x http://10.201.0.54:8080 -sL -o /tmp/update.sh https://raw.githubusercontent.com/Commerry/OCR-V8.1/main/update.sh
bash /tmp/update.sh "2026-08-13 09:27:00" 10.201.0.54:8080
```
```bash
curl -x http://10.201.0.54:3128 -sL -o /tmp/update.sh https://raw.githubusercontent.com/Commerry/OCR-V8.1/main/update.sh
bash /tmp/update.sh "2026-08-13 09:28:00" 10.201.0.54:3128
```


## กรณีที่ 2: ไซต์ที่ออกเน็ตตรงได้ (ไม่ต้อง proxy)

```bash
curl -sL -o /tmp/update.sh https://raw.githubusercontent.com/Commerry/OCR-V8.1/main/update.sh
bash /tmp/update.sh "2026-08-10 14:45:00"
```

**สิ่งที่ต้องแก้ทุกครั้ง:** เวลาในเครื่องหมายคำพูด → ใส่**เวลาจริงขณะรัน** (`"ปี-เดือน-วัน ชม:นาที:วินาที"`)
ถ้าไม่ใส่เวลา สคริปต์จะไม่ทำงาน

---

## พอร์ต proxy ของแต่ละไซต์

| ไซต์ | proxy |
|---|---|
| ไซต์ A | `10.201.0.54:8080` |
| ไซต์ B | `10.201.0.54:3128` |

**ไม่รู้ว่าไซต์นี้ใช้พอร์ตอะไร** — สแกนหา:

```bash
for p in 3128 8080 8081 8000 80 8888; do
  timeout 4 bash -c "echo > /dev/tcp/10.201.0.54/$p" 2>/dev/null && echo "port $p OPEN" || echo "port $p closed"
done
```

เจอพอร์ตที่ `OPEN` → ทดสอบ (ได้ `200` หรือ `301` = ใช้ได้):

```bash
curl -x http://10.201.0.54:<PORT> -sm 10 -o /dev/null -w "%{http_code}\n" https://raw.githubusercontent.com/
```

**เช็คว่าไซต์นี้ต้องใช้ proxy ไหม** — ได้ `200` = ออกตรงได้ ใช้กรณีที่ 2:

```bash
curl -sm 8 -o /dev/null -w "direct: %{http_code}\n" https://raw.githubusercontent.com/
```

---

## ผลที่ต้องเห็นตอนจบ

```
UPDATE COMPLETE - ready to use
  http://<IP กล้อง>:64010
```

เปิดเบราว์เซอร์ตาม URL → login `Admin` / `Abc123**`

---

## ตรวจหลังอัพเดต

```bash
pm2 status                                    # ocr ต้อง online
pm2 logs ocr --lines 40 --nostream | grep -c "read_bool 0,0"   # >0 = รับทริกเกอร์จาก PLC ได้
```

---

## ปัญหาที่พบบ่อย

| อาการ | ทางแก้ |
|---|---|
| `UPDATE FAILED` | ดู error: `pm2 logs ocr --lines 30` |
| curl ค้าง / โหลดไฟล์ไม่ได้ | พอร์ต proxy ผิด → สแกนพอร์ตตามหัวข้อด้านบน |
| `Address out of range` (อ่านน้ำหนัก) | ไซต์นั้น PLC ไม่มีช่องน้ำหนัก — ไม่กระทบการทำงาน ช่อง Weight บนเว็บขึ้น `--` |
| npm ล้มกลางทาง | รันสคริปต์ซ้ำอีกครั้ง (ของที่โหลดแล้วอยู่ใน cache) |


---

## อัปเดตกล้องหลายตัวพร้อมกัน (`update-fleet.sh`)

ใช้เมื่อกล้องติดตั้งโปรแกรมไว้แล้ว (มี `.git` ในโฟลเดอร์) ต้องการแค่ดึงโค้ดใหม่ + รีสตาร์ต

รันจากเครื่องไหนก็ได้ที่ ssh ถึงกล้องได้ (เครื่อง Center, โน้ตบุ๊ก, กล้องตัวใดตัวหนึ่ง):

```bash
cd ~/Desktop/OCR-V8.1
git pull                                    # เอาสคริปต์เวอร์ชันล่าสุดมาก่อน
bash update-fleet.sh 10.1.100.61 10.1.100.62 10.1.100.63
```

**ระบุรายชื่อกล้องได้ 3 แบบ**

| แบบ | คำสั่ง |
|---|---|
| พิมพ์ IP ต่อท้าย | `bash update-fleet.sh 10.1.100.61 10.1.100.62` |
| ไฟล์รายชื่อ (บรรทัดละ 1 IP, `#` = คอมเมนต์) | `bash update-fleet.sh -f cameras.txt` |
| ดึง IP จากฐานข้อมูล Center เอง | `bash update-fleet.sh --from-db ~/Desktop/OCR-Center-main` |

**ตัวเลือกที่ใช้บ่อย**

| ตัวเลือก | ความหมาย | ค่าเริ่มต้น |
|---|---|---|
| `-u USER` | ผู้ใช้ ssh | `pi` |
| `-p PASSWORD` | รหัสผ่าน ssh (ต้องมี `sshpass`) | ใช้ ssh key |
| `-d DIR` | โฟลเดอร์โปรแกรมบนกล้อง | `~/Desktop/OCR-V8.1` |
| `-n NAME` | ชื่อ process ใน pm2 | `ocr` |
| `-j N` | อัปพร้อมกันกี่ตัว | `4` |
| `--dry-run` | แสดงคำสั่งที่จะรัน โดยยังไม่รันจริง | - |

ตัวอย่างครบ (รหัสผ่าน + ดึงรายชื่อจาก Center + ทีละ 2 ตัว):

```bash
sudo apt install -y sshpass          # ครั้งแรกครั้งเดียว
bash update-fleet.sh --from-db ~/Desktop/OCR-Center-main -u pi -p raspberry -j 2
```

**สิ่งที่สคริปต์ทำบนกล้องแต่ละตัว**

1. `git fetch origin main` — ถ้าติด certificate (proxy ตัดกลาง SSL) จะลองใหม่แบบข้ามการตรวจ cert ให้เอง
2. `git reset --hard origin/main` — ทับเฉพาะไฟล์โค้ด `config.json` รูปที่เก็บไว้ และ pm2 startup ไม่ถูกแตะ
3. `pm2 restart ocr`
4. รายงานคอมมิตที่ได้ + สถานะ pm2

จบแล้วสรุปท้ายจอว่าอัปสำเร็จกี่ตัว ล้มกี่ตัว พร้อม log 6 บรรทัดสุดท้ายของตัวที่ล้ม

**ข้อความที่อาจเจอ**

| ข้อความ | ความหมาย |
|---|---|
| `SKIP: ... is not a git clone` | กล้องตัวนั้นติดตั้งจาก ZIP ต้องต่อ git ให้ครั้งเดียวก่อน (ดูหัวข้อ "ต่อ git กับโฟลเดอร์เดิม") |
| `fetch failed, retrying without certificate check` | proxy ตัดกลาง SSL — สคริปต์ลองใหม่ให้เองแล้ว ไม่ต้องทำอะไร |
| `FETCH FAILED:` | เน็ตไปไม่ถึง GitHub — ตั้ง proxy บนกล้องตัวนั้นก่อน |

### ต่อ git กับโฟลเดอร์เดิม (กรณีติดตั้งจาก ZIP)

ทำครั้งเดียวต่อเครื่อง ข้อมูลและ config เดิมอยู่ครบ:

```bash
cd ~/Desktop/OCR-V8.1
git init
git remote add origin https://github.com/Commerry/OCR-V8.1.git
git fetch origin main
git reset --hard origin/main
git branch -M main
git branch -u origin/main main
pm2 restart ocr
```
