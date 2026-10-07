package com.stepanok.bulava.platform

import kotlin.test.Test
import kotlin.test.assertEquals

/** A notification's button presses nothing on a locked phone until it has been unlocked. */
class UnlockGateTest {

    private class Phone(var locked: Boolean) {
        val events = mutableListOf<String>()
        var answer: ((Boolean) -> Unit)? = null

        fun gate() = UnlockGate(locked = { locked }, askToUnlock = { onAnswer -> events += "asked"; answer = onAnswer })
        fun press() = gate().pass(press = { events += "pressed" }, refused = { events += "refused" })
    }

    @Test
    fun anUnlockedPhonePressesAtOnce() {
        val phone = Phone(locked = false)
        phone.press()
        assertEquals(listOf("pressed"), phone.events)
    }

    @Test
    fun aLockedPhoneAsksAndPressesNothingWhileItWaits() {
        val phone = Phone(locked = true)
        phone.press()
        assertEquals(listOf("asked"), phone.events, "nothing is pressed before the owner answers")
    }

    @Test
    fun theOwnerWhoDoesNotUnlockPressesNothing() {
        val phone = Phone(locked = true)
        phone.press()
        phone.answer!!(false)
        assertEquals(listOf("asked", "refused"), phone.events)
    }

    @Test
    fun unlockingPressesOnce() {
        val phone = Phone(locked = true)
        phone.press()
        phone.locked = false
        phone.answer!!(true)
        assertEquals(listOf("asked", "pressed"), phone.events)
    }

    @Test
    fun anAnswerThePhoneDoesNotBearOutIsNotBelieved() {
        val phone = Phone(locked = true)
        phone.press()
        phone.answer!!(true)
        assertEquals(listOf("asked", "refused"), phone.events, "still locked, so still nothing pressed")
    }
}
