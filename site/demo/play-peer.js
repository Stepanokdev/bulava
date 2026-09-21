// Cozy Cottage Match — the third run's game. Recorded from `?level=1`, which its author wired up
// for exactly this, so the clip opens on the board instead of on a menu.
//
// Same contract as the other two: this file picks the move, Chrome performs the clicks.
(() => {
  // `?level=1` opens straight onto the board, so almost nothing here is warm-up — but the
  // asset loader's progress bar is, and the same rule drops it.
  const inPlay = () => {
    const app = window.__ccm;
    return !!app && !!app.game && app.game.status === 'playing' && !app.dialogs.current;
  };
  const frame = (acts) => (acts ? { acts, record: inPlay() } : { record: inPlay() });

  let cooldown = 0;

  window.__director = {
    step() {
      if (cooldown > 0) { cooldown -= 1; return frame(null); }

      const app = window.__ccm;
      if (!app || !app.playable || !app.playable()) return frame(null);
      const board = app.game && app.game.board;
      if (!board) return frame(null);

      // Its own list of legal moves, in its own order of preference: a special first if one is
      // on the board, then an ordinary swap.
      const moves = board.findMoves() || [];
      const swap = moves.find((m) => m.type === 'combo')
        || moves.find((m) => m.type === 'special' && m.b)
        || moves.find((m) => m.b);
      if (!swap) return frame(null);

      const box = app.canvas.getBoundingClientRect();
      const at = (cell) => ({
        x: box.left + app.renderer.cx(cell.c),
        y: box.top + app.renderer.cy(cell.r),
      });
      cooldown = 7;
      return frame([
        { t: 'click', ...at(swap.a) },
        { t: 'wait', ms: 140 },
        { t: 'click', ...at(swap.b) },
      ]);
    },
  };
})()
