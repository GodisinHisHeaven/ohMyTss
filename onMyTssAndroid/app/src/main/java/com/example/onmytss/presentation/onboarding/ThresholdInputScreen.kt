package com.example.onmytss.presentation.onboarding

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

@Composable
fun ThresholdInputScreen(
    defaultFTP: Int = 200,
    onComplete: (Int) -> Unit
) {
    var ftpText by remember { mutableStateOf(defaultFTP.toString()) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(modifier = Modifier.height(64.dp))
        Text(
            text = "Set Your FTP",
            style = MaterialTheme.typography.headlineLarge,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            text = "Functional Threshold Power (FTP) is used to calculate power-based TSS for cycling workouts. You can change this anytime in Settings.",
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center
        )
        Spacer(modifier = Modifier.height(32.dp))

        OutlinedTextField(
            value = ftpText,
            onValueChange = { ftpText = it.filter { c -> c.isDigit() } },
            label = { Text("Cycling FTP (watts)") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(modifier = Modifier.weight(1f))
        Button(
            onClick = {
                val ftp = ftpText.toIntOrNull()?.coerceIn(50, 500) ?: defaultFTP
                onComplete(ftp)
            },
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Finish")
        }
        Spacer(modifier = Modifier.height(8.dp))
        TextButton(onClick = { onComplete(defaultFTP) }) {
            Text("Skip (use $defaultFTP W)")
        }
    }
}

@Composable
private fun TextButton(onClick: () -> Unit, content: @Composable () -> Unit) {
    androidx.compose.material3.TextButton(onClick = onClick) { content() }
}
