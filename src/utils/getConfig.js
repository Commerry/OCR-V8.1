import fs from 'fs-extra';

const getConfig = () => {
  const configFileName = 'config.json';
  fs.ensureFileSync(configFileName);
  const configFileContent = fs.readFileSync(configFileName).toString();
  let config = {};
  try {
    config = JSON.parse(configFileContent) || {};
  } catch (e) {
    config = {};
  }
  return config;
};

const saveConfig = (config) => {
  const configFileName = 'config.json';
  fs.writeFileSync(configFileName, JSON.stringify(config));
};

export { saveConfig, getConfig };
