# อัพเดตโปรแกรม OCR บนกล้อง CM4

ลบโปรแกรมเก่า → ลงโค้ดใหม่จาก GitHub ทำตามลำดับ 1 → 4

---

## 1. ตั้ง proxy (ข้ามได้ถ้าไซต์นั้นออกเน็ตตรงได้)

```bash
PROXY="http://10.201.0.54:8080"
npm config set proxy "$PROXY"
npm config set https-proxy "$PROXY"
npm config set strict-ssl false
git config --global http.proxy "$PROXY"
git config --global https.proxy "$PROXY"
mkdir -p ~/.config/pip
printf '[global]\nproxy = %s\n' "$PROXY" > ~/.config/pip/pip.conf
echo "Acquire::http::Proxy \"$PROXY/\";
Acquire::https::Proxy \"$PROXY/\";" | sudo tee /etc/apt/apt.conf.d/95proxy
sudo sed -i 's|http://|https://|g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list
```

ตรวจ (ต้องได้ 200):

```bash
curl -sm 8 -o /dev/null -w "npm: %{http_code}\n" https://registry.npmjs.org/
```

---

## 2. เคลียร์ pm2 startup เดิม

```bash
pm2 delete all
pm2 save --force
sudo env PATH=$PATH:/usr/local/bin:$HOME/.npm-global/bin:$HOME/.local/bin \
  $(command -v pm2) unstartup systemd -u pi --hp /home/pi 2>/dev/null || pm2 unstartup systemd
pm2 kill
pkill -f main.py 2>/dev/null; true
```

---

## 3. ลบโปรแกรมเก่า

```bash
rm -rf ~/Desktop/OCR-V8.1
```

(ค่ากล้อง/บัญชีผู้ใช้จะกลับเป็นค่าเริ่มต้น — login ใหม่ด้วย `Admin` / `Abc123**`)

---

## 4. ลงโค้ดใหม่ + ติดตั้ง

```bash
cd ~/Desktop
git clone https://github.com/Commerry/OCR-V8.1.git
cd OCR-V8.1
npm install -g npm@10.9.2 2>&1 | tail -2
hash -r
bash install.sh
```

ตอบคำถามของ install.sh:

| คำถาม | ตอบ |
|---|---|
| Node.js v24.14.0 | **n** ถ้ามี node แล้ว / **y** ถ้ายังไม่มี |
| Redis reinstall? | **n** |
| Redis install now? | **y** |

ใกล้จบสคริปต์พิมพ์คำสั่ง `sudo env PATH=...` → copy ไปรัน 1 บรรทัด

เสร็จแล้วเช็ค:

```bash
pm2 status
curl -s -o /dev/null -w "web: %{http_code}\n" http://localhost:64010/login
```

`online` + `web: 200` = เสร็จ เปิดใช้ที่ `http://<IP กล้อง>:64010`
