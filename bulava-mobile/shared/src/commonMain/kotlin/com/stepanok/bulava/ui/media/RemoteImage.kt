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

/**
 * A picture from the Mac: a spinner in its place while it comes, a picture mark if it cannot be had
 * — or, for both, [fallback]: what the caller shows instead, as a product's initials stand for its icon.
 */
@Composable
fun RemoteImage(
    controller: AppController,
    ref: String,
    description: String?,
    modifier: Modifier = Modifier,
    contentScale: ContentScale = ContentScale.Crop,
    fallback: (@Composable () -> Unit)? = null,
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
    val s = state
    when {
        s is Loaded.Done -> Image(s.image, contentDescription = description, modifier = modifier, contentScale = contentScale)
        fallback != null -> Box(modifier, contentAlignment = Alignment.Center) { fallback() }
        s == Loaded.Loading -> Box(modifier.background(Bulava.colors.surfaceMuted), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Bulava.colors.textFaint)
        }
        else -> Box(modifier.background(Bulava.colors.surfaceMuted), contentAlignment = Alignment.Center) {
            Icon(Icons.Image, description, tint = Bulava.colors.textFaint, modifier = Modifier.size(22.dp))
        }
    }
}
