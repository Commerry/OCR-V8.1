import cv2
import base64
from io import BytesIO
from PIL import Image


def send_frame(r, frame_name, camera_name, frame):
    image = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
    buffer = BytesIO()
    image.save(buffer, format="webp", quality=50)
    base64_image = base64.b64encode(buffer.getvalue()).decode("utf-8")

    r.publish(frame_name, f"{camera_name} {base64_image}")
