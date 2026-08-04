import redis

redisInstance = None


def get_connection():
    global redisInstance
    if redisInstance is None:
        redisInstance = redis.StrictRedis(
            host='localhost', port=6379,  db=0, decode_responses=False)
    return redisInstance


def get_value(key):
    r = get_connection()
    return r.get(key)


def set_value(key, value):
    r = get_connection()
    return r.set(key, value)
