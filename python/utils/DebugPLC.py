from threading import Timer
from utils.log import log
import utils.redis as redis
from threading import Thread
from queue import Queue, Empty
import time


counter = 0

class PLC:
    def __init__(self, camera_name, plc_address, db_num):
        self.camera_name = camera_name
        self.db_num = int(db_num)

        # connect redis
        self.r = redis.get_connection()



        # send CONNECTED
        self.r.publish("plc_status", f"{self.camera_name} CONNECTED_TO_PLC")





    def get_connected(self):
        return True

    def is_ready_for_ocr(self):
        return self.read_bool(0, 0)
    
    def read_int(self, offset, size):
        current_buff = 123
        log(f"{self.camera_name}: read_int {offset} = {current_buff}")
        return current_buff
    
    def write_int(self, offset, size, value):
        log(f"{self.camera_name}: write_int {value} to {offset}")

    def read_bool(self, offset, index):
        global counter
        counter += 1
        current_buff = counter % 10 == 0
        log(f"{self.camera_name}: read_bool {offset},{index} = {current_buff}")

        # send CONNECTED
        self.r.publish("plc_status", f"{self.camera_name} CONNECTED_TO_PLC")

        return current_buff
        
    def write_bool(self, offset, index, value):
        log(f"{self.camera_name}: write_bool {value} to {offset},{index}")

    def write_ocr_result(self, result, conf):
        result_int = int(result)
        
        if result_int == 0:
            self.write_bool(4, 0, True)
            s = Timer(5.0, self.auto_flip_not_found_status, ())
            s.start()
        else:
            self.write_int(2, 3, result_int)
            
    def auto_flip_not_found_status(self):
        self.write_bool(4, 0, False)

    def write_camera_status(self, is_connected):
        self.write_bool(4, 1, not is_connected)


def PLCLoop(camera_name, plc_address, plc_db_num, queue_list):
    is_ready_queue: Queue = queue_list["is_ready"]
    write_queue: Queue = queue_list["write"]
    camera_status_queue: Queue = queue_list["camera_status"]

    client = PLC(camera_name, plc_address, plc_db_num)

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

        except Exception as e:
            print(f"[{camera_name}] Loop error: {e}")

        time.sleep(0.1)