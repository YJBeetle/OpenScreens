package com.openscreens.app.ui.sshkeys

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openscreens.app.R
import com.openscreens.app.data.SshKey
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SshKeysScreen(
    keys: List<SshKey>,
    onGenerate: (String) -> Result<SshKey>,
    onImport: (String, String, String) -> Result<SshKey>,
    onDelete: (String) -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }
    var addMenuExpanded by remember { mutableStateOf(false) }
    var showGenerate by remember { mutableStateOf(false) }
    var showImport by remember { mutableStateOf(false) }
    var pendingPem by remember { mutableStateOf("") }
    var pendingName by remember { mutableStateOf("") }
    var pendingPassphrase by remember { mutableStateOf("") }
    var pendingDelete by remember { mutableStateOf<SshKey?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) {
            scope.launch {
                val text = withContext(Dispatchers.IO) {
                    runCatching {
                        context.contentResolver.openInputStream(uri)?.use { stream ->
                            stream.bufferedReader().readText()
                        }
                    }.getOrNull()
                }
                if (text.isNullOrBlank()) {
                    snackbarHostState.showSnackbar(context.getString(R.string.ssh_key_import_failed))
                } else {
                    pendingPem = text
                    pendingName = uri.lastPathSegment?.substringAfterLast('/')?.take(48).orEmpty()
                    pendingPassphrase = ""
                    showImport = true
                }
            }
        }
    }

    fun copyPublicKey(key: SshKey) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText(context.getString(R.string.ssh_key_public), key.publicKey))
        scope.launch {
            snackbarHostState.showSnackbar(context.getString(R.string.ssh_key_copied))
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.ssh_keys_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.settings_back),
                        )
                    }
                },
                actions = {
                    IconButton(onClick = { addMenuExpanded = true }) {
                        Icon(
                            imageVector = Icons.Outlined.Add,
                            contentDescription = stringResource(R.string.ssh_key_add),
                        )
                    }
                    DropdownMenu(
                        expanded = addMenuExpanded,
                        onDismissRequest = { addMenuExpanded = false },
                    ) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.ssh_key_generate)) },
                            onClick = {
                                addMenuExpanded = false
                                showGenerate = true
                            },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.ssh_key_import)) },
                            onClick = {
                                addMenuExpanded = false
                                importLauncher.launch(arrayOf("*/*"))
                            },
                        )
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Spacer(Modifier.height(4.dp))
            if (keys.isEmpty()) {
                Card(
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceContainer,
                    ),
                    shape = RoundedCornerShape(20.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(
                        modifier = Modifier.padding(20.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            text = stringResource(R.string.ssh_keys_empty_title),
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Text(
                            text = stringResource(R.string.ssh_keys_empty_body),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            } else {
                keys.forEach { key ->
                    Card(
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.surfaceContainer,
                        ),
                        shape = RoundedCornerShape(20.dp),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(
                            modifier = Modifier.padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text(key.name, style = MaterialTheme.typography.titleMedium)
                            Text(
                                text = key.fingerprint,
                                style = MaterialTheme.typography.labelSmall,
                                fontFamily = FontFamily.Monospace,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                TextButton(onClick = { copyPublicKey(key) }) {
                                    Text(stringResource(R.string.ssh_key_copy_public))
                                }
                                TextButton(onClick = { pendingDelete = key }) {
                                    Text(stringResource(R.string.ssh_key_delete))
                                }
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
        }
    }

    if (showGenerate) {
        var name by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showGenerate = false },
            title = { Text(stringResource(R.string.ssh_key_generate)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = name,
                        onValueChange = { name = it },
                        label = { Text(stringResource(R.string.ssh_key_name)) },
                        singleLine = true,
                    )
                    error?.let {
                        Text(it, color = MaterialTheme.colorScheme.error)
                    }
                }
            },
            confirmButton = {
                TextButton(
                    enabled = name.isNotBlank(),
                    onClick = {
                        onGenerate(name.trim())
                            .onSuccess {
                                showGenerate = false
                                error = null
                                scope.launch {
                                    snackbarHostState.showSnackbar(context.getString(R.string.ssh_key_created))
                                }
                            }
                            .onFailure { error = it.message ?: context.getString(R.string.ssh_key_error) }
                    },
                ) { Text(stringResource(R.string.editor_save)) }
            },
            dismissButton = {
                TextButton(onClick = { showGenerate = false }) {
                    Text(stringResource(R.string.editor_cancel))
                }
            },
        )
    }

    if (showImport) {
        AlertDialog(
            onDismissRequest = { showImport = false },
            title = { Text(stringResource(R.string.ssh_key_import)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = pendingName,
                        onValueChange = { pendingName = it },
                        label = { Text(stringResource(R.string.ssh_key_name)) },
                        singleLine = true,
                    )
                    OutlinedTextField(
                        value = pendingPassphrase,
                        onValueChange = { pendingPassphrase = it },
                        label = { Text(stringResource(R.string.ssh_key_passphrase)) },
                        supportingText = { Text(stringResource(R.string.ssh_key_passphrase_optional)) },
                        singleLine = true,
                    )
                    error?.let {
                        Text(it, color = MaterialTheme.colorScheme.error)
                    }
                }
            },
            confirmButton = {
                TextButton(
                    enabled = pendingName.isNotBlank(),
                    onClick = {
                        onImport(pendingName.trim(), pendingPem, pendingPassphrase)
                            .onSuccess {
                                showImport = false
                                error = null
                                scope.launch {
                                    snackbarHostState.showSnackbar(context.getString(R.string.ssh_key_imported))
                                }
                            }
                            .onFailure { error = it.message ?: context.getString(R.string.ssh_key_error) }
                    },
                ) { Text(stringResource(R.string.editor_save)) }
            },
            dismissButton = {
                TextButton(onClick = { showImport = false }) {
                    Text(stringResource(R.string.editor_cancel))
                }
            },
        )
    }

    pendingDelete?.let { key ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.ssh_key_delete_title)) },
            text = { Text(stringResource(R.string.ssh_key_delete_body, key.name)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        onDelete(key.id)
                        pendingDelete = null
                    },
                ) { Text(stringResource(R.string.ssh_key_delete)) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) {
                    Text(stringResource(R.string.editor_cancel))
                }
            },
        )
    }

}
