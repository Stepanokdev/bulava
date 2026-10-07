package com.stepanok.bulava.ui.media

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.foundation.layout.size
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.state.AppController
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import org.jetbrains.compose.resources.decodeToImageBitmap

/** Pictures fetched from the Mac, kept while the app runs. Bounded, oldest out first. */
object ImageCache {
    private val images = LinkedHashMap<String, ImageBitmap>()
    private const val LIMIT = 48

    fun get(ref: String): ImageBitmap? = images[ref]

    fun put(ref: String, image: ImageBitmap) {
        images.remove(ref)
        images[ref] = image
        while (images.size > LIMIT) images.remove(images.keys.first())
    }
}

private sealed interface Loaded {
    data object Loading : Loaded
    data object Failed : Loaded
    data class Done(val image: ImageBitmap) : Loaded
}

@Composable
fun RemoteImage(
    controller: AppController,
    ref: String,
    description: String?,
    modifier: Modifier = Modifier,
    contentScale: ContentScale = ContentScale.Crop,
) {
    val state by produceState<Loaded>(ImageCache.get(ref)?.let { Loaded.Done(it) } ?: Loaded.Loading, ref) {
        if (value is Loaded.Done) return@produceState
        val bytes = controller.readFile(ref, limit = 25L * 1024 * 1024)
        val image = bytes?.let { runCatching { it.decodeToImageBitmap() }.getOrNull() }
        value = if (image != null) {
            ImageCache.put(ref, image)
            Loaded.Done(image)
        } else Loaded.Failed
    }
    when (val s = state) {
        is Loaded.Done -> Image(s.image, contentDescription = description, modifier = modifier, contentScale = contentScale)
        Loaded.Loading -> Box(modifier.background(Bulava.colors.surfaceMuted), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Bulava.colors.textFaint)
        }
        Loaded.Failed -> Box(modifier.background(Bulava.colors.surfaceMuted), contentAlignment = Alignment.Center) {
            Icon(Icons.Image, description, tint = Bulava.colors.textFaint, modifier = Modifier.size(22.dp))
        }
    }
}
