"""
OCR Test Tool - Process images with OCR model (ONNX) and return annotated results
Uses the same model and logic as the main pipeline but runs on static images via CPU.
"""
import sys
import os

# Add the python/ directory to sys.path so that `utils` package is importable
_python_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _python_dir not in sys.path:
    sys.path.insert(0, _python_dir)

import numpy as np
import cv2
import base64
import onnxruntime as ort
from utils.mobilenet import (
    load_tflite_anchors,
    pre_process,
    post_process,
    translate_id_to_class,
)


# -----------------------------------------------------------------------
# Model config (same values as main.py)
# -----------------------------------------------------------------------
MODEL_WIDTH  = 384
MODEL_HEIGHT = 384
SCORE_THRESHOLD = 0.55
IOU_THRESHOLD   = 0.5

# Path relative to python/ (cwd when called from Node.js)
ONNX_MODEL_PATH  = "./models/16_04/best_model.onnx"
METADATA_PATH    = "./models/16_04/metadata.json"

# Fallback to root model folder if 16_04 is missing
if not os.path.exists(ONNX_MODEL_PATH):
    ONNX_MODEL_PATH = "./models/11_04/best_model.onnx"
    METADATA_PATH   = "./models/11_04/metadata.json"


def decode_from_onnx(outputs):
    """
    Convert onnxruntime output list to raw_boxes / raw_scores / raw_classes
    Same semantic as decode_from_depthai but for CPU inference.

    The model outputs two tensors:
      - shape (1, N, 4)  -> boxes
      - shape (1, N, 11) -> scores per class
    We pick them by shape (not by name) so it works regardless of export names.
    """
    boxes_out  = None
    scores_out = None

    for arr in outputs:
        if arr.ndim == 3:
            if arr.shape[-1] == 4:
                boxes_out = arr
            elif arr.shape[-1] == 11:
                scores_out = arr

    if boxes_out is None or scores_out is None:
        raise ValueError(
            f"Unexpected ONNX output shapes: {[o.shape for o in outputs]}"
        )

    raw_classes = np.argmax(scores_out, axis=-1)
    return boxes_out, scores_out, raw_classes


def draw_result(frame, bbox, text, conf, orig_w, orig_h, scale_x, scale_y):
    """
    Draw bounding box and label on the original-size frame.
    bbox is (ymin, xmin, ymax, xmax) in crop-space (0..MODEL_SIZE).
    """
    if bbox is None:
        return frame

    ymin, xmin, ymax, xmax = bbox

    # Scale from model coords back to original image coords
    x1 = int(xmin * scale_x)
    y1 = int(ymin * scale_y)
    x2 = int(xmax * scale_x)
    y2 = int(ymax * scale_y)

    # Clamp to frame
    x1 = max(0, min(x1, orig_w - 1))
    y1 = max(0, min(y1, orig_h - 1))
    x2 = max(0, min(x2, orig_w - 1))
    y2 = max(0, min(y2, orig_h - 1))

    frame = cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
    conf  = float("{:.2f}".format(conf))
    label = f"{text} {conf}"

    font       = cv2.FONT_HERSHEY_SIMPLEX
    font_scale = max(0.7, orig_w / 800)
    thickness  = 2

    (tw, th), _ = cv2.getTextSize(label, font, font_scale, thickness)
    ty = max(y1 - 10, th + 4)

    # Background rectangle for readability
    cv2.rectangle(frame, (x1, ty - th - 4), (x1 + tw + 4, ty + 4), (0, 255, 0), -1)
    cv2.putText(frame, label, (x1 + 2, ty), font, font_scale, (0, 0, 0), thickness)

    return frame


