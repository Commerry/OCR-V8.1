# probe_db.py
import snap7
from snap7 import util
import sys

plc_ip = "10.31.182.13"   # เปลี่ยนเป็น IP ของคุณถ้าต่างกัน
db_num = 100              # เปลี่ยนเป็น DB ที่ต้องการทดสอบ
max_offset = 200          # จำนวนไบต์สูงสุดที่จะสแกน (ปรับเพิ่มได้)

c = snap7.client.Client()
try:
    c.connect(plc_ip, 0, 1)
    print("Connected to PLC", plc_ip)
except Exception as e:
    print("Failed to connect:", e)
    sys.exit(1)

for off in range(0, max_offset, 4):
    try:
        data = c.db_read(db_num, off, 4)
        try:
            val = util.get_real(data, 0)
            print(f"OK offset={off}: real={val}")
        except Exception:
            print(f"OK offset={off}: raw={data}")
    except Exception as e:
        print(f"ERROR offset={off}: {e}")
        break

c.disconnect()