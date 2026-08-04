import Redis from "ioredis";

let client = null;
const getClient = async () => {
  if (!client) {
    client = new Redis();
  }
  return client;
};

export default getClient;
