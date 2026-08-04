from utils.mobilenet import (
    decode_from_depthai,
    post_process,
    translate_id_to_class,
)


# ถ้าไม่เจอ ได้888
# ถ้ามากกว่าสามหลัก 999
def read_number(nn_det_in, anchors, score_threshold, iou_threshold, crop_width, crop_height):
    
    bbox_list = []
    confidence_list=[]
    xmin_and_number_list = []
    incoming_text = 888
    bbox = None
    confidence_avg = 0

    if nn_det_in is not None:
        raw_boxes, raw_scores, raw_classes = decode_from_depthai(nn_det_in)
        processed_boxes, processed_scores, processed_classes = post_process(
            raw_boxes,
            raw_scores,
            raw_classes,
            anchors,
            score_threshold=score_threshold,
            iou_threshold=iou_threshold,
        )
        # ตรวจหา incoming_text
        if len(processed_classes) > 0:
            for box, score, class_id in zip(
                    processed_boxes, processed_scores, processed_classes
            ):
                ymin, xmin, ymax, xmax = box
                xmin = int(xmin * crop_width)
                ymin = int(ymin * crop_height)
                xmax = int(xmax * crop_width)
                ymax = int(ymax * crop_height)
                # เก็บ boxที่เจอ
                bbox_list.append((ymin, xmin, ymax, xmax))
                # เก็บ scoreที่เจอ
                confidence_list.append(score)
                # translate ID to Class
                real_number = translate_id_to_class(class_id)
                # เก็บ เลขและต่ำแหน่งที่เจอ
                xmin_and_number_list.append((xmin, real_number))
                
            # รวม bbox list เป็นกล่องใหญ่
            if len(bbox_list) > 0:
                min_ymin = min(b[0] for b in bbox_list)
                min_xmin = min(b[1] for b in bbox_list)
                max_ymax = max(b[2] for b in bbox_list)
                max_xmax = max(b[3] for b in bbox_list)
                # กล่องใหญ่
                bbox = (min_ymin, min_xmin, max_ymax, max_xmax)

            # หาค่าเฉลี่ยของกล่องใหญ่
            if len(confidence_list) > 0:
                # ค่าเฉลี่ยน confidence
                confidence_avg = sum(confidence_list) / len(confidence_list)

            # หาตัวเลข ทำเป็นstring
            if len(xmin_and_number_list) > 0:
                # 1. เรียงตามตำแหน่ง x
                sorted_list = sorted(xmin_and_number_list, key=lambda x: x[0])

                # 2. ดึงเฉพาะตัวเลขออกมาและแปลงเป็น string
                sorted_numbers = [str(x[1]) for x in sorted_list]

                # 3. รวมเป็น string เดียว
                text = "".join(sorted_numbers)
                # ค่าตัวเลขที่อ่านได้
                incoming_text = int(text)
                if incoming_text > 999 or incoming_text == 0:
                    incoming_text = 999

       

    return incoming_text, bbox, confidence_avg
    