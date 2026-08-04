import cv2
import numpy as np


def center_crop(frame, x_percent, y_percent):
    width, height = frame.shape[1], frame.shape[0]

    crop_width = int(width * x_percent / 100)
    crop_height = int(height * y_percent / 100)

    crop_width = crop_width if crop_width < frame.shape[1] else frame.shape[1]
    crop_height = crop_height if crop_height < frame.shape[0] else frame.shape[0]
    mid_x, mid_y = int(width/2), int(height/2)
    cw2, ch2 = int(crop_width/2), int(crop_height/2)
    crop_img = frame[mid_y-ch2:mid_y+ch2, mid_x-cw2:mid_x+cw2]
    return crop_img


def sharpen(frame):
    kernel = np.array([[0, -1, 0], [-1, 5, -1], [0, -1, 0]])
    kernel = np.array([[-1, -1, -1], [-1, 9, -1], [-1, -1, -1]])
    frame = cv2.filter2D(frame, -1, kernel)
    return frame


def denoise(frame):
    return cv2.fastNlMeansDenoising(frame, None, 20, 7, 14)


def resize(frame, max_width):
    # RESIZE
    scale = max_width / frame.shape[1]
    frame = cv2.resize(frame, (0, 0), fx=scale, fy=scale)

    return frame


def contrast(img, contrast_ratio):
    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
    l_channel, a, b = cv2.split(lab)

    clip_limit = contrast_ratio
    tile_grid_size = (contrast_ratio * 4, contrast_ratio * 4)

    clahe = cv2.createCLAHE(clipLimit=clip_limit, tileGridSize=tile_grid_size)
    cl = clahe.apply(l_channel)

    l_img = cv2.merge((cl, a, b))

    enhanced_img = cv2.cvtColor(l_img, cv2.COLOR_LAB2BGR)

    return enhanced_img

