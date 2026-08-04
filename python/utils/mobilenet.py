import numpy as np
import json
from PIL import Image
import cv2

def load_tflite_anchors(metadata_path):
    with open(metadata_path, "r") as f:
        metadata = json.load(f)

    # เข้าถึง anchor data ในโครงสร้างที่ซับซ้อน
    try:
        anchor_data = []
        for subgraph in metadata.get("subgraph_metadata", []):
            for meta in subgraph.get("custom_metadata", []):
                if meta.get("name") == "DETECTOR_METADATA":
                    anchors = meta["data"]["ssd_anchors_options"][
                        "fixed_anchors_schema"
                    ]["anchors"]
                    for anchor in anchors:
                        cx = anchor["x_center"]
                        cy = anchor["y_center"]
                        width = anchor["width"]
                        height = anchor["height"]
                        anchor_data.append([cy, cx, height, width])
                    break

        if not anchor_data:
            raise ValueError("No anchors found in metadata")

        return np.array(anchor_data)

    except KeyError as e:
        raise ValueError(f"Invalid metadata format: {str(e)}")


def decode_boxes(boxes, anchors, scale_factors=(1.0, 1.0, 1.0, 1.0)):

    new_boxes = []
    for i, anchor in enumerate(anchors):
        box = boxes[i]
        y = box[0]
        x = box[1]
        h = box[2]
        w = box[3]

        y_scale, x_scale, h_scale, w_scale = scale_factors
        anchor_cy, anchor_cx, anchor_h, anchor_w = anchor

        ycenter = (y / y_scale) * anchor_h + anchor_cy
        xcenter = (x / x_scale) * anchor_w + anchor_cx
        half_h = 0.5 * np.exp(h / h_scale) * anchor_h
        half_w = 0.5 * np.exp(w / w_scale) * anchor_w
        xmin = xcenter - half_w
        ymin = ycenter - half_h
        ymax = ycenter + half_h
        xmax = xcenter + half_w
        new_boxes.append([ymin, xmin, ymax, xmax])

    return np.array(new_boxes)



def box_iou(boxes1, boxes2):
    
    # ดึงพิกัด x1, y1, x2, y2 ของทั้งสองชุด
    x1, y1, x2, y2 = boxes1[:, 0], boxes1[:, 1], boxes1[:, 2], boxes1[:, 3]
    x1_, y1_, x2_, y2_ = boxes2[:, 0], boxes2[:, 1], boxes2[:, 2], boxes2[:, 3]
    
    # คำนวณพื้นที่ของแต่ละกล่อง
    area1 = (x2 - x1) * (y2 - y1)
    area2 = (x2_ - x1_) * (y2_ - y1_)
    
    # คำนวณขอบเขตของการทับซ้อน (Intersection)
    inter_x1 = np.maximum(x1, x1_)
    inter_y1 = np.maximum(y1, y1_)
    inter_x2 = np.minimum(x2, x2_)
    inter_y2 = np.minimum(y2, y2_)
    
    # คำนวณพื้นที่ที่ทับซ้อนกัน
    inter_area = np.maximum(0, inter_x2 - inter_x1) * np.maximum(0, inter_y2 - inter_y1)
    
    # คำนวณค่า IoU
    union_area = area1 + area2 - inter_area
    iou = inter_area / union_area
    
    return iou


def suppress_overlapping_classes(boxes, scores, classes, iou_threshold=0.5):
    boxes = np.array(boxes, dtype=np.float32)
    scores = np.array(scores, dtype=np.float32)
    classes = np.array(classes, dtype=np.int64)

    keep = []
    suppressed = set()

    # เรียงคะแนนจากมากไปน้อย
    sorted_indices = np.argsort(scores)[::-1]
    
    for i in sorted_indices:
        if i in suppressed:
            continue

        keep.append(i)
        ious = box_iou(boxes[i].reshape(1, -1), boxes)  # คำนวณ IoU ระหว่างกล่อง i กับกล่องทุกตัวใน boxes

        # หา index ของกล่องที่ซ้อนกัน
        overlap_indices = np.where(ious > iou_threshold)[0]

        for j in overlap_indices:
            if j != i:
                suppressed.add(j)

    return boxes[keep], scores[keep], classes[keep]


def pre_process(cvframe, input_size):
    cvframe = cv2.resize(cvframe, input_size)
    # อ่านรูปภาพ
    image = Image.fromarray(cvframe)
    original_size = image.size[::-1]  # (height, width)

    # แปลงเป็น RGB ถ้าจำเป็น
    if image.mode != "RGB":
        image = image.convert("RGB")

    # resize โดยรักษา aspect ratio
    img_height, img_width = input_size
    scale = min(img_height / original_size[0], img_width / original_size[1])
    new_height = int(original_size[0] * scale)
    new_width = int(original_size[1] * scale)

    image = image.resize((new_width, new_height), Image.Resampling.BILINEAR)
   
    # สร้าง padding
    delta_h = img_height - new_height
    delta_w = img_width - new_width
    top = delta_h // 2
    left = delta_w // 2

    # สร้าง canvas สีดำ
    new_image = Image.new("RGB", (img_width, img_height), (0, 0, 0))
    new_image.paste(image, (left, top))
    
    # แปลงเป็น numpy array และ normalize
    img_array = np.asarray(new_image, dtype=np.float32)
    # normalize to [-1, 1]
    img_array = (img_array - 127.5) / 127.5

    # เพิ่มมิติ batch
    img_array = np.expand_dims(img_array, axis=0)

    return img_array

def post_process(
    raw_boxes, raw_scores, raw_classes, anchors, score_threshold=0.5, iou_threshold=0.5
):
    # ลดมิติที่ไม่จำเป็น
    boxes = np.squeeze(raw_boxes)
    scores = np.squeeze(raw_scores)
    classes = np.squeeze(raw_classes)

    # print("classes",raw_classes.tolist())   
    filtered_boxes = []
    filtered_classes = []
    filtered_scores = []
    filtered_idx = []
    for idx, cls_scores in enumerate(scores):
        # print("classes", classes[idx])

        class_idx = classes[idx]
        score = cls_scores[class_idx]
        if score >= score_threshold:
            filtered_idx.append(idx)
            filtered_boxes.append(boxes[idx])
            filtered_classes.append(class_idx)
            filtered_scores.append(score)

    anchors = anchors[filtered_idx]
    boxes = np.array(filtered_boxes)
    classes = np.array(filtered_classes)
    scores = np.array(filtered_scores)

    if len(filtered_idx) == 0:
        return np.array([]), np.array([]), np.array([])

    # ถอดรหัสกล่อง
    boxes = decode_boxes(boxes, anchors, scale_factors=(1.0, 1.0, 1.0, 1.0))
    
    # กรองและทำ NMS
    return suppress_overlapping_classes(boxes, scores, classes, iou_threshold)



def run_inference(interpreter, preprocessed_image):
    # Get input details
    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()

    # Check input type
    if input_details[0]["dtype"] != preprocessed_image.dtype:
        print(
            f"Converting input from {preprocessed_image.dtype} to {input_details[0]['dtype']}"
        )
        preprocessed_image = preprocessed_image.astype(input_details[0]["dtype"])
        print("preprocessed_image",preprocessed_image)
    # Set input tensor
    interpreter.set_tensor(input_details[0]["index"], preprocessed_image)

    # Run inference
    interpreter.invoke()

    # Get outputs
    boxes = interpreter.get_tensor(output_details[0]["index"])
    scores = interpreter.get_tensor(output_details[1]["index"])
    classes = np.argmax(scores, axis=-1)

    return boxes, scores, classes

def translate_id_to_class(class_id):
    id_class_map = {
        0:"",
        1:"1",
        2:"2",
        3:"3",
        4:"4",
        5:"5",
        6:"6",
        7:"7",
        8:"8",
        9:"9",
        10:"0",
    }
    return id_class_map.get(int(class_id))


def decode_from_depthai(layer_list):
    layer_name_list = layer_list.getAllLayerNames()
    layer1_data = layer_list.getLayerFp16(layer_name_list[0])
    layer2_data = layer_list.getLayerFp16(layer_name_list[1])

    np1 = np.array(layer1_data)
    np2 = np.array(layer2_data)

    raw_boxes = np1.reshape((1, -1, 4))
    raw_scores = np2.reshape((1, -1, 11))
    raw_classes = np.argmax(raw_scores, axis=-1)

    return raw_boxes, raw_scores, raw_classes