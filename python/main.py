import depthai as dai
import sys
import cv2
import time
import os
import json
import glob
import shutil
from datetime import datetime, timedelta
# os.environ["DEPTHAI_LEVEL"] = "trace"
import traceback
from queue import Queue
from threading import Thread
from collections import Counter
import utils.redis as redis
from threading import Thread as Th
import utils.ImageProcessing as ImageProcessing
# from python.utils.__OCR import OCR
from utils.log import log
from utils.stream import send_frame
from utils.DebugPLC import PLCLoop as DebugPLCLoop 
from utils.PLC import PLCLoop as ProductionPLCLoop
from utils.read_number import read_number
from utils.mobilenet import (
    load_tflite_anchors,
)
from utils.text_rec import attach_text_recognizer, read_letter_prefix

ENABLE_MANIP = False
ENABLE_PASSTHROUGH = False

# ฟังชั่นวาดกล่อง
def draw(frame, bbox, crop_points, text, conf):
    if bbox is not None:
        x1 = int(bbox[1] + crop_points[0])
        y1 = int(bbox[0] + crop_points[1])
        x2 = int(bbox[3] + crop_points[0])
        y2 = int(bbox[2] + crop_points[1])

        frame = cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
        conf = float("{:.2f}".format(conf))
        frame = cv2.putText(frame, str(text) + " " + str(conf), (x1, y1 - 10),
                            cv2.FONT_HERSHEY_SIMPLEX, 2, (0, 255, 0), 2)
    return frame

# ฟังชั่นแปลงเป็น boolen
def switch_to_bool(val: str) -> bool:
    return val == "1"

# อ่าน env เป็น int แบบปลอดภัย - ค่าว่าง/ไม่ใช่ตัวเลขได้ default แทนการ crash
def getenv_int(name, default):
    try:
        return int(os.getenv(name, default))
    except (ValueError, TypeError):
        return int(default)

# เช็คพื้นที่ว่างของดิสก์ (%) ที่โฟลเดอร์เก็บรูปอยู่
def disk_free_percent(directory):
    try:
        usage = shutil.disk_usage(directory)
        return usage.free / usage.total * 100
    except Exception:
        return 100.0

# ฟังก์ชันลบไฟล์เก่า (Auto Cleanup)
def cleanup_old_files(directory, days_to_keep=7):
    """Delete image files older than specified days"""
    try:
        if not os.path.exists(directory):
            return 0
        
        cutoff_time = datetime.now() - timedelta(days=days_to_keep)
        deleted_count = 0
        
        # Get all image files
        image_extensions = ['*.jpg', '*.jpeg', '*.png', '*.bmp', '*.webp']
        for ext in image_extensions:
            for file_path in glob.glob(os.path.join(directory, ext)):
                try:
                    # Get file modification time
                    file_mtime = datetime.fromtimestamp(os.path.getmtime(file_path))
                    
                    # Delete if older than cutoff
                    if file_mtime < cutoff_time:
                        os.remove(file_path)
                        deleted_count += 1
                        
                        # Also delete associated txt file if exists
                        txt_file = file_path.rsplit('.', 1)[0] + '.txt'
                        if os.path.exists(txt_file):
                            os.remove(txt_file)
                            
                except Exception as e:
                    log(f"Error deleting file {file_path}: {str(e)}", True)
        
        if deleted_count > 0:
            log(f"Auto-cleanup: Deleted {deleted_count} old images from {directory}")
        
        return deleted_count
    except Exception as e:
        log(f"Error in cleanup_old_files: {str(e)}", True)
        return 0

node_env = os.getenv("NODE_ENV", "development")


def clamp(val, min_v, max_v):
    return min(max(val, min_v), max_v)

if __name__ == "__main__":
    r = redis.get_connection()

    camera_name = os.getenv("cameraName", "in")
    camera_address = os.getenv("cameraAddress", "")
    plc_address = os.getenv("plcAddress", "")
    plc_db_num = getenv_int("plcDbNum", 111)
    enable_preview = os.getenv("enablePreview", "0") # switch
    enable_ocr = os.getenv("enableOcr", "0") # switch
    contrast_ratio = getenv_int("contrast", 0)
    sharpness = getenv_int("sharpness", 1)
    saturation = getenv_int("saturation", 0)
    chromadenoise = getenv_int("chromadenoise", 1)
    lumadenoise = getenv_int("lumadenoise", 1)
    autoexposurecompensation = getenv_int("autoexposurecompensation", 0)
    effectmode = getenv_int("effectmode", 0)

    # System settings (from System modal in web UI)
    enable_letter_read = os.getenv("enableLetterRead", "0")  # switch: read A-Z prefix before the number
    focus_mode = os.getenv("focusMode", "auto")  # "auto" | "manual"
    lens_position = getenv_int("lensPosition", 135)  # 0=far, 255=near
    ocr_model = os.getenv("ocrModel", "")  # subfolder in ./models, "" = default
    camera_fps = getenv_int("cameraFps", 30)


    crop_x1 = getenv_int("cropX1", 661)
    crop_y1 = getenv_int("cropY1", 49)
    crop_x2 = getenv_int("cropX2", 1220)
    crop_y2 = getenv_int("cropY2", 608 - 50)

    enable_writeflie = os.getenv("enableWriteFile", "0") # switch
    write_file_path = os.getenv("writeFilePath","")
    enable_plc = os.getenv("enablePlc", "0") # switch

    # Image saving filters (from Storage section in web UI)
    save_only_valid = os.getenv("saveOnlyValid", "0")  # switch: skip 888/999 results
    save_min_confidence = getenv_int("saveMinConfidence", 0)  # 0-100 (%), 0 = save all
    cleanup_days_setting = getenv_int("cleanupDays", 0)  # 0 = never auto-delete
    min_free_disk_percent = getenv_int("minFreeDiskPercent", 10)  # auto-stop saving below this
    # log(f"before switch{enable_plc},{enable_ocr},{enable_writeflie},{enable_plc},{write_file_path}")

    if write_file_path == "":
        enable_writeflie = "0"
    else:
        # Create Img directory if it doesn't exist
        if not os.path.exists(write_file_path):
            os.makedirs(write_file_path, exist_ok=True)
            log(f"Created directory: {write_file_path}")
        
        # Auto-cleanup old images (0 = keep everything, operator backs up + formats manually)
        cleanup_days = getenv_int("cleanupDays", 0)
        if cleanup_days > 0:
            cleanup_old_files(write_file_path, cleanup_days)

    enable_preview = switch_to_bool(enable_preview)
    enable_ocr = switch_to_bool(enable_ocr)
    enable_writeflie = switch_to_bool(enable_writeflie)
    enable_plc = switch_to_bool(enable_plc)
    save_only_valid = switch_to_bool(save_only_valid)
    enable_letter_read = switch_to_bool(enable_letter_read)
    if enable_letter_read and not os.path.exists("./models/text-recognition-0012.blob"):
        log("letter-read enabled but text-recognition-0012.blob not found - disabling", True)
        enable_letter_read = False

    # log(f"after swit{enable_plc},{enable_ocr},{enable_writeflie},{enable_plc}")
    
    if enable_plc:
        # quick probe: if PLC address is unreachable, fall back to DebugPLCLoop
        can_connect = False
        if plc_address:
            try:
                import snap7
                tmp = snap7.client.Client()
                try:
                    tmp.connect(plc_address, 0, 1)
                    # small pause to allow connection state
                    time.sleep(0.05)
                    if tmp.get_connected():
                        can_connect = True
                        tmp.disconnect()
                except Exception as e:
                    print(f"PLC quick connect failed: {e}", flush=True)
            except Exception as e:
                print(f"snap7 import/connect probe failed: {e}", flush=True)

        if can_connect:
            PLCLoop = ProductionPLCLoop
            print("###### START PYTHON IN PRODUCTION MODE ######", flush=True)
        else:
            PLCLoop = DebugPLCLoop
            print("###### START PYTHON IN DEVELOPMENT MODE ###### (PLC unreachable, using DebugPLCLoop)", flush=True)
    else:
        PLCLoop = DebugPLCLoop
        print("###### START PYTHON IN DEVELOPMENT MODE ###### (Please check .env file for configuration)", flush=True)
    # clamp
    contrast_ratio = clamp(contrast_ratio, -10, 10)
    sharpness = clamp(sharpness, 0, 4)
    saturation = clamp(saturation, -10, 10)
    chromadenoise = clamp(chromadenoise, 0, 4)
    lumadenoise = clamp(lumadenoise, 0, 4)
    autoexposurecompensation = clamp(autoexposurecompensation, -9, 9)
    effectmode = clamp(effectmode, 0, 9)

    effectmode_enum = None

    if effectmode == 0:
        effectmode_enum = dai.CameraControl.EffectMode.OFF
    elif effectmode == 1:
        effectmode_enum = dai.CameraControl.EffectMode.MONO
    elif effectmode == 2:
        effectmode_enum = dai.CameraControl.EffectMode.NEGATIVE
    elif effectmode == 3:
        effectmode_enum = dai.CameraControl.EffectMode.SOLARIZE
    elif effectmode == 4:
        effectmode_enum = dai.CameraControl.EffectMode.SEPIA
    elif effectmode == 5:
        effectmode_enum = dai.CameraControl.EffectMode.POSTERIZE
    elif effectmode == 6:
        effectmode_enum = dai.CameraControl.EffectMode.WHITEBOARD
    elif effectmode == 7:
        effectmode_enum = dai.CameraControl.EffectMode.BLACKBOARD
    elif effectmode == 8:
        effectmode_enum = dai.CameraControl.EffectMode.AQUA

    # set Width/Height
    width = 1280
    height = 720
    model_width = 384
    model_height = 384
    # set model (ocrModel = subfolder in ./models selected from System modal)
    nn_path = f"./models/best_model.blob"
    metadata_path = f"./models/metadata.json"
    if ocr_model:
        candidate_blob = f"./models/{ocr_model}/best_model.blob"
        candidate_meta = f"./models/{ocr_model}/metadata.json"
        if os.path.exists(candidate_blob) and os.path.exists(candidate_meta):
            nn_path = candidate_blob
            metadata_path = candidate_meta
            log(f"{camera_name}: using OCR model '{ocr_model}'")
        else:
            log(f"{camera_name}: OCR model '{ocr_model}' not found, using default")
    anchors = load_tflite_anchors(metadata_path)
    # crop points
    x1 = crop_x1 / width
    y1 = crop_y1 / height
    x2 = crop_x2 / width
    y2 = crop_y2 / height

    crop_width = crop_x2 - crop_x1
    crop_height = crop_y2 - crop_y1

    crop_points = [crop_x1, crop_y1, crop_x2, crop_y2]

    # Crop range
    crop_top_left = dai.Point2f(x1, y1)
    crop_bottom_right = dai.Point2f(x2, y2)

    
    queue_list = {
    "is_ready": Queue(maxsize=1),
    "write": Queue(maxsize=1),
    "camera_status": Queue(maxsize=1),
    # plc_weight queue will contain latest float weight (or None)
    "plc_weight": Queue(maxsize=1)
    }

    thread = Thread(target=PLCLoop, args=(camera_name, plc_address, plc_db_num, queue_list))
    thread.start()
    print(f"Started PLCLoop thread using: {PLCLoop.__name__}", flush=True)
    # If using DebugPLCLoop, push an initial ready trigger so capture can start immediately
    try:
        if PLCLoop == DebugPLCLoop:
            if queue_list["is_ready"].full():
                _ = queue_list["is_ready"].get_nowait()
            queue_list["is_ready"].put_nowait(True)
            print("DebugPLCLoop fallback active: initial is_ready signal sent", flush=True)
    except Exception:
        pass

    # start a Redis-based manual trigger listener so UI or CLI can force a capture
    def _redis_trigger_listener(q_list):
        try:
            rconn = redis.get_connection()
            psub = rconn.pubsub(ignore_subscribe_messages=True)
            psub.subscribe('plc_trigger')
            print('Redis trigger listener subscribed to plc_trigger', flush=True)
            for msg in psub.listen():
                try:
                    data = msg.get('data')
                    if data:
                        # any message received will enqueue a True to is_ready
                        if q_list['is_ready'].full():
                            try:
                                _ = q_list['is_ready'].get_nowait()
                            except Exception:
                                pass
                        q_list['is_ready'].put_nowait(True)
                        print('Manual trigger received via redis: plc_trigger', flush=True)
                except Exception as e:
                    print('Error in trigger listener loop:', e, flush=True)
        except Exception as e:
            print('Failed to start redis trigger listener:', e, flush=True)

    trig_thread = Th(target=_redis_trigger_listener, args=(queue_list,), daemon=True)
    trig_thread.start()

    
    while True:
        log(f"starting camera: {camera_name} -> {camera_address}")

        pipeline = dai.Pipeline()

        # mkdir result
        if enable_writeflie:    
            camera_folder_ocr = f"{write_file_path}/{camera_name}"
            if not os.path.exists(camera_folder_ocr):
                os.makedirs(camera_folder_ocr)

        log(f"{camera_name}, PLC {plc_address} Connected")

        cam_rgb = pipeline.create(dai.node.ColorCamera)
        cam_rgb.setPreviewSize(width, height)
        cam_rgb.setInterleaved(False)
        cam_rgb.setFps(camera_fps)
        cam_rgb.setColorOrder(dai.ColorCameraProperties.ColorOrder.RGB)
        cam_rgb.initialControl.setContrast(contrast_ratio)
        cam_rgb.initialControl.setSharpness(sharpness)
        cam_rgb.initialControl.setSaturation(saturation)
        if effectmode_enum is not None:
            cam_rgb.initialControl.setEffectMode(effectmode_enum)
        cam_rgb.initialControl.setChromaDenoise(chromadenoise)
        cam_rgb.initialControl.setLumaDenoise(lumadenoise)
        cam_rgb.initialControl.setAutoExposureCompensation(autoexposurecompensation)
        # Focus: manual = fixed lens position (0=ไกล, 255=ใกล้), auto = continuous autofocus
        if focus_mode == "manual":
            cam_rgb.initialControl.setManualFocus(lens_position)
            log(f"{camera_name}: manual focus, lens position {lens_position}")
        else:
            cam_rgb.initialControl.setAutoFocusMode(dai.CameraControl.AutoFocusMode.CONTINUOUS_VIDEO)

        # MANIP (CROP)
        manip = pipeline.create(dai.node.ImageManip)
        manip.setMaxOutputFrameSize(model_width * model_height * 3)
        manip.initialConfig.setCropRect(
            crop_top_left.x,
            crop_top_left.y,
            crop_bottom_right.x,
            crop_bottom_right.y,
        )
        manip.initialConfig.setKeepAspectRatio(False)
        manip.initialConfig.setResize(model_width, model_height)
        manip.initialConfig.setFrameType(dai.RawImgFrame.Type.BGR888p)
        manip.inputImage.setBlocking(False)
        manip.inputImage.setQueueSize(1)
        cam_rgb.video.link(manip.inputImage)

        # NN NODE
        nn = pipeline.createNeuralNetwork()
        nn.setBlobPath(nn_path)
        nn.setNumInferenceThreads(2)
        nn.input.setBlocking(False)
        nn.input.setQueueSize(1)
        manip.out.link(nn.input)

        # XOUT NN DET
        xout_nn_det = pipeline.create(dai.node.XLinkOut)
        xout_nn_det.setStreamName("det")
        nn.out.link(xout_nn_det.input)

        # XOUT RGB
        xout_rgb = pipeline.create(dai.node.XLinkOut)
        xout_rgb.setStreamName("rgb")
        cam_rgb.preview.link(xout_rgb.input)

        # XOUT NN PASS
        if ENABLE_PASSTHROUGH:
            xout_nn_pass = pipeline.create(dai.node.XLinkOut)
            xout_nn_pass.setStreamName("pass")
            nn.passthrough.link(xout_nn_pass.input)

        # XOUT MANIP
        if ENABLE_MANIP:
            xout_manip = pipeline.create(dai.node.XLinkOut)
            xout_manip.setStreamName("manip")
            manip.out.link(xout_manip.input)

        # SECOND NN: letter-prefix recognizer (runs on the VPU next to the digit model)
        if enable_letter_read:
            attach_text_recognizer(pipeline)
            log(f"{camera_name}: letter-prefix recognizer attached (text-recognition-0012)")

        try:
            if camera_address == "":
                device = dai.Device(pipeline=pipeline)
            else:
                device = dai.Device(deviceInfo=dai.DeviceInfo(camera_address))
                device.startPipeline(pipeline)

            log(f"{camera_name}: Camera Connected", True)
            
            # set queue
            print("PUT CAMERA STATUS", flush=True)
            if queue_list["camera_status"].full():
                queue_list["camera_status"].get()
            queue_list["camera_status"].put_nowait(True)

            q_rgb = device.getOutputQueue(name="rgb", maxSize=1, blocking=False)
            q_nn_det = device.getOutputQueue(name="det", maxSize=1, blocking=False)
            q_rec_in = device.getInputQueue("rec_in") if enable_letter_read else None
            q_rec_out = device.getOutputQueue(name="rec_out", maxSize=1, blocking=False) if enable_letter_read else None
            if ENABLE_MANIP:
                q_manip = device.getOutputQueue(name="manip", maxSize=1, blocking=False)
            if ENABLE_PASSTHROUGH:
                q_nn_pass = device.getOutputQueue(name="pass", maxSize=1, blocking=False)

            max_trick = 25
            trick_counter = 0

            score_threshold = 0.55
            iou_threshold = 0.5
            last_update_time = None

            last_current_read_text = None
            bbox = None
            current_read_frame = None
            curent_confidence_avg = None
            read_text_list=[]
            current_read_frame_nn_pass = None
            current_read_frame_manip = None

            check_box_xmin = 0
            check_box_xmax = 0

            first_bbox_xmax = None
            log_list = ""

            # best frame that actually contains a number (bbox seen) in this trigger cycle
            best_bbox_frame = None
            best_bbox = None
            best_bbox_conf = 0
            
            # Auto-cleanup timer (run every hour)
            last_cleanup_time = time.time()
            cleanup_interval = 3600  # 1 hour in seconds

            while True:
                time.sleep(0.1)
                
                # Auto-cleanup check (every hour, 0 = disabled)
                if enable_writeflie and write_file_path:
                    current_time = time.time()
                    if current_time - last_cleanup_time >= cleanup_interval:
                        cleanup_days = getenv_int("cleanupDays", 0)
                        if cleanup_days > 0:
                            cleanup_old_files(write_file_path, cleanup_days)
                        last_cleanup_time = current_time
                
                bbox_list = []
                confidence_list = []
                xmin_and_number_list = []
                result_int = 0

                rgb_in = q_rgb.get()
                nn_det_in = q_nn_det.tryGet()

                if ENABLE_MANIP:
                    manip_in = q_manip.tryGet()
                if ENABLE_PASSTHROUGH:
                    nn_pass_in = q_nn_pass.tryGet()

                frame = rgb_in.getCvFrame()

                frame_threemin = frame.copy()
                
                width = frame.shape[1]
                height = frame.shape[0]

                frame = cv2.rectangle(frame, (int(crop_points[0]), int(crop_points[1])),
                                    (int(crop_points[2]), int(crop_points[3])), (0, 255, 255), 1)
                
                if enable_ocr:
                    is_ready = False
                    if not queue_list["is_ready"].empty():
                        val = queue_list["is_ready"].get_nowait()
                        is_ready = val == True
                        if is_ready:
                            print(f"[Trigger] is_ready consumed: {val}", flush=True)

                    # ASK PLC Status
                    if trick_counter > 0:
                        trick_counter += 1
                    elif is_ready:
                        trick_counter = 1

                    # log(f"{camera_name}: trick_counter: {trick_counter}")
                    frame_manip = None
                    if ENABLE_MANIP:
                        if manip_in is not None:
                            frame_manip = manip_in.getCvFrame()
                            # send_frame(r, "ocr_frame_last", camera_name, frame_manip)
                    frame_nn_pass = None
                    if ENABLE_PASSTHROUGH:
                        if nn_pass_in is not None:
                            frame_nn_pass = nn_pass_in.getCvFrame()

                    if trick_counter > 0:
                        # อ่านกล้อง
                        incoming_text, bbox, confidence_avg = read_number(nn_det_in, anchors, score_threshold, iou_threshold, crop_width, crop_height)
                        
                        # ไม่เจอbox เพิ่ม888
                        if bbox is None:
                            read_text_list.append(incoming_text)
                        else:
                            bbox_xmax = bbox[3]
                            bbox_xmin = bbox[1]
                            if first_bbox_xmax is None:
                                first_bbox_xmax = bbox_xmax
                            # เปรียบเทียบต่ำแหน่งของbboxในช่วง เพื่อบันทึกผลลัพธ์
                            if bbox_xmin < first_bbox_xmax:
                                log(f"bbox_xmin ,{bbox_xmin}, first_bbox_xmax, {first_bbox_xmax}")
                                read_text_list.append(incoming_text)

                            # เก็บเฟรมที่เห็นเลขจริง (มี bbox) ตัวที่ confidence ดีสุดของรอบนี้
                            conf_val = confidence_avg if confidence_avg is not None else 0
                            if best_bbox_frame is None or conf_val >= best_bbox_conf:
                                best_bbox_frame = frame_threemin.copy()
                                best_bbox = bbox
                                best_bbox_conf = conf_val

                        log(f"read_text_list ,{read_text_list}")
                        log(f"{trick_counter} {first_bbox_xmax}")
                        
                        # เอา read_text_list มาหาจำนวนตัวเลขที่อ่านได้จำนวนครั้งมากสุด
                        counter = Counter(read_text_list)
                        # หาค่าที่มีจำนวนมากที่สุด
                        most_common_value, count = counter.most_common(1)[0]
                        # ถ้าได้ค่าใหม่ให้บันทึกภาพใหม่
                        if most_common_value != last_current_read_text:
                            last_current_read_text = most_common_value
                            current_read_frame = frame.copy()
                            curent_confidence_avg = confidence_avg

                            if ENABLE_PASSTHROUGH:
                                current_read_frame_nn_pass = frame_nn_pass.copy()
                                
                            # if ENABLE_MANIP:
                            #     current_read_frame_manip = frame_manip.copy()

                            if enable_preview:
                                current_read_frame_draw = draw(current_read_frame.copy(), bbox, crop_points, last_current_read_text,
                                                        curent_confidence_avg)
                                # overlay latest plc weight on the frame before sending
                                try:
                                    latest_weight = None
                                    if not queue_list["plc_weight"].empty():
                                        latest_weight = queue_list["plc_weight"].get_nowait()
                                        # put it back so preview also sees it next time
                                        if queue_list["plc_weight"].full():
                                            _ = queue_list["plc_weight"].get_nowait()
                                        queue_list["plc_weight"].put_nowait(latest_weight)
                                    if latest_weight is not None:
                                        txt = f"Weight: {float(latest_weight):.3f}"
                                        cv2.putText(current_read_frame_draw, txt, (int(width) - 260, 30), cv2.FONT_HERSHEY_SIMPLEX, 1,
                                                    (255, 255, 255), 2, cv2.LINE_AA)
                                except Exception:
                                    pass
                                send_frame(r, "ocr_frame_last", camera_name, current_read_frame_draw)
                            log(f"[Trick {trick_counter}] Change detected! New most common class: {most_common_value} (count: {count})")
                            log_list = f"{log_list} \n [Trick {trick_counter}] Change detected! New most common class: {most_common_value} (count: {count})"
                        else:
                            log(f"[Trick {trick_counter}] No change. Most common remains: {most_common_value} (count: {count})")
                            log_list = f"{log_list} \n [Trick {trick_counter}] No change. Most common remains: {most_common_value} (count: {count})"
                        
                        log(f"{camera_name}: Scanning result: {incoming_text}, current_result: {last_current_read_text}, curent_confidence_avg: {curent_confidence_avg}" )
                        log_list = f"{log_list} \n trick: {trick_counter} class: {incoming_text}, confidence_avg: {confidence_avg}, bbox: {bbox}"

                # send result if trick more than max trick
                if trick_counter >= max_trick:
                    # Letter prefix (e.g. "AB" in AB123): read once per trigger from the
                    # best frame, via the second NN on the VPU. The PLC still receives
                    # the numeric part only - the prefix goes to display/publish/filename.
                    read_display_value = last_current_read_text
                    if (enable_letter_read and best_bbox_frame is not None and best_bbox is not None
                            and str(last_current_read_text) not in ("888", "999", "None")):
                        try:
                            letter_prefix = read_letter_prefix(q_rec_in, q_rec_out, best_bbox_frame, best_bbox, crop_points)
                            if letter_prefix:
                                read_display_value = f"{letter_prefix}{last_current_read_text}"
                                log(f"{camera_name}: letter prefix '{letter_prefix}' -> {read_display_value}")
                        except Exception as e:
                            log(f"{camera_name}: letter read error: {e}")

                    if queue_list["write"].full():
                        queue_list["write"].get()
                    print(f"[Result] Queueing OCR result: {read_display_value}, conf={curent_confidence_avg}", flush=True)
                    queue_list["write"].put_nowait([last_current_read_text, curent_confidence_avg])
                    # publish final result for web UI / central server (with prefix when read)
                    try:
                        conf_str = f"{curent_confidence_avg:.4f}" if curent_confidence_avg is not None else ""
                        r.publish("ocr_result", f"{camera_name} {read_display_value} {conf_str}")
                    except Exception:
                        pass
                    # if last_current_read_text == 888 or last_current_read_text == 999:
                    #     file_name_by_time = f"{camera_folder_result}/{int(time.time())}_{camera_name}_{last_current_read_text}.jpg"
                    #     cv2.imwrite(file_name_by_time, current_read_frame)
                    #     # passthrough result
                    #     file_name_by_time_pass = f"{camera_folder_result}/{int(time.time())}_{camera_name}_{last_current_read_text}_passthrough.jpg"
                    #     cv2.imwrite(file_name_by_time_pass, current_read_frame_nn_pass)
                    #     log("888++999")
                    # Save rules (per PLC trigger: 1 annotated + 1 raw image max):
                    # - save only when a number was actually seen in frame (bbox detected);
                    #   trigger with no number visible saves nothing
                    # - unreadable results (888/999) with a visible number are kept for
                    #   retraining, unless saveOnlyValid is on
                    # - min-confidence filter applies to valid reads only
                    # - stop saving automatically when disk is almost full
                    is_valid_read = last_current_read_text is not None and str(last_current_read_text) not in ("888", "999")
                    should_save = enable_writeflie and best_bbox_frame is not None
                    if enable_writeflie and best_bbox_frame is None:
                        log(f"{camera_name}: skip save (no number seen in this trigger)")
                    if should_save and save_only_valid and not is_valid_read:
                        should_save = False
                        log(f"{camera_name}: skip save (invalid read: {last_current_read_text})")
                    if should_save and save_min_confidence > 0 and is_valid_read:
                        conf_pct = best_bbox_conf * 100
                        if conf_pct < save_min_confidence:
                            should_save = False
                            log(f"{camera_name}: skip save (confidence {conf_pct:.0f}% < {save_min_confidence}%)")
                    if should_save:
                        free_percent = disk_free_percent(write_file_path)
                        if free_percent < min_free_disk_percent:
                            should_save = False
                            log(f"{camera_name}: skip save (disk almost full: {free_percent:.1f}% free < {min_free_disk_percent}%)", True)

                    if should_save:
                        try:
                            # Annotated copy (ROI + confidence) for recheck
                            frame_to_save = draw(best_bbox_frame.copy(), best_bbox, crop_points, read_display_value, best_bbox_conf)
                            # overlay latest weight if available
                            try:
                                latest_weight = None
                                if not queue_list["plc_weight"].empty():
                                    latest_weight = queue_list["plc_weight"].get_nowait()
                                    if queue_list["plc_weight"].full():
                                        _ = queue_list["plc_weight"].get_nowait()
                                    queue_list["plc_weight"].put_nowait(latest_weight)
                                if latest_weight is not None:
                                    txt = f"Weight: {float(latest_weight):.3f}"
                                    cv2.putText(frame_to_save, txt, (int(width) - 260, 30), cv2.FONT_HERSHEY_SIMPLEX, 1,
                                                (255, 255, 255), 2, cv2.LINE_AA)
                            except Exception:
                                pass
                            
                            # Save the image directly to /home/pi/Desktop/OCR-NEW-update/Img
                            # (filename carries the letter prefix when one was read)
                            timestamp = time.strftime("%Y%m%d_%H%M%S")
                            file_name = f"{write_file_path}/{read_display_value}_{timestamp}.jpg"
                            cv2.imwrite(file_name, frame_to_save)

                            # Raw copy (no overlay) for model retraining
                            raw_file_name = f"{write_file_path}/{read_display_value}_{timestamp}_raw.jpg"
                            cv2.imwrite(raw_file_name, best_bbox_frame)

                            # Save Log List -- disabled per operator request (uncomment to re-enable)
                            # log_list = f"{log_list} \n trick: result class: {last_current_read_text}, confidence_avg: {curent_confidence_avg}, bbox: {bbox}"
                            # txt_file_name = f"{write_file_path}/{last_current_read_text}_{timestamp}.txt"
                            # with open(f"{txt_file_name}", "w") as f:
                            #     f.write(log_list)

                            # Save passthrough OCR with ROI
                            if ENABLE_PASSTHROUGH:
                                frame_pass_to_save = current_read_frame_nn_pass.copy()
                                if bbox is not None:
                                    frame_pass_to_save = draw(frame_pass_to_save, bbox, crop_points, last_current_read_text, curent_confidence_avg)
                                file_name_pass = f"{write_file_path}/{last_current_read_text}_{timestamp}_passthrough.jpg"
                                cv2.imwrite(file_name_pass, frame_pass_to_save)
                            # Save Manip
                            # if ENABLE_MANIP:
                                
                            #     file_name_manip = f"{write_file_path}/{camera_name}/{last_current_read_text}_{timestamp}_manip.jpg"
                            #     cv2.imwrite(file_name_manip, current_read_frame_manip)
                                
                            log(f"Saved image with ROI: {file_name}")
                        except Exception as e:
                            log(f"Error saving image to {write_file_path}: {str(e)}" , True)
                    # reset value
                    trick_counter = 0
                    last_current_read_text = None
                    read_text_list = []
                    curent_confidence_avg = None
                    current_read_frame = None
                    first_bbox_xmax = None
                    current_read_frame_nn_pass = None
                    current_read_frame_manip = None
                    log_list= ""
                    best_bbox_frame = None
                    best_bbox = None
                    best_bbox_conf = 0
                    

                # preview frame 
                if enable_preview:
                    # overlay latest weight onto preview frame as well
                    try:
                        latest_weight = None
                        if not queue_list["plc_weight"].empty():
                            latest_weight = queue_list["plc_weight"].get_nowait()
                            if queue_list["plc_weight"].full():
                                _ = queue_list["plc_weight"].get_nowait()
                            queue_list["plc_weight"].put_nowait(latest_weight)
                        if latest_weight is not None:
                            txt = f"Weight: {float(latest_weight):.3f}"
                            cv2.putText(frame, txt, (int(width) - 260, 30), cv2.FONT_HERSHEY_SIMPLEX, 1,
                                        (255, 255, 255), 2, cv2.LINE_AA)
                    except Exception:
                        pass
                    frame = ImageProcessing.resize(frame, 600)
                    send_frame(r, "ocr_frame", camera_name, frame)
                

        except Exception as e:
            log(f"Error, {e}", True)
            log(f"{camera_name}: Python Crash Error", True)
            log(f"{camera_name}: Device init/start error: {e}", True)
            traceback.print_exc()

        finally:
            log(f"{camera_name}: Cleaning up device & PLC", True)

            if queue_list["camera_status"].full():
                queue_list["camera_status"].get()
            queue_list["camera_status"].put_nowait(False)

            try:
                device.close()
            except:
                pass
            time.sleep(10)  # พักก่อนวนใหม่
