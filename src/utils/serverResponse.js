const error = (message) => {
  return {
    isOK: false,
    error: message,
  };
};

const success = async (result) => {
  return {
    isOK: true,
    result: await result,
  };
};

const serverResponse = {
  success,
  error,
};

export default serverResponse;
