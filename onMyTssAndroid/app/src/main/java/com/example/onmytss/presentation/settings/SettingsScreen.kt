package com.example.onmytss.presentation.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@Composable
fun SettingsScreen(viewModel: SettingsViewModel = hiltViewModel()) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    var showResetDialog by remember { mutableStateOf(false) }
    var ftpText by remember(uiState.ftp) { mutableStateOf(uiState.ftp.toString()) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp)
    ) {
        Text(
            text = "Settings",
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold
        )
        Spacer(modifier = Modifier.height(24.dp))

        // FTP Setting
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("FTP (Watts)", fontWeight = FontWeight.Medium)
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedTextField(
                    value = ftpText,
                    onValueChange = { ftpText = it.filter { c -> c.isDigit() } },
                    label = { Text("Cycling FTP") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(modifier = Modifier.height(8.dp))
                Button(
                    onClick = { ftpText.toIntOrNull()?.let { viewModel.updateFTP(it) } },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Save FTP")
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Sync
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Data Sync", fontWeight = FontWeight.Medium)
                Spacer(modifier = Modifier.height(8.dp))
                Text("Last sync: ${uiState.lastSyncText}")
                Spacer(modifier = Modifier.height(8.dp))
                Button(
                    onClick = { viewModel.syncData() },
                    enabled = !uiState.isSyncing,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(if (uiState.isSyncing) "Syncing..." else "Sync Health Connect Data")
                }
                uiState.error?.let {
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(it, color = MaterialTheme.colorScheme.error)
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Reset
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Data Management", fontWeight = FontWeight.Medium)
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedButton(
                    onClick = { showResetDialog = true },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Reset All Data")
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // About
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("About", fontWeight = FontWeight.Medium)
                Spacer(modifier = Modifier.height(8.dp))
                Text("onMyTss Android MVP")
                Text("Version 1.0")
            }
        }
    }

    if (showResetDialog) {
        AlertDialog(
            onDismissRequest = { showResetDialog = false },
            title = { Text("Reset All Data?") },
            text = { Text("This will permanently delete all your training data and recalculated metrics.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.resetAllData()
                        showResetDialog = false
                    }
                ) {
                    Text("Reset", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showResetDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }
}
