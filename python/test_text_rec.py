# Standalone on-device test for the letter recognizer (text-recognition-0012).
# Builds a minimal pipeline (XLinkIn -> NN -> XLinkOut), feeds synthetic images
# rendered with cv2.putText, and prints what the model reads.
# NOTE: stop the main OCR process first (pm2 stop ocr) - one process per OAK device.
import numpy as np
import cv2
import depthai as dai
from utils.text_rec import attach_text_recognizer, recognize_text

# letters-only cases: in production this model only ever sees the letter zone
# (the digits are excluded from the crop and read by the original digit model)
CASES = ["AB", "X", "GT", "PKM"]

pipeline = dai.Pipeline()
attach_text_recognizer(pipeline)

with dai.Device(pipeline) as device:
    q_in = device.getInputQueue("rec_in")
    q_out = device.getOutputQueue(name="rec_out", maxSize=1, blocking=False)

    passed = 0
    for text in CASES:
        # synthetic plate: dark text on light background, like stamped numbers
        img = np.full((64, 240, 3), 235, dtype=np.uint8)
        cv2.putText(img, text, (12, 46), cv2.FONT_HERSHEY_SIMPLEX, 1.5, (20, 20, 20), 4, cv2.LINE_AA)
        result = recognize_text(q_in, q_out, img, timeout_sec=3.0).upper()
        ok = result == text
        passed += ok
        print(f"expect={text:<6} got={result:<8} {'PASS' if ok else 'FAIL'}", flush=True)

    print(f"RESULT: {passed}/{len(CASES)} passed", flush=True)
