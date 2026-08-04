# Letter-prefix reader using Intel text-recognition-0012 (a-z, 0-9)
# Runs as a SECOND NeuralNetwork node on the OAK VPU alongside the digit
# detector - near zero extra CPU load on the CM4. The host crops the region
# around the detected digits (extended to the left where the letter prefix
# sits), sends it in via XLinkIn, and CTC-decodes the result.
import re
import time
import numpy as np
import cv2
import depthai as dai

BLOB_PATH = "./models/text-recognition-0012.blob"
REC_W, REC_H = 120, 32
ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz"
BLANK = len(ALPHABET)  # index 36


def attach_text_recognizer(pipeline, blob_path=BLOB_PATH):
    """Add XLinkIn -> NN -> XLinkOut nodes for text recognition."""
    rec_in = pipeline.create(dai.node.XLinkIn)
    rec_in.setStreamName("rec_in")
    rec_in.setMaxDataSize(REC_W * REC_H)

    rec_nn = pipeline.create(dai.node.NeuralNetwork)
    rec_nn.setBlobPath(blob_path)
    rec_nn.setNumInferenceThreads(1)
    rec_nn.input.setBlocking(False)
    rec_nn.input.setQueueSize(1)
    rec_in.out.link(rec_nn.input)

    rec_out = pipeline.create(dai.node.XLinkOut)
    rec_out.setStreamName("rec_out")
    rec_nn.out.link(rec_out.input)


def _ctc_decode(logits, min_conf=0.5):
    """Greedy CTC decode of [T, 37] logits -> lowercase string.
    Characters below min_conf (softmax) are dropped - guards against
    hallucinated characters on noisy regions."""
    shifted = logits - logits.max(axis=-1, keepdims=True)
    exp = np.exp(shifted)
    probs = exp / exp.sum(axis=-1, keepdims=True)
    prev = -1
    chars = []
    for t in range(logits.shape[0]):
        idx = int(np.argmax(logits[t]))
        if idx != BLANK and idx != prev and idx < len(ALPHABET) and probs[t][idx] >= min_conf:
            chars.append(ALPHABET[idx])
        prev = idx
    return "".join(chars)


def _tight_crop(gray):
    """Crop tight around the text. Foreground = minority pixel class (polarity-agnostic)."""
    _, bw = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    fg = bw > 0
    if fg.mean() > 0.5:
        fg = ~fg
    ys, xs = np.where(fg)
    if len(xs) < 10:
        return gray
    m = 3
    return gray[max(0, ys.min() - m):ys.max() + m + 1, max(0, xs.min() - m):xs.max() + m + 1]


def preprocess_region(region):
    """BGR/gray region -> 32x120 gray: tight crop then stretch to full size.
    Stretching (not padding) is important - padded empty space makes this model
    hallucinate extra characters. Single source of truth for camera + CPU test."""
    gray = cv2.cvtColor(region, cv2.COLOR_BGR2GRAY) if region.ndim == 3 else region
    return cv2.resize(_tight_crop(gray), (REC_W, REC_H))


def recognize_text(q_rec_in, q_rec_out, region_bgr, timeout_sec=1.0):
    """Send a BGR crop through the recognizer, return lowercase string ('' on failure)."""
    if region_bgr is None or region_bgr.size == 0:
        return ""
    gray = preprocess_region(region_bgr)

    frame = dai.ImgFrame()
    frame.setType(dai.ImgFrame.Type.GRAY8)  # device converts U8 -> FP16
    frame.setWidth(REC_W)
    frame.setHeight(REC_H)
    frame.setData(gray.flatten())

    # drain stale results, then send
    while q_rec_out.tryGet() is not None:
        pass
    q_rec_in.send(frame)

    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        nn_data = q_rec_out.tryGet()
        if nn_data is not None:
            logits = np.array(nn_data.getFirstLayerFp16()).reshape(-1, len(ALPHABET) + 1)
            return _ctc_decode(logits)
        time.sleep(0.01)
    return ""


def read_letter_prefix(q_rec_in, q_rec_out, frame, bbox, crop_points):
    """Read the letter prefix left of the detected digit bbox.

    bbox = [y1, x1, y2, x2] relative to the crop area (same convention as draw()).
    Returns UPPERCASE letters, '' when none recognized.
    """
    y1 = int(bbox[0] + crop_points[1])
    x1 = int(bbox[1] + crop_points[0])
    y2 = int(bbox[2] + crop_points[1])
    x2 = int(bbox[3] + crop_points[0])
    h = max(1, y2 - y1)
    w = max(1, x2 - x1)

    # region = area LEFT of the digits only (digits are excluded on purpose:
    # this model confuses digits with letters, so it must never see them -
    # the digit value comes from the original digit model).
    # Window width scales with character HEIGHT (not digit width - a single
    # narrow digit like "7" would shrink the window and cut the prefix off);
    # 3.5*h covers a prefix of ~4 letters.
    x_from = max(0, x1 - int(h * 3.5))
    x_to = min(frame.shape[1], x1 + int(w * 0.05))
    y_from = max(0, y1 - int(h * 0.25))
    y_to = min(frame.shape[0], y2 + int(h * 0.25))
    if x_to - x_from < 8:
        return ""

    text = recognize_text(q_rec_in, q_rec_out, frame[y_from:y_to, x_from:x_to])
    match = re.match(r"^([a-z]+)", text)
    return match.group(1).upper() if match else ""
