#!/usr/bin/env python3
import depthai as dai
import subprocess
import os
import time

folder = "4"

mx = os.getenv("MX", "10.15.161.22")
cam_name = os.getenv("CAM_NAME", "video")

# if os.path.exists(f"{cam_name}.h264"):
#     os.remove(f"{cam_name}.h264")

print("cam_name", cam_name)

pipeline = dai.Pipeline()

cam_rgb = pipeline.create(dai.node.ColorCamera)
cam_rgb.setBoardSocket(dai.CameraBoardSocket.CAM_A)

video_encoder = pipeline.create(dai.node.VideoEncoder)
video_encoder.setDefaultProfilePreset(30, dai.VideoEncoderProperties.Profile.H264_HIGH)
cam_rgb.video.link(video_encoder.input)

xout = pipeline.create(dai.node.XLinkOut)
xout.setStreamName("xout")
video_encoder.bitstream.link(xout.input)

# Connect to device and start pipeline


with dai.Device(deviceInfo=dai.DeviceInfo("10.15.161.22")) as dev:
    dev.startPipeline(pipeline)
    out = dev.getOutputQueue(name="xout", maxSize=30, blocking=True)

    with open(f"{cam_name}.h264", "wb") as file_h265:
        print("Press Ctrl+C to stop encoding...")
        while True:
            try:
                while out.has():
                    out.get().getData().tofile(file_h265)

            except KeyboardInterrupt:
                # Keyboard interrupt (Ctrl + C) detected
                break

# ffmpeg -f -r 30 -i c.txt -c:v copy a.mp4

# while read -r line; do
#     fname=$(echo "$line" | cut -d"'" -f2)         # ดึงชื่อไฟล์ออกจาก 'vid1.h264'
#     base="${fname%.*}"                            # ตัดนามสกุลออก → vid1
#     ffmpeg -framerate 30 -i "$fname" -c:v copy "${base}.mp4"
# done < c.txt