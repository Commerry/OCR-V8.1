# อัพเดตโปรแกรม OCR บนกล้อง CM4

**2 คำสั่งจบ** — สคริปต์จัดการให้ทั้งหมด: ตั้งเวลา → เซ็ต proxy → ดาวน์โหลดโค้ดใหม่ → เคลียร์ pm2 เดิม → ติดตั้ง → ตั้ง auto-start → ตรวจผล
(ไม่แตะโฟลเดอร์โปรแกรมเก่า — ลบเองตามสะดวก)

---

## กรณีที่ 1: ไซต์ที่ต้องผ่าน proxy

```bash
curl -x http://10.201.0.54:3128 -sL -o /tmp/update.sh https://raw.githubusercontent.com/Commerry/OCR-V8.1/main/update.sh
bash /tmp/update.sh "2026-08-06 23:30:00" 10.201.0.54:3128
```

## กรณีที่ 2: ไซต์ที่ออกเน็ตตรงได้ (ไม่ต้อง proxy)

```bash
curl -sL -o /tmp/update.sh https://raw.githubusercontent.com/Commerry/OCR-V8.1/main/update.sh
bash /tmp/update.sh "2026-08-06 23:30:00"
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
