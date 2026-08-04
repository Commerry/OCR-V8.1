import snap7.client
from snap7 import util
from threading import Timer
from utils.log import log
import time
import traceback
from threading import Thread
from queue import Queue, Empty
import utils.redis as redis



class PLC:
    def __init__(self, camera_name, plc_address, db_num):
        self.r = redis.get_connection()
        self.camera_name = camera_name
        self.db_num = int(db_num)
        self.client_for_read = snap7.client.Client()
        self.client_for_write = snap7.client.Client()
        self.is_read_connected = False
        self.is_write_connected = False
        self.plc_address = plc_address

        
    def connect(self):
        # check connection state
        read_cpu = self.client_for_read.get_cpu_state()
        write_cpu = self.client_for_write.get_cpu_state()
        if self.is_read_connected and read_cpu != "S7CpuStatusRun":
            self.is_read_connected = False
            self.client_for_read.disconnect()

        if self.is_write_connected and write_cpu != "S7CpuStatusRun":
            self.is_write_connected = False
            self.client_for_write.disconnect()

        if not self.is_read_connected or not self.is_write_connected:
            log(f"not connect = read: {self.is_read_connected} write: {self.is_write_connected} | real_read: {self.client_for_read.get_connected()}, real_write: {self.client_for_write.get_connected()} | read_cpu: {self.client_for_read.get_cpu_state()} | write_cpu: {self.client_for_write.get_cpu_state()}")    

            self.r.publish("plc_status", f"{self.camera_name} CONNECTING_TO_PLC")
            
        while not self.is_read_connected:
            log(f"Connecting to PLC for read {self.camera_name}...")
            # redis publish
            # self.r.publish("plc_status", f"{self.camera_name} CONNECTING_TO_PLC")

            try:
                self.client_for_read.connect(self.plc_address, 0, 1)  # เชื่อมต่อ PLC
                log(f"Connected to PLC for read {self.camera_name}")
                # self.r.publish("plc_status", f"{self.camera_name} CONNECTED_TO_PLC")
                self.is_read_connected = True
                break
            except Exception as e:
                log(f"Failed to connect to PLC for read {self.camera_name}: {e}")
                self.r.publish("plc_status", f"{self.camera_name} CONNECTING_TO_PLC_ERROR")

                time.sleep(1)  # หยุด 1 วินาทีระหว่างการลองเชื่อมต่อใหม่
            
        while not self.is_write_connected:
            log(f"Connecting to PLC for write {self.camera_name}...")
            try:
                self.client_for_write.connect(self.plc_address, 0, 1)  # เชื่อมต่อ PLC
                log(f"Connected to PLC for write {self.camera_name}")
                # self.r.publish("plc_status", f"{self.camera_name} CONNECTED_TO_PLC")
                self.is_write_connected = True
                break
            except Exception as e:
                log(f"Failed to connect to PLC for write {self.camera_name}: {e}")
                self.r.publish("plc_status", f"{self.camera_name} CONNECTING_TO_PLC_ERROR")

                time.sleep(1)  # หยุด 1 วินาทีระหว่างการลองเชื่อมต่อใหม่

        if self.is_read_connected and self.is_write_connected:
            self.r.publish("plc_status", f"{self.camera_name} CONNECTED_TO_PLC")
        
        # log(f"read: {self.is_read_connected} write: {self.is_write_connected} | real_read: {self.client_for_read.get_connected()}, real_write: {self.client_for_write.get_connected()} | read_cpu: {self.client_for_read.get_cpu_state()} | write_cpu: {self.client_for_write.get_cpu_state()}")    
        

    def reconnect_for_read(self):
        self.is_read_connected = False
        self.client_for_read.disconnect()
        time.sleep(0.1)  # รอ PLC เคลียร์ connection นิดนึง
        self.connect()

    def reconnect_for_write(self):
        self.is_write_connected = False
        self.client_for_write.disconnect()
        time.sleep(0.1)  # รอ PLC เคลียร์ connection นิดนึง
        self.connect()

    def get_connected(self):
        return self.is_connected

    def is_ready_for_ocr(self):
        return self.read_bool(0, 0)
    

    def read_int(self, offset, size):
        try:
            self.connect()
            db = self.client_for_read.db_read(self.db_num, offset, size)
            current_buff = util.get_int(db, 0)
            # log(f"{self.camera_name}: read_int {offset} = {current_buff}")
            return current_buff
        except Exception as e:
            log(f"{self.camera_name}: Failed to read_int({e}) at {offset}", True)
            self.reconnect_for_read()
            traceback.print_exc()
    
    def write_int(self, offset, size, value):
        try:
            self.connect()
            log(f"{self.camera_name}: write_int {value} to {offset}")
            db = self.client_for_write.db_read(self.db_num, offset, size)
            updated_buff = util.set_int(db, 0, value)
            self.client_for_write.db_write(self.db_num, offset, updated_buff)
        except Exception as e:
            log(f"{self.camera_name}: Failed to write_int({e}) at {offset}", True)
            self.reconnect_for_write()
            traceback.print_exc()

    def read_real(self, offset):
        try:
            self.connect()
            db = self.client_for_read.db_read(self.db_num, offset, 4)
            current_buff = util.get_real(db, 0)
            return current_buff
        
        except Exception as e:
            log(f"{self.camera_name}: Failed to read_real({e}) at {offset}", True)
            self.reconnect_for_read()
            traceback.print_exc()

    def write_real(self, offset, value):
        try:
            self.connect()
            log(f"{self.camera_name}: write_real {value} to {offset}")
            db = self.client_for_write.db_read(self.db_num, offset, 4)
            updated_buff = util.set_real(db, 0, value)
            self.client_for_write.db_write(self.db_num, offset, updated_buff)
        except Exception as e:
            log(f"{self.camera_name}: Failed to write_real({e}) at {offset}", True)
            self.reconnect_for_write()
            traceback.print_exc()

    def read_bool(self, offset, index):
        try:
            self.connect()
            db = self.client_for_read.db_read(self.db_num, offset, index + 1)
            log(f"Read success: db value = {db} ")

            current_buff = util.get_bool(db, 0, index)
        
            return current_buff
        except Exception as e:
            log(f"{self.camera_name}: Failed to read_bool({e}) at {offset},{index} — {e}", True)
            self.reconnect_for_read()
            traceback.print_exc()

    def write_bool(self, offset, index, value):
        try:
            self.connect()
            log(f"{self.camera_name}: write_bool {value} to {offset},{index}")
            db = self.client_for_write.db_read(self.db_num, offset, index + 1)
            updated_buff = util.set_bool(db, 0, index, value)
            self.client_for_write.db_write(self.db_num, offset, updated_buff)
        except Exception as e:
            log(f"{self.camera_name}: Failed to write_bool({value}) at {offset},{index} — {e}", True)
            self.reconnect_for_write()
            traceback.print_exc()


    
    def write_ocr_result(self, result, conf):
        result_int = int(result)

        # ส่งเลข OCR ไปยัง offset 2
        self.write_int(2, 3, result_int)
        
        # ส่งค่า confidence (% ความเหมือนของโมเดล) ไปยัง offset 6 ทุกครั้ง
        if conf is not None:
            # แปลง confidence เป็นเปอร์เซ็นต์ (0.85 -> 85.0)
            confidence_percent = conf * 100.0
            self.write_real(6, confidence_percent)

        # TODO: หยุดการส่ง 888, 999 ชั่วคราว - จะกลับมาแก้ไขภายหลัง
        # if result_int == 888 or result_int == 999:
        #     self.write_bool(4, 0, True)
        #     s = Timer(5.0, self.auto_flip_not_found_status, ())
        #     s.start()

    def auto_flip_not_found_status(self):
        self.write_bool(4, 0, False)

    def write_camera_status(self, is_connected):
        self.write_bool(4, 1, not is_connected)


