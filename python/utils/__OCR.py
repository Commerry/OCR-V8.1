from paddleocr import PaddleOCR, draw_ocr
import numpy as np
import cv2


class OCR:
    def __init__(self, drop_score=0.8):
        det_model_dir = "./models/det/en_PP-OCRv3_det_slim_infer"
        rec_model_dir = "./models/rec/en_PP-OCRv3_rec_slim_infer"
        cls_model_dir = "./models/cls/ch_ppocr_mobile_v2.0_cls_slim_infer"
        self.ocr = PaddleOCR(
            det_model_dir=det_model_dir,
            rec_model_dir=rec_model_dir,
            cls_model_dir=cls_model_dir,
            use_angle_cls=False,
            lang='en',
            drop_score=drop_score,
            show_log=False,
        )

    def run_once(self, frame):
        np_image = np.array(frame)
        results = self.ocr.ocr(np_image, cls=False)
        result_bbox = None
        result_text = ""
        result_conf = 0
        if len(results) > 0:
            for index in range(len(results)):
                paragraph = results[index]
                if paragraph is not None:
                    for line in paragraph:
                        conf = line[1][1]
                        if conf > result_conf:
                            result_conf = conf
                            result_text = line[1][0]
                            result_bbox = line[0]
                            top_left = (int(result_bbox[0][0]), int(result_bbox[0][1]))
                            bottom_right = (int(result_bbox[2][0]), int(result_bbox[2][1]))
                            result_bbox = [top_left, bottom_right]
        return result_bbox, result_text, result_conf, results

    def draw(self, processed_frame, bbox, text, conf):
        if bbox is not None:
            processed_frame = cv2.rectangle(processed_frame, bbox[0], bbox[1], (0, 255, 0), 2)
            conf = float("{:.2f}".format(conf))
            processed_frame = cv2.putText(processed_frame, text + " " + str(conf), (bbox[0][0], bbox[0][1] - 10),
                                          cv2.FONT_HERSHEY_SIMPLEX, 2, (0, 255, 0), 2)
        return processed_frame
