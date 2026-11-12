// Backline: proof-of-origin (PO) token minting for YouTube (R01p), run in a hidden WKWebView on a blank
// page whose origin is www.youtube.com. A port of the parts of bgutils-js 4.0.3 (MIT, (c) 2024 LuanRT)
// that BotGuard needs: load the VM, take a snapshot, build the minter from the integrity token, mint.
// The challenge payload from YouTube's homepage is parsed as data and never evaluated; the only code that
// runs besides this file is Google's BotGuard interpreter, which Swift fetches from www.google.com/js/th/.
(() => {
  const withTimeout = (promise, ms, what) => Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(what + ' timed out')), ms)),
  ]);

  // bgutils' parseLooseJSON: the homepage's `window.ytAtN({...})` argument is a JavaScript object literal
  // with single-quoted, \x-escaped strings; its `R` value is a JSON string.
  const parseLooseJSON = (loose) => {
    const unhexed = loose.replace(/\\x([0-9A-Fa-f]{2})/g, (_m, hex) => String.fromCharCode(parseInt(hex, 16)));
    let json = unhexed.replace(/,\s*([\]}])/g, '$1');
    json = json.replace(/'((?:[^'\\]|\\[\s\S])*)'/g, (_m, inner) => JSON.stringify(inner.replace(/\\'/g, '\'')));
    json = json.replace(/([{,]\s*)([a-zA-Z0-9_$]+)\s*:/g, '$1"$2":');
    const parsed = JSON.parse(json);
    for (const key in parsed) {
      const v = parsed[key];
      if (typeof v === 'string' && /^\s*[{[]/.test(v)) {
        try { parsed[key] = JSON.parse(v); } catch (_) { /* keep the string */ }
      }
    }
    return parsed;
  };

  const base64ToU8 = (b64) => {
    const plain = b64.replace(/[-_.]/g, (c) => ({ '-': '+', '_': '/', '.': '=' })[c]);
    return Uint8Array.from(atob(plain), (c) => c.charCodeAt(0));
  };
  const u8ToBase64Url = (u8) => btoa(String.fromCharCode(...u8)).replace(/\+/g, '-').replace(/\//g, '_');

  let signals = null;
  let mintFn = null;

  window.backlinePot = {
    /// The BotGuard challenge in the homepage's ytAtN payload; `ytcfg` becomes `yt.config_`, which
    /// BotGuard reads (EVENT_ID).
    challenge(atnText, ytcfgText) {
      const atn = parseLooseJSON(atnText);
      const c = atn && atn.R && atn.R.bgChallenge;
      if (!c || !c.program || !c.globalName || !c.interpreterUrl) throw new Error('no BotGuard challenge');
      window.yt = { config_: JSON.parse(ytcfgText) };
      return {
        program: c.program,
        globalName: c.globalName,
        interpreterUrl: c.interpreterUrl.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue,
      };
    },

    /// Loads the program into the VM the interpreter defined and takes one snapshot; returns the
    /// BotGuard response for GenerateIT.
    async snapshot(program, globalName) {
      const vm = window[globalName];
      if (!vm || typeof vm.a !== 'function') throw new Error('BotGuard unavailable');
      let ready;
      const functions = new Promise((resolve) => { ready = resolve; });
      const setup = (asyncSnapshot, shutdown) => ready({ asyncSnapshot, shutdown });
      const noop = () => {};
      vm.a(program, setup, true, undefined, noop, [[], []], undefined, false, [noop, noop, noop, noop, noop]);
      const f = await withTimeout(functions, 10000, 'BotGuard load');
      signals = [];
      return await withTimeout(new Promise((resolve) => {
        f.asyncSnapshot((response) => resolve(response), [undefined, undefined, signals, undefined]);
      }), 10000, 'BotGuard snapshot');
    },

    /// Builds the minter from GenerateIT's integrity token.
    async minter(integrityToken) {
      const getMinter = signals && signals[0];
      if (typeof getMinter !== 'function') throw new Error('no minter from BotGuard');
      mintFn = await withTimeout(Promise.resolve(getMinter(base64ToU8(integrityToken))), 10000, 'minter');
      if (typeof mintFn !== 'function') throw new Error('minter unavailable');
      return true;
    },

    /// One token, bound to a visitor data string, a data sync id or a video id; web-safe base64.
    async mint(binding) {
      if (!mintFn) throw new Error('no minter');
      const out = await withTimeout(Promise.resolve(mintFn(new TextEncoder().encode(binding))), 10000, 'mint');
      if (!(out instanceof Uint8Array)) throw new Error('mint failed');
      return u8ToBase64Url(out);
    },
  };
})();
