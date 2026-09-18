window.YTBackend = (() => {

  // 已经帮你填好 Apps Script Web App
  const API_URL =
    "https://script.google.com/macros/s/AKfycbzCFtnhDubjakfhj3fbdDKa7hUZ0eJV6GCfc62TqQkwWETfTkvcglbip1sYxcuI4hqlNg/exec";

  const configured = () =>
    /^https:\/\/script\.google\.com\/macros\/s\/.+\/exec$/.test(API_URL);

  async function post(action, data = {}) {

    if (!configured()) {
      return {
        ok: false,
        offline: true,
        error: "backend_not_configured"
      };
    }

    try {

      const response = await fetch(API_URL, {
        method: "POST",
        headers: {
          "Content-Type": "text/plain;charset=utf-8"
        },
        body: JSON.stringify({
          action,
          ...data
        })
      });

      const text = await response.text();

      try {
        return JSON.parse(text);
      } catch (e) {
        console.error("YETIPSY API returned non-JSON:", text);

        return {
          ok: false,
          error: "invalid_backend_response",
          raw: text
        };
      }

    } catch (e) {

      console.error("YETIPSY Backend Error:", e);

      return {
        ok: false,
        error: String(e)
      };
    }
  }

  return {

    configured,

    join: (p) =>
      post("join", p),

    heartbeat: (p) =>
      post("heartbeat", p),

    status: (p) =>
      post("status", p),

    // TABLE SYNC
    tableState: (p) =>
      post("tableState", p),

    startCountdown: (p) =>
      post("startCountdown", p),

    nextTableRound: (p) =>
      post("nextTableRound", p),

    // MATCH
    queue: (p) =>
      post("queue", p),

    matchStatus: (p) =>
      post("matchStatus", p),

    // VERIFICATION
    verify: (p) =>
      post("verify", p),

    complete: (p) =>
      post("complete", p)
  };

})();
