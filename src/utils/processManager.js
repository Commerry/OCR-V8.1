import fs from "fs-extra";

const pidFile = "pidlog.json";
fs.ensureFileSync(pidFile);

const killProcess = (pid) => {
  try {
    process.kill(pid);
    return true;
  } catch (e) {
    if (e.toString().indexOf("ESRCH") > -1) {
      return true;
    } else {
      console.error(e);
      return false;
    }
  }
};

const readPIdFileContent = () => {
  const pidLog = fs.readFileSync(pidFile, "utf8");
  let content = {};
  try {
    content = JSON.parse(pidLog);
  } catch (e) {
    content = {};
  }
  return content;
};

const savePId = (cameraName, pid) => {
  const content = readPIdFileContent();
  if (typeof content[cameraName] === "undefined") {
    content[cameraName] = [];
  }
  content[cameraName].push(pid);
  fs.writeFileSync(pidFile, JSON.stringify(content));
};

const killProcessByCameraName = (cameraName) => {
  let isFound = false;
  const content = readPIdFileContent();
  if (
    typeof content[cameraName] !== "undefined" &&
    content[cameraName].length > 0
  ) {
    isFound = true;
    content[cameraName].forEach((pid) => {
      killProcess(pid);
    });
    content[cameraName] = [];
    fs.writeFileSync(pidFile, JSON.stringify(content));
  }

  return isFound;
};

const killAll = () => {
  const content = readPIdFileContent();
  Object.keys(content).forEach((cameraName) => {
    killProcessByCameraName(cameraName);
  });
};

export default {
  killAll,
  savePId,
  killProcessByCameraName,
};
