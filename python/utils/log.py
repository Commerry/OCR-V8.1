import time

log_count = 0


def log(text, write_to_file=False):
    global log_count
    log_count += 1
    if log_count > 999:
        log_count = 0

    current_time = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())

    line = f"{current_time}, {log_count}: {text}"
    print(line, flush=True)

    if write_to_file:
        with open("log.txt", "a") as f:
            f.write(f"{line}\n")
            f.flush()
        f.close()