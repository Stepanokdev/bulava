package com.stepanok.bulava.ui.media

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.components.IconAction
import com.stepanok.bulava.ui.theme.Icons

/** A picture from the chat, full screen, with pinch to zoom. */
@Composable
fun ImageScreen(controller: AppController, ref: String, name: String, onBack: () -> Unit) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val state = rememberTransformableState { _, zoom, pan, _ ->
        scale = (scale * zoom).coerceIn(1f, 6f)
        offset = if (scale == 1f) Offset.Zero else offset + pan
    }
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        RemoteImage(
            controller, ref, name,
            Modifier.fillMaxSize().transformable(state)
                .graphicsLayer { scaleX = scale; scaleY = scale; translationX = offset.x; translationY = offset.y },
            contentScale = ContentScale.Fit,
        )
        IconAction(Icons.Close, name, onBack, Modifier.align(Alignment.TopEnd).statusBarsPadding(), tint = Color.White)
    }
}
