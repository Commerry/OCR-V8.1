import serverResponse from "./serverResponse";

const methodResolvers = async (
  resolvers,
  method,
  req,
  res,
  io,
  generateContext = null
) => {
  const resolver = req.params.endpoint;
  try {
    if (resolver && typeof resolvers[resolver] !== "undefined") {
      let context = {};
      if (generateContext) {
        context = (await generateContext(req, res, io)) || {};
      }

      let params = {};

      params = req.query;

      if (method === "POST") {
        if (req.headers["content-type"] === "application/json") {
          const bodyJSON = await req.body;
          params = { ...params, ...bodyJSON };
        } else {
          params = { ...params };

          if (req.files) {
            params.files = req.files;
          }
          if (req.formData) {
            const formDataObject = await req.formData();
            for (const pair of formDataObject.entries()) {
              params[pair[0]] = pair[1];
            }
          }
          if (req.body) {
            params = { ...params, ...req.body };
          }
        }
      }

      const result = await resolvers[resolver](params, context);
      res.json(result);
      return true;
    } else {
      console.error("resolver not found");
      throw "resolver not found";
    }
  } catch (e) {
    console.error(resolver, e);
    res.json(serverResponse.error(e));
    return true;
  }
};

export default methodResolvers;