def PLCLoop(camera_name, plc_address, plc_db_num, queue_list):
    is_ready_queue: Queue = queue_list["is_ready"]
    write_queue: Queue = queue_list["write"]
    camera_status_queue: Queue = queue_list["camera_status"]

    client = PLC(camera_name, plc_address, plc_db_num)
    plc_weight_queue: Queue = None
    if "plc_weight" in queue_list:
        plc_weight_queue = queue_list["plc_weight"]

    while True:
        try:
            # 1. ตรวจสอบว่า PLC พร้อม OCR หรือยัง แล้วใส่ลง queue
            is_ready = client.is_ready_for_ocr()

            if is_ready_queue.full():
                is_ready_queue.get()
            is_ready_queue.put_nowait(is_ready)

           # 2. ถ้ามีข้อมูลรอเขียนจาก write_queue
            try:
                if not write_queue.empty():
                    write_data = write_queue.get_nowait()
                    print("write_data", write_data, flush=True)
                    if write_data:
                        # สมมุติ write_data = {"value": 123, "conf": 0.88}
                        client.write_ocr_result(write_data[0], write_data[1])
                        print("Write_success")
            except Exception as e:
                print(f"[{camera_name}] Write_data error: {e}", flush=True)

            # 3. ถ้ามีการอัปเดตสถานะกล้อง (เช่น online/offline)
            try:
                if not camera_status_queue.empty():
                    camera_status_data = camera_status_queue.get_nowait()
                    print("camera_status_data", camera_status_data, flush=True)
                    if camera_status_data is not None:
                        client.write_camera_status(camera_status_data)
                        print("write_camera_status__success")

            except Exception as e:
                print(f"[{camera_name}] Camera_status_data error: {e}", flush=True)

            # 4. อ่านค่าน้ำหนักจาก PLC (Real) ที่ offset 92 และส่งขึ้น redis ทุกๆ 0.5 วินาที
            try:
                now = time.time()
                # เก็บค่า last_weight_publish ไว้เป็น attribute อยู่นอก loop
                if not hasattr(PLCLoop, '_last_weight_publish'):
                    PLCLoop._last_weight_publish = 0
                if now - PLCLoop._last_weight_publish >= 0.5:
                    weight_val = client.read_real(92)
                    # weight_val อาจเป็น None เมื่ออ่านไม่สำเร็จ
                    if weight_val is not None:
                        # ส่งเป็นข้อความ "cameraName <value>" เพื่อให้โค้ดฝั่ง Node รับได้เหมือนกับ plc_status
                        client.r.publish("plc_weight", f"{camera_name} {weight_val}")
                        print(f"[{camera_name}] Published weight: {weight_val}", flush=True)
                        # also push latest weight into queue for main thread to overlay on frames
                        try:
                            if plc_weight_queue is not None:
                                if plc_weight_queue.full():
                                    _ = plc_weight_queue.get_nowait()
                                plc_weight_queue.put_nowait(weight_val)
                        except Exception:
                            pass
                    PLCLoop._last_weight_publish = now
            except Exception as e:
                print(f"[{camera_name}] Read weight error: {e}", flush=True)
        except Exception as e:
            print(f"[{camera_name}] Loop error: {e}")

        time.sleep(0.1)