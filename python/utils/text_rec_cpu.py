# CPU (OpenVINO) version of the letter-prefix reader - used by the web OCR
# Test tool (ocr_test.py) which runs on static images without the OAK device.
# Optional dependency: silently unavailable when openvino / IR files are missing.
import os
import re

import numpy as np

from utils.text_rec import _ctc_decode, preprocess_region, ALPHABET, REC_W, REC_H

_IR_XML = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "models", "text-recognition-ir", "text-recognition-0012.xml")
_compiled = None
_output = None
_failed = False


def _ensure_loaded():
    global _compiled, _output, _failed
    if _compiled is not None or _failed:
        return _compiled is not None
    try:
        try:
            from openvino import Core          # openvino >= 2024
        except ImportError:
            from openvino.runtime import Core  # older releases
        if not os.path.exists(_IR_XML):
            raise FileNotFoundError(_IR_XML)
        core = Core()
        _compiled = core.compile_model(core.read_model(_IR_XML), "CPU")
        _output = _compiled.output(0)
        return True
    except Exception:
        _failed = True
        return False


def recognize_cpu(region):
    """BGR/gray region -> lowercase text ('' when recognizer unavailable)."""
    if not _ensure_loaded() or region is None or region.size == 0:
        return ""
    gray = preprocess_region(region)
    blob = gray.astype(np.float32).reshape(1, REC_H, REC_W, 1)  # this IR is NHWC
    logits = _compiled([blob])[_output]
    return _ctc_decode(logits.reshape(-1, len(ALPHABET) + 1))


def read_letter_prefix_cpu(frame, x1, y1, x2, y2):
    """Read the letter prefix left of the digit bbox (absolute pixel coords).
    Same geometry as utils/text_rec.read_letter_prefix on the camera."""
    h = max(1, y2 - y1)
    w = max(1, x2 - x1)
    x_from = max(0, x1 - int(h * 3.5))
    x_to = min(frame.shape[1], x1 + int(w * 0.05))
    y_from = max(0, y1 - int(h * 0.25))
    y_to = min(frame.shape[0], y2 + int(h * 0.25))
    if x_to - x_from < 8:
        return ""
    text = recognize_cpu(frame[y_from:y_to, x_from:x_to])
    match = re.match(r"^([a-z]+)", text)
    return match.group(1).upper() if match else ""
