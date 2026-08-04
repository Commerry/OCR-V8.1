import moment from "./moment";

const socketLog = (cameraName, io, message) => {
  // console.info(`socket log_${cameraName}:`, message);
  io.emit(`log_${cameraName}`, {
    time: moment().format("HH:mm:ss"),
    message,
  });
};

export default socketLog;
