# Test the letter model (text-recognition-0012) on this PC's CPU via OpenVINO -
# same network + same preprocessing + same CTC decode as the camera VPU path.
#
# Usage:
#   python test_text_rec_cpu.py                 -> run the built-in test suites
#   python test_text_rec_cpu.py path\to\img.jpg -> read letters from your own image
#     (crop the image so it contains ONLY the letter area for best results;
#      optional 2nd arg = expected text to compare)
import os
import re
import sys
import numpy as np
import cv2

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from utils.text_rec import _ctc_decode, preprocess_region, ALPHABET

try:
    from openvino import Core          # openvino >= 2024
except ImportError:
    from openvino.runtime import Core  # older releases

IR_XML = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "models", "text-recognition-ir", "text-recognition-0012.xml")
REC_W, REC_H = 120, 32

core = Core()
compiled = core.compile_model(core.read_model(IR_XML), "CPU")
output_layer = compiled.output(0)


def recognize_cpu(image):
    """Same preprocessing as the camera path, inference on CPU (NHWC input)."""
    gray = preprocess_region(image)
    blob = gray.astype(np.float32).reshape(1, REC_H, REC_W, 1)
    logits = compiled([blob])[output_layer]
    return _ctc_decode(logits.reshape(-1, len(ALPHABET) + 1))


def synth_word(text, size=48):
    """Render a word like stamped text (dark on light) with a real font."""
    from PIL import Image, ImageDraw, ImageFont
    img = Image.new("L", (340, 90), 240)
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("arialbd.ttf", size)
    except OSError:
        font = ImageFont.load_default()
    draw.text((12, 14), text, fill=15, font=font)
    return np.array(img)


def prefix_flow(letters, digits):
    """Simulate the camera flow: full plate image + known digit bbox ->
    crop the region LEFT of the digits (same formula as read_letter_prefix) ->
    recognize -> extract prefix."""
    from PIL import Image, ImageDraw, ImageFont
    font = ImageFont.truetype("arialbd.ttf", 48)
    img = Image.new("L", (420, 100), 240)
    draw = ImageDraw.Draw(img)
    draw.text((14, 20), letters, fill=15, font=font)
    lw = draw.textlength(letters + " ", font=font)
    draw.text((14 + lw, 20), digits, fill=15, font=font)
    frame = np.array(img)

    # digit bbox (absolute) like the detector would give us
    dw = draw.textlength(digits, font=font)
    x1, y1 = int(14 + lw), 20
    x2, y2 = int(14 + lw + dw), 20 + 48
    h, w = y2 - y1, x2 - x1

    # same crop formula as utils/text_rec.read_letter_prefix
    x_from = max(0, x1 - int(h * 3.5))
    x_to = min(frame.shape[1], x1 + int(w * 0.05))
    y_from = max(0, y1 - int(h * 0.25))
    y_to = min(frame.shape[0], y2 + int(h * 0.25))

    text = recognize_cpu(frame[y_from:y_to, x_from:x_to])
    match = re.match(r"^([a-z]+)", text)
    return (match.group(1).upper() if match else ""), text


if __name__ == "__main__":
    if len(sys.argv) > 1:
        path = sys.argv[1]
        img = cv2.imread(path)
        if img is None:
            print(f"ERROR: cannot open image: {path}")
            sys.exit(1)
        raw = recognize_cpu(img)
        result = raw.upper()
        m = re.match(r"^([A-Z]+)", result)
        print(f"file   : {path}")
        print(f"read   : {result or '(nothing recognized)'}")
        print(f"prefix : {m.group(1) if m else '(none)'}")
        if len(sys.argv) > 2:
            expect = sys.argv[2].upper()
            print(f"expect : {expect}  ->  {'PASS' if result == expect else 'FAIL'}")
        sys.exit(0)

    print("== suite 1: letters-only regions (what the model sees in production) ==")
    letter_cases = ["AB", "X", "GT", "PKM", "HELLO", "ZQ"]
    passed = 0
    for text in letter_cases:
        got = recognize_cpu(synth_word(text)).upper()
        ok = got == text
        passed += ok
        print(f"  expect={text:<7} got={got:<9} {'PASS' if ok else 'FAIL'}")
    print(f"  letters: {passed}/{len(letter_cases)} passed")

    print("== suite 2: full flow (plate 'AB 123' -> crop left of digit bbox -> prefix) ==")
    flow_cases = [("AB", "123"), ("X", "985"), ("GT", "7"), ("PK", "460")]
    passed2 = 0
    for letters, digits in flow_cases:
        prefix, raw = prefix_flow(letters, digits)
        ok = prefix == letters
        passed2 += ok
        print(f"  plate={letters}{digits:<5} raw={raw:<8} prefix={prefix:<5} {'PASS' if ok else 'FAIL'}")
    print(f"  flow: {passed2}/{len(flow_cases)} passed")
    print(f"RESULT: {passed + passed2}/{len(letter_cases) + len(flow_cases)} passed")
