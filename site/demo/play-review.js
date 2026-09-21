// Muffin Manor — the second run's game. Same contract as play-pure.js: this file only says where
// to click, Chrome does the clicking, and the move comes from the game's own hint finder.
(() => {
  const centre = (node) => {
    const r = node.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  };
  const visible = (node) => !!node && !!node.offsetParent
    && getComputedStyle(node).visibility !== 'hidden';

  // Same rule as the other two: only frames of the board itself are kept.
  const inPlay = () => {
    const mm = window.MM;
    return !!mm && !!mm.game && mm.game.active && !mm.game.finished && !mm.UI.openId;
  };
  const frame = (acts) => (acts ? { acts, record: inPlay() } : { record: inPlay() });

  let cooldown = 0;
  const done = { home: false, node: false, start: false };

  window.__director = {
    step() {
      if (cooldown > 0) { cooldown -= 1; return frame(null); }

      const ui = window.MM && window.MM.UI;

      // A first visit opens "How to play" over the home screen, and its own close button is the
      // way past it. Without this the recording was sixteen seconds of the instructions.
      if (ui && ui.openId && ui.openId !== 'dlg-prelevel') {
        const x = document.querySelector(`#${ui.openId} .dlg-x`);
        if (visible(x)) {
          cooldown = 8;
          return frame([{ t: 'click', ...centre(x) }]);
        }
      }

      const play = document.querySelector('#btn-play');
      if (!done.home && !(ui && ui.openId) && visible(play)) {
        done.home = true;
        cooldown = 12;
        return frame([{ t: 'click', ...centre(play) }]);
      }

      const node = document.querySelector('#map-inner .node.current:not(.locked)')
        || document.querySelector('#map-inner .node:not(.locked)');
      if (done.home && !done.node && visible(node)) {
        done.node = true;
        cooldown = 10;
        return frame([{ t: 'click', ...centre(node) }]);
      }

      const start = document.querySelector('#btn-start');
      if (done.node && !done.start && visible(start)) {
        done.start = true;
        cooldown = 20;
        return frame([{ t: 'click', ...centre(start) }]);
      }

      const mm = window.MM;
      if (!mm || !mm.game || !mm.game.canAcceptInput()) return frame(null);
      const hint = mm.game.board.findHint();
      if (!hint) return frame(null);

      const box = mm.renderer.canvas
        ? mm.renderer.canvas.getBoundingClientRect()
        : document.querySelector('canvas').getBoundingClientRect();
      // This renderer works in the canvas's BACKING-STORE pixels — its own input code divides by
      // `dpr` before comparing with a finger — so a centre has to be divided back down before it
      // means anything to the mouse. Without it every click landed a couple of cells away, the
      // board never matched anything, and the score sat at zero for the whole recording.
      const dpr = mm.renderer.dpr || 1;
      const at = (r, c) => {
        const [x, y] = mm.renderer.cellCenter(r, c);
        return { x: box.left + x / dpr, y: box.top + y / dpr };
      };
      const [r1, c1, r2, c2] = hint;
      cooldown = 7;
      return frame([
        { t: 'click', ...at(r1, c1) },
        { t: 'wait', ms: 140 },
        { t: 'click', ...at(r2, c2) },
      ]);
    },
  };
})()
