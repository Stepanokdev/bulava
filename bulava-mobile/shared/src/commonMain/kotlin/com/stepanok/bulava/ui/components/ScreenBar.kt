package com.stepanok.bulava.ui.components

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.stepanok.bulava.resources.Res
import com.stepanok.bulava.resources.cd_back
import com.stepanok.bulava.ui.theme.Bulava
import com.stepanok.bulava.ui.theme.Icons
import org.jetbrains.compose.resources.stringResource

/** The bar over a screen opened on top of the chat: back, its title, and what it offers. */
@Composable
fun ScreenBar(title: String, onBack: () -> Unit, trailing: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconAction(Icons.Back, stringResource(Res.string.cd_back), onBack)
        Text(title, style = Bulava.type.headline, color = Bulava.colors.text, modifier = Modifier.weight(1f).padding(horizontal = 4.dp))
        trailing()
    }
    Hairline()
}
