package com.stepanok.bulava.platform

/**
 * A button pressed on a notification acts on the Mac only from an unlocked phone.
 *
 * From Android 12 the system asks for that itself (`setAuthenticationRequired`); on Android 10 and
 * 11 nothing does, and a notification's buttons are there on the lock screen for anyone holding the
 * phone. So every press passes through here, on every version: on a locked phone the owner is asked
 * to unlock first — the PIN, the pattern or the fingerprint — and the press happens only if the
 * phone then says it is unlocked.
 */
class UnlockGate(
    private val locked: () -> Boolean,
    private val askToUnlock: (onAnswer: (Boolean) -> Unit) -> Unit,
) {
    fun pass(press: () -> Unit, refused: () -> Unit) {
        if (!locked()) {
            press()
            return
        }
        askToUnlock { unlocked ->
            // An answer is believed only when the phone agrees: unlocked, and no longer locked.
            if (unlocked && !locked()) press() else refused()
        }
    }
}
