// Kitten Manor — the first run's game, played for the camera.
//
// This file decides WHERE to click; web-video.py does the clicking, through Chrome's own input
// pipeline, so the game receives exactly what a hand at the trackpad would send. Nothing here
// calls the game's logic: every match in the recording went through the page's pointer handlers.
//
// The move itself comes from the game's own hint — the arrow it shows a player who sits idle for
// five seconds. So the recording is a competent player, not a lucky one, and it never stalls on a
// board whose only legal move is in a corner.
(() => {
  const centre = (node) => {
    const r = node.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  };
  const visible = (node) => !!node && !node.hidden && !!node.offsetParent;

  // A frame is worth keeping once the board is up and no card is over it. Everything before
  // that — splash, level map, the goals card — is navigation, and the recorder is told to throw
  // those frames away rather than open every clip on a menu.
  const inPlay = () => {
    const km = window.KM;
    return !!km && !!km.game && !document.querySelector('#overlays .veil')
      && ['ready', 'busy', 'finale'].includes(km.game.state);
  };
  const frame = (acts) => (acts ? { acts, record: inPlay() } : { record: inPlay() });

  let cooldown = 0;        // frames to let an animation finish before looking again
  let tapped = false;      // the splash screen's one button
  let launched = false;    // the level we play

  window.__director = {
    step() {
      if (cooldown > 0) { cooldown -= 1; return frame(null); }

      const splash = document.querySelector('#boot-play');
      if (!tapped && visible(splash)) {
        tapped = true;
        cooldown = 10;
        return frame([{ t: 'click', ...centre(splash) }]);
      }

      const level = document.querySelector('#level-grid .lvl:not(.is-locked)');
      if (!launched && visible(level)) {
        launched = true;
        cooldown = 12;
        return frame([{ t: 'click', ...centre(level) }]);
      }

      // The pre-level card (goals and boosters), and later the "level cleared" card: both are
      // dismissed by their one green button, which is also how a player gets past them.
      //
      // Scoped to the dialog on top of the stack, and deliberately so: the map screen keeps its
      // own green "Play" behind the veil, it is still `offsetParent`-visible, and a click there
      // lands on the veil and does nothing. The first recording spent all fourteen seconds
      // clicking it.
      const veils = [...document.querySelectorAll('#overlays .veil')];
      const top = veils[veils.length - 1];
      const go = top && [...top.querySelectorAll('button.btn-green')].find((b) => visible(b)
        && ['play', 'next level', 'finish', 'retry'].includes(b.textContent.trim().toLowerCase()));
      if (go) {
        cooldown = 18;
        return frame([{ t: 'click', ...centre(go) }]);
      }

      const km = window.KM;
      if (!km || !km.game || km.game.state !== 'ready') return frame(null);
      const move = km.game.hint();
      if (!move) return frame(null);

      const box = km.renderer.cv.getBoundingClientRect();
      const at = (cell) => {
        const p = km.renderer.cellCenter(cell);
        return { x: box.left + p.x, y: box.top + p.y };
      };
      cooldown = 7;
      // Tap one piece, then its neighbour: the game's own two-tap swap, not a synthetic drag.
      return frame([
        { t: 'click', ...at(move.a) },
        { t: 'wait', ms: 140 },
        { t: 'click', ...at(move.b) },
      ]);
    },
  };
})()
