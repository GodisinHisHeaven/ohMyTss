package com.example.onmytss.presentation.settings

import android.content.Intent
import android.net.Uri
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
import androidx.compose.material.icons.automirrored.filled.Launch
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.DeleteForever
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.example.onmytss.domain.Constants
import com.example.onmytss.presentation.theme.IosColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(viewModel: SettingsViewModel = hiltViewModel()) {
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val palette = IosColors.current
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    var showResetDialog by remember { mutableStateOf(false) }
    var showFtpEditor by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            LargeTopAppBar(
                title = {
                    Text(
                        text = "Settings",
                        style = MaterialTheme.typography.displayLarge,
                        color = palette.label
                    )
                },
                scrollBehavior = scrollBehavior
            )
        },
        containerColor = palette.secondarySystemBackground
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp)
        ) {
            // Cycling section
            SettingsSection(title = "Cycling") {
                SettingsRow(
                    icon = Icons.Filled.Bolt,
                    iconTint = palette.systemYellow,
                    title = "FTP (Functional Threshold Power)",
                    trailing = { Text("${uiState.ftp} W", color = palette.secondaryLabel) },
                    onClick = { showFtpEditor = true }
                )
                SettingsDivider()
                SettingsRow(
                    icon = Icons.Filled.Edit,
                    iconTint = palette.systemBlue,
                    title = "Edit FTP",
                    onClick = { showFtpEditor = true }
                )
            }

            // Data section
            SettingsSection(title = "Data") {
                SettingsRow(
                    icon = Icons.Filled.Autorenew,
                    iconTint = palette.systemBlue,
                    title = "Sync Health Connect Data",
                    trailing = {
                        if (uiState.isSyncing) {
                            CircularProgressIndicator(
                                color = palette.systemBlue,
                                strokeWidth = 2.dp,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    },
                    onClick = { if (!uiState.isSyncing) viewModel.syncData() }
                )
                SettingsDivider()
                SettingsRow(
                    icon = Icons.Filled.Schedule,
                    iconTint = palette.systemGray,
                    title = "Last Sync",
                    trailing = { Text(uiState.lastSyncText, color = palette.secondaryLabel) }
                )
                uiState.error?.let {
                    SettingsDivider()
                    Text(
                        text = it,
                        style = MaterialTheme.typography.labelMedium,
                        color = palette.systemRed,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                    )
                }
            }

            // About section
            val context = LocalContext.current
            SettingsSection(title = "About") {
                SettingsRow(
                    title = "Version",
                    trailing = { Text("1.0", color = palette.secondaryLabel) }
                )
                SettingsDivider()
                SettingsRow(
                    title = "Build",
                    trailing = { Text("MVP", color = palette.secondaryLabel) }
                )
                SettingsDivider()
                SettingsRow(
                    icon = Icons.Filled.Shield,
                    iconTint = palette.systemBlue,
                    title = "Privacy Policy",
                    trailing = {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.Launch,
                            contentDescription = null,
                            tint = palette.tertiaryLabel,
                            modifier = Modifier.size(14.dp)
                        )
                    },
                    onClick = {
                        context.startActivity(
                            Intent(
                                Intent.ACTION_VIEW,
                                Uri.parse("https://godisinHisHeaven.github.io/ohMyTss/privacy-policy.html")
                            )
                        )
                    }
                )
                SettingsDivider()
                SettingsRow(
                    icon = Icons.AutoMirrored.Filled.Launch,
                    iconTint = palette.systemBlue,
                    title = "GitHub Repository",
                    trailing = {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.Launch,
                            contentDescription = null,
                            tint = palette.tertiaryLabel,
                            modifier = Modifier.size(14.dp)
                        )
                    },
                    onClick = {
                        context.startActivity(
                            Intent(
                                Intent.ACTION_VIEW,
                                Uri.parse("https://github.com/GodisinHisHeaven/ohMyTss")
                            )
                        )
                    }
                )
            }

            // Danger zone
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                SettingsSection(title = null) {
                    SettingsRow(
                        icon = Icons.Filled.DeleteForever,
                        iconTint = palette.systemRed,
                        title = "Reset All Data",
                        titleColor = palette.systemRed,
                        onClick = { showResetDialog = true }
                    )
                }
                Text(
                    text = "This will delete all calculated metrics. Your Health Connect data will not be affected.",
                    style = MaterialTheme.typography.labelMedium,
                    color = palette.secondaryLabel,
                    modifier = Modifier.padding(horizontal = 32.dp)
                )
            }

            Spacer(Modifier.height(16.dp))
        }
    }

    if (showResetDialog) {
        AlertDialog(
            onDismissRequest = { showResetDialog = false },
            title = { Text("Reset All Data?") },
            text = { Text("This will delete all calculated Body Battery data. This action cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.resetAllData()
                    showResetDialog = false
                }) { Text("Reset", color = palette.systemRed) }
            },
            dismissButton = {
                TextButton(onClick = { showResetDialog = false }) { Text("Cancel") }
            },
            containerColor = palette.systemBackground,
            titleContentColor = palette.label,
            textContentColor = palette.secondaryLabel
        )
    }

    if (showFtpEditor) {
        FtpEditorDialog(
            currentFtp = uiState.ftp,
            onDismiss = { showFtpEditor = false },
            onSave = { newFtp ->
                viewModel.updateFTP(newFtp)
                showFtpEditor = false
            }
        )
    }
}

