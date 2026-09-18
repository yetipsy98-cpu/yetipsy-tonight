window.YTBackend = (() => {
  const API_URL =
    "https://script.google.com/macros/s/AKfycbzCFtnhDubjakfhj3fbdDKa7hUZ0eJV6GCfc62TqQkwWETfTkvcglbip1sYxcuI4hqlNg/exec";

  const TIMEOUT = 9000;

  const configured = () =>
    /^https:\/\/script\.google\.com\/macros\/s\/.+\/exec$/.test(API_URL);

  async function post(action, data = {}) {
    if (!configured()) {
      return { ok: false, error: "backend_not_configured" };
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TIMEOUT);

    try {
      const response = await fetch(API_URL, {
        method: "POST",
        headers: { "Content-Type": "text/plain;charset=utf-8" },
        body: JSON.stringify({ action, ...data }),
        signal: controller.signal
      });

      const text = await response.text();

      try {
        return JSON.parse(text);
      } catch {
        return { ok: false, error: "invalid_backend_response", raw: text.slice(0, 180) };
      }
    } catch (e) {
      if (e.name === "AbortError") return { ok: false, error: "timeout" };
      return { ok: false, error: "network_error", detail: String(e) };
    } finally {
      clearTimeout(timer);
    }
  }

  return {
    configured,
    join: p => post("join", p),
    heartbeat: p => post("heartbeat", p),
    tableState: p => post("tableState", p),
    startTable: p => post("startTable", p),
    claimLead: p => post("claimLead", p),
    finishCountdown: p => post("finishCountdown", p),
    nextTableRound: p => post("nextTableRound", p),
    startEvent: p => post("startEvent", p),
    completeEvent: p => post("completeEvent", p),
    queue: p => post("queue", p),
    matchStatus: p => post("matchStatus", p),
    verify: p => post("verify", p),
    cancelMatch: p => post("cancelMatch", p),
    completeMatch: p => post("completeMatch", p)
  };
})();