def process_test_image(image_bytes):
    """
    Process a single image with the ONNX OCR model.

    Returns:
        dict: {
            'success': bool,
            'imageData': str (base64 JPEG),
            'detections': list of {'text': str, 'confidence': float}
        }
    """
    try:
        # ------------------------------------------------------------------ #
        # 1. Decode image
        # ------------------------------------------------------------------ #
        nparr = np.frombuffer(image_bytes, np.uint8)
        img   = cv2.imdecode(nparr, cv2.IMREAD_COLOR)

        if img is None:
            return {'success': False, 'error': 'Failed to decode image'}

        orig_h, orig_w = img.shape[:2]

        # ------------------------------------------------------------------ #
        # 2. Load model & anchors (once per call – acceptable for test tool)
        # ------------------------------------------------------------------ #
        if not os.path.exists(ONNX_MODEL_PATH):
            return {'success': False,
                    'error': f'ONNX model not found: {ONNX_MODEL_PATH}'}
        if not os.path.exists(METADATA_PATH):
            return {'success': False,
                    'error': f'metadata.json not found: {METADATA_PATH}'}

        sess    = ort.InferenceSession(ONNX_MODEL_PATH,
                                       providers=['CPUExecutionProvider'])
        anchors = load_tflite_anchors(METADATA_PATH)

        # ------------------------------------------------------------------ #
        # 3. Pre-process: resize image to 384×384, normalise to [-1, 1]
        #    pre_process expects RGB (PIL standard), cv2 loads BGR → convert
        # ------------------------------------------------------------------ #
        input_name = sess.get_inputs()[0].name
        img_rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        preprocessed = pre_process(img_rgb, (MODEL_HEIGHT, MODEL_WIDTH))   # (1,H,W,3) float32

        # ONNX model uses NCHW format → transpose (1,H,W,C) → (1,C,H,W)
        input_shape = sess.get_inputs()[0].shape   # e.g. [1, 3, 384, 384] or [1, 384, 384, 3]
        if len(input_shape) == 4 and input_shape[1] in (1, 3):
            # NCHW expected
            preprocessed = preprocessed.transpose(0, 3, 1, 2)   # (1,3,H,W)

        # ------------------------------------------------------------------ #
        # 4. Run ONNX inference
        # ------------------------------------------------------------------ #
        raw_outputs = sess.run(None, {input_name: preprocessed})
        raw_boxes, raw_scores, raw_classes = decode_from_onnx(raw_outputs)

        # ------------------------------------------------------------------ #
        # 5. Post-process (NMS + decode boxes)
        # ------------------------------------------------------------------ #
        processed_boxes, processed_scores, processed_classes = post_process(
            raw_boxes, raw_scores, raw_classes,
            anchors,
            score_threshold=SCORE_THRESHOLD,
            iou_threshold=IOU_THRESHOLD,
        )

        # ------------------------------------------------------------------ #
        # 6. Interpret detections (same logic as read_number in read_number.py)
        #    but we work directly in model-space coords (0..1 fraction)
        #    and scale back to original image size.
        # ------------------------------------------------------------------ #
        processed_img = img.copy()
        detections    = []

        # Scale factors: model coords are 0..MODEL_SIZE (pixels in 384 space)
        # We fed the full image cropped to the model, so scale back to original
        scale_x = orig_w / MODEL_WIDTH
        scale_y = orig_h / MODEL_HEIGHT

        bbox_list             = []
        confidence_list       = []
        xmin_and_number_list  = []

        if len(processed_classes) > 0:
            for box, score, class_id in zip(processed_boxes,
                                            processed_scores,
                                            processed_classes):
                ymin, xmin, ymax, xmax = box
                # model outputs are 0-1 fractions of MODEL_SIZE
                xmin_px = int(xmin * MODEL_WIDTH)
                ymin_px = int(ymin * MODEL_HEIGHT)
                xmax_px = int(xmax * MODEL_WIDTH)
                ymax_px = int(ymax * MODEL_HEIGHT)

                bbox_list.append((ymin_px, xmin_px, ymax_px, xmax_px))
                confidence_list.append(float(score))

                digit = translate_id_to_class(class_id)
                if digit:
                    xmin_and_number_list.append((xmin_px, digit))

        # Build combined bounding box
        combined_bbox = None
        if bbox_list:
            combined_bbox = (
                min(b[0] for b in bbox_list),
                min(b[1] for b in bbox_list),
                max(b[2] for b in bbox_list),
                max(b[3] for b in bbox_list),
            )

        confidence_avg = (sum(confidence_list) / len(confidence_list)
                          if confidence_list else 0.0)

        # ------------------------------------------------------------------ #
        # 7. Draw result — only when digits are actually detected
        #    Test mode: no 888/999 fallback, no digit-count limit
        # ------------------------------------------------------------------ #
        if xmin_and_number_list:
            sorted_digits = sorted(xmin_and_number_list, key=lambda x: x[0])
            text = "".join(d for _, d in sorted_digits)

            # Letter prefix (A-Z) left of the digits - optional CPU recognizer,
            # same model/logic as the camera's enableLetterRead feature
            try:
                from utils.text_rec_cpu import read_letter_prefix_cpu
                bx1 = int(combined_bbox[1] * scale_x)
                by1 = int(combined_bbox[0] * scale_y)
                bx2 = int(combined_bbox[3] * scale_x)
                by2 = int(combined_bbox[2] * scale_y)
                prefix = read_letter_prefix_cpu(img, bx1, by1, bx2, by2)
                if prefix:
                    text = f"{prefix}{text}"
            except Exception:
                pass  # letter reading is best-effort in the test tool

            # Draw combined bounding box + label
            processed_img = draw_result(
                processed_img, combined_bbox, text, confidence_avg,
                orig_w, orig_h, scale_x, scale_y
            )

            # Draw individual digit boxes (light blue)
            for (ymin_px, xmin_px, ymax_px, xmax_px), score, class_id in zip(
                    bbox_list, confidence_list, processed_classes):
                digit = translate_id_to_class(class_id)
                if digit:
                    x1 = int(xmin_px * scale_x)
                    y1 = int(ymin_px * scale_y)
                    x2 = int(xmax_px * scale_x)
                    y2 = int(ymax_px * scale_y)
                    cv2.rectangle(processed_img, (x1, y1), (x2, y2), (255, 200, 0), 1)

            detections.append({'text': text, 'confidence': round(confidence_avg, 4)})
        # If nothing detected → return original image with no drawing, empty detections

        # ------------------------------------------------------------------ #
        # 8. Encode result as base64 JPEG
        # ------------------------------------------------------------------ #
        _, buffer  = cv2.imencode('.jpg', processed_img)
        img_base64 = base64.b64encode(buffer).decode('utf-8')

        return {
            'success': True,
            'imageData': img_base64,
            'detections': detections,
        }

    except Exception as e:
        import traceback
        traceback.print_exc()
        return {'success': False, 'error': str(e)}


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import json

    if len(sys.argv) > 1:
        image_path = sys.argv[1]
        try:
            with open(image_path, 'rb') as f:
                image_bytes = f.read()
            result = process_test_image(image_bytes)
            print(json.dumps(result))
            sys.exit(0 if result['success'] else 1)
        except Exception as e:
            print(json.dumps({'success': False, 'error': str(e)}))
            sys.exit(1)
    else:
        print(json.dumps({'success': False, 'error': 'No image path provided'}))
        sys.exit(1)
