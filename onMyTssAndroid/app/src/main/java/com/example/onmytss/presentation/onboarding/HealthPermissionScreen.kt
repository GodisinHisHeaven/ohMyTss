package com.example.onmytss.presentation.onboarding

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.activity.result.ActivityResultLauncher

@Composable
fun HealthPermissionScreen(
    permissionsLauncher: ActivityResultLauncher<Set<String>>,
    permissions: Set<String>,
    onNext: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(modifier = Modifier.height(64.dp))
        Text(
            text = "Connect Health Data",
            style = MaterialTheme.typography.headlineLarge,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            text = "onMyTss reads your workouts, heart rate, HRV, and sleep from Health Connect to calculate your Body Battery and training recommendations.",
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center
        )
        Spacer(modifier = Modifier.height(32.dp))

        val dataTypes = listOf(
            "🏃 Exercise sessions",
            "❤️ Heart rate",
            "💓 Heart rate variability",
            "😴 Sleep"
        )
        dataTypes.forEach { item ->
            Text(text = item, modifier = Modifier.padding(vertical = 4.dp))
        }

        Spacer(modifier = Modifier.weight(1f))
        Button(
            onClick = { permissionsLauncher.launch(permissions) },
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Grant Permissions")
        }
        Spacer(modifier = Modifier.height(8.dp))
        Button(onClick = onNext, modifier = Modifier.fillMaxWidth()) {
            Text("Continue")
        }
    }
}
