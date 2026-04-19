package com.example.onmytss.presentation.onboarding

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.example.onmytss.presentation.theme.IosColors

@Composable
fun ThresholdInputScreen(
    defaultFTP: Int = 200,
    onComplete: (Int) -> Unit
) {
    val palette = IosColors.current
    var ftpText by remember { mutableStateOf("") }
    val ftpValue = ftpText.toIntOrNull()
    val isValid = ftpValue != null && ftpValue in 50..500

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(palette.systemBackground)
    ) {
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            Icon(
                imageVector = Icons.Filled.Speed,
                contentDescription = null,
                tint = palette.systemOrange,
                modifier = Modifier
                    .padding(top = 12.dp)
                    .size(70.dp)
            )

            Text(
                text = "Set Your FTP",
                style = MaterialTheme.typography.headlineLarge,
                fontWeight = FontWeight.Bold,
                color = palette.label
            )

            Text(
                text = "Your Functional Threshold Power helps us calculate accurate training stress scores.",
                style = MaterialTheme.typography.bodyLarge,
                color = palette.secondaryLabel,
                textAlign = TextAlign.Center
            )

            // FTP Input card
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(palette.secondarySystemBackground)
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "Cycling FTP (Watts)",
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.label
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedTextField(
                        value = ftpText,
                        onValueChange = { ftpText = it.filter { c -> c.isDigit() }.take(4) },
                        placeholder = { Text("e.g., 250") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        textStyle = MaterialTheme.typography.headlineMedium,
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = palette.systemBlue,
                            unfocusedBorderColor = palette.systemGray3
                        ),
                        modifier = Modifier.weight(1f)
                    )
                    Text(
                        text = "W",
                        style = MaterialTheme.typography.headlineSmall,
                        color = palette.secondaryLabel
                    )
                }
            }

            // Help card
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(palette.systemBlue.copy(alpha = 0.1f))
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text(
                    text = "What is FTP?",
                    style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.label
                )
                Text(
                    text = "FTP is the maximum power you can sustain for one hour. If you don't know your FTP, you can:",
                    style = MaterialTheme.typography.labelMedium,
                    color = palette.secondaryLabel
                )
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    HelpItem(text = "Complete an FTP test")
                    HelpItem(text = "Estimate from a 20-minute test")
                    HelpItem(text = "Use a default value and update later")
                }
            }

            Spacer(Modifier.height(120.dp))
        }

        // Bottom sticky actions
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(palette.systemBackground.copy(alpha = 0.95f))
                .padding(horizontal = 8.dp)
                .padding(top = 12.dp, bottom = 20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            PrimaryButton(
                text = "Continue",
                enabled = isValid,
                onClick = { ftpValue?.let(onComplete) }
            )
            Box(
                modifier = Modifier.fillMaxWidth(),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "Skip (Use Default)",
                    style = MaterialTheme.typography.bodyLarge,
                    color = palette.secondaryLabel,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { onComplete(defaultFTP) }
                        .padding(horizontal = 12.dp, vertical = 6.dp)
                )
            }
        }
    }
}

@Composable
private fun HelpItem(text: String) {
    val palette = IosColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Icon(
            imageVector = Icons.Filled.CheckCircle,
            contentDescription = null,
            tint = palette.systemBlue,
            modifier = Modifier.size(14.dp)
        )
        Text(
            text = text,
            style = MaterialTheme.typography.labelMedium,
            color = palette.secondaryLabel
        )
    }
}