@Composable
private fun FtpEditorDialog(
    currentFtp: Int,
    onDismiss: () -> Unit,
    onSave: (Int) -> Unit
) {
    val palette = IosColors.current
    var text by remember { mutableStateOf(currentFtp.toString()) }
    val intValue = text.toIntOrNull()
    val valid = intValue != null && intValue in Constants.MIN_FTP..Constants.MAX_FTP

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Edit FTP") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                TextField(
                    value = text,
                    onValueChange = { text = it.filter { c -> c.isDigit() }.take(4) },
                    label = { Text("FTP (Watts)") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = palette.secondarySystemBackground,
                        unfocusedContainerColor = palette.secondarySystemBackground
                    )
                )
                Text(
                    text = "Your FTP is the maximum power you can sustain for one hour.",
                    style = MaterialTheme.typography.labelMedium,
                    color = palette.secondaryLabel
                )
                Text(
                    text = "Valid range: ${Constants.MIN_FTP}-${Constants.MAX_FTP} watts",
                    style = MaterialTheme.typography.labelMedium,
                    color = palette.secondaryLabel
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { intValue?.let(onSave) },
                enabled = valid
            ) { Text("Save") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
        containerColor = palette.systemBackground,
        titleContentColor = palette.label,
        textContentColor = palette.secondaryLabel
    )
}

@Composable
private fun SettingsSection(
    title: String?,
    content: @Composable () -> Unit
) {
    val palette = IosColors.current
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        if (title != null) {
            Text(
                text = title.uppercase(),
                style = MaterialTheme.typography.labelMedium,
                color = palette.secondaryLabel,
                modifier = Modifier.padding(horizontal = 32.dp)
            )
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(palette.systemBackground)
        ) {
            content()
        }
    }
}

@Composable
private fun SettingsDivider() {
    val palette = IosColors.current
    HorizontalDivider(
        color = palette.separator,
        modifier = Modifier.padding(start = 48.dp)
    )
}

@Composable
private fun SettingsRow(
    title: String,
    icon: ImageVector? = null,
    iconTint: Color? = null,
    titleColor: Color? = null,
    trailing: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)? = null
) {
    val palette = IosColors.current
    val base = Modifier
        .fillMaxWidth()
        .then(if (onClick != null) Modifier.clickable { onClick() } else Modifier)
        .padding(horizontal = 16.dp, vertical = 12.dp)
    Row(
        modifier = base,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        if (icon != null) {
            Box(
                modifier = Modifier.size(20.dp),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = iconTint ?: palette.systemBlue,
                    modifier = Modifier.size(18.dp)
                )
            }
        }
        Text(
            text = title,
            style = MaterialTheme.typography.bodyLarge,
            color = titleColor ?: palette.label,
            modifier = Modifier.weight(1f)
        )
        if (trailing != null) {
            trailing()
        }
    }
}
