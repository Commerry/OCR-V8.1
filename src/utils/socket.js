import { Server } from "socket.io";
import socketLog from "./socketLog";

const createSocketServer = (server) => {
  const io = new Server(server, {
    cors: {
      origin: "*",
    },
  });

  io.on("connection", (socket) => {
    socketLog("all", socket, "socket connected");

    socket.on("disconnect", () => {
      socketLog("all", socket, "socket disconnected");
    });
  });

  return io;
};

export default createSocketServer;
