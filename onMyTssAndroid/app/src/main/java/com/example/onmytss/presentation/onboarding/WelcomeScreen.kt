package com.example.onmytss.presentation.onboarding

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

@Composable
fun WelcomeScreen(onNext: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(modifier = Modifier.height(64.dp))
        Text(
            text = "Welcome to onMyTss",
            style = MaterialTheme.typography.headlineLarge,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )
        Spacer(modifier = Modifier.height(16.dp))
        Text(
            text = "Track training load, monitor recovery, and get personalized guidance powered by your health data.",
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center
        )
        Spacer(modifier = Modifier.height(48.dp))

        val features = listOf(
            "📊 Body Battery score based on CTL/ATL/TSB",
            "❤️ HRV & RHR recovery insights",
            "😴 Sleep quality integration",
            "🎯 Daily TSS recommendations"
        )
        features.forEach { feature ->
            Text(text = feature, modifier = Modifier.padding(vertical = 4.dp))
        }

        Spacer(modifier = Modifier.weight(1f))
        Button(onClick = onNext, modifier = Modifier.fillMaxWidth()) {
            Text("Get Started")
        }
    }
}
