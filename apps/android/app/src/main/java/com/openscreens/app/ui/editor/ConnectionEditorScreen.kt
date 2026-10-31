package com.openscreens.app.ui.editor

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openscreens.app.R
import com.openscreens.app.data.Connection
import com.openscreens.app.data.ConnectionAccent
import com.openscreens.app.data.QualityPreset
import com.openscreens.app.data.SshAuthMode
import com.openscreens.app.ui.common.label
import com.openscreens.app.ui.common.summary
import com.openscreens.app.data.SshCredentials
import com.openscreens.app.data.SshKey
import com.openscreens.app.ui.theme.ThemedSystemBarIcons
import com.openscreens.app.ui.theme.autoAccent
import com.openscreens.app.ui.theme.gradient
import com.openscreens.app.ui.theme.labelRes
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.rfb_ffi.validateOpenvpnProfile

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun ConnectionEditorScreen(
    connection: Connection?,
    sshKeys: List<SshKey> = emptyList(),
    onSave: (Connection) -> Unit,
    onCancel: () -> Unit,
) {
    ThemedSystemBarIcons()

    val editorKey = connection?.id
    var name by rememberSaveable(editorKey) { mutableStateOf(connection?.name.orEmpty()) }
    var accent by rememberSaveable(editorKey) { mutableStateOf(connection?.accent) }
    var host by rememberSaveable(editorKey) { mutableStateOf(connection?.host.orEmpty()) }
    var port by rememberSaveable(editorKey) {
        mutableStateOf((connection?.port ?: Connection.DEFAULT_VNC_PORT).toString())
    }
    var vncPassword by rememberSaveable(editorKey) {
        mutableStateOf(connection?.vncPassword.orEmpty())
    }
    var quality by rememberSaveable(editorKey) {
        mutableStateOf(connection?.quality ?: QualityPreset.Balanced)
    }
    var username by rememberSaveable(editorKey) {
        mutableStateOf(connection?.username.orEmpty())
    }
    var sshEnabled by rememberSaveable(editorKey) { mutableStateOf(connection?.ssh != null) }
    var sshHost by rememberSaveable(editorKey) {
        mutableStateOf(connection?.ssh?.host.orEmpty())
    }
    var sshUsername by rememberSaveable(editorKey) {
        mutableStateOf(connection?.ssh?.username.orEmpty())
    }
    var sshPassword by rememberSaveable(editorKey) {
        mutableStateOf(connection?.ssh?.password.orEmpty())
    }
    var sshPort by rememberSaveable(editorKey) {
        mutableStateOf((connection?.ssh?.port ?: SshCredentials.DEFAULT_SSH_PORT).toString())
    }
    var sshFingerprint by rememberSaveable(editorKey) {
        mutableStateOf(connection?.ssh?.hostKeyFingerprint.orEmpty())
    }
    var sshAuthMode by rememberSaveable(editorKey) {
        mutableStateOf(connection?.ssh?.authMode ?: SshAuthMode.Password)
    }
    var sshKeyId by rememberSaveable(editorKey) {
        mutableStateOf(connection?.ssh?.keyId.orEmpty())
    }
    var wireGuardConfig by rememberSaveable(editorKey) {
        mutableStateOf<String?>(connection?.wireGuardConfig)
    }
    var wireGuardFileName by rememberSaveable(editorKey) {
        mutableStateOf<String?>(null)
    }
    var wireGuardImportFailed by remember { mutableStateOf(false) }
    var openVpnConfig by rememberSaveable(editorKey) {
        mutableStateOf<String?>(connection?.openVpnConfig)
    }
    var openVpnFileName by rememberSaveable(editorKey) {
        mutableStateOf<String?>(null)
    }
    var openVpnSummary by rememberSaveable(editorKey) { mutableStateOf<String?>(null) }
    var openVpnImportError by rememberSaveable(editorKey) { mutableStateOf<String?>(null) }
    var keyMenuExpanded by remember { mutableStateOf(false) }
    var validate by rememberSaveable { mutableStateOf(false) }

    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }
    val wireGuardPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val text = withContext(Dispatchers.IO) { readWireGuardConfig(context, uri) }
            if (text == null) {
                wireGuardImportFailed = true
            } else {
                wireGuardConfig = text
                wireGuardFileName = uri.lastPathSegment
                    ?.substringAfterLast('/')
                    ?.take(64)
                    ?.takeIf { it.isNotBlank() }
                wireGuardImportFailed = false
            }
        }
    }

    val openVpnPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val text = withContext(Dispatchers.IO) { readOpenVpnConfig(context, uri) }
            if (text == null) {
                openVpnImportError = context.getString(R.string.editor_openvpn_import_failed)
                return@launch
            }
            val result = withContext(Dispatchers.IO) { runCatching { validateOpenvpnProfile(text) } }
            result.fold(
                onSuccess = {
                    openVpnConfig = text
                    openVpnFileName = uri.lastPathSegment
                        ?.substringAfterLast('/')
                        ?.take(64)
                        ?.takeIf { it.isNotBlank() }
                    openVpnImportError = null
                },
                onFailure = { error ->
                    openVpnImportError = error.message
                        ?.takeIf { it.isNotBlank() }
                        ?: context.getString(R.string.editor_openvpn_import_failed)
                },
            )
        }
    }

    LaunchedEffect(openVpnConfig) {
        openVpnSummary = null
        val text = openVpnConfig
        if (text.isNullOrBlank()) return@LaunchedEffect
        openVpnSummary = withContext(Dispatchers.IO) {
            runCatching { validateOpenvpnProfile(text) }.getOrNull()?.let { summary ->
                buildList {
                    add(summary.remote)
                    add(summary.proto)
                    add(summary.cipher)
                    summary.tlsWrap?.let(::add)
                }.joinToString(" · ")
            }
        }
    }

    val nameError = if (name.isBlank()) R.string.editor_error_required else null
    val hostError = when {
        host.isBlank() -> R.string.editor_error_required
        host.any(Char::isWhitespace) || "://" in host -> R.string.editor_error_host
        else -> null
    }
    val portNumber = port.toIntOrNull()
    val portError = when {
        port.isBlank() -> R.string.editor_error_required
        portNumber == null || portNumber !in 1..65535 -> R.string.editor_error_port
        else -> null
    }
    val sshUsernameError = if (sshEnabled && sshUsername.isBlank()) {
        R.string.editor_error_required
    } else {
        null
    }
    val sshPortNumber = sshPort.toIntOrNull()
    val sshPortError = if (sshEnabled && (sshPortNumber == null || sshPortNumber !in 1..65535)) {
        R.string.editor_error_port
    } else {
        null
    }
    val selectedSshKey = sshKeys.firstOrNull { it.id == sshKeyId }
    val sshKeyError = if (sshEnabled && sshAuthMode == SshAuthMode.PrivateKey && selectedSshKey == null) {
        R.string.editor_ssh_key_required
    } else {
        null
    }
    val hasWireGuard = !wireGuardConfig.isNullOrBlank()
    val hasOpenVpn = !openVpnConfig.isNullOrBlank()
    val wireGuardConflict = hasWireGuard && (sshEnabled || hasOpenVpn)
    val openVpnConflict = hasOpenVpn && (sshEnabled || hasWireGuard)
    val tunnelConflict = wireGuardConflict || openVpnConflict

    val onSaveClick: () -> Unit = {
        validate = true
        if (tunnelConflict) {
            scope.launch {
                snackbarHostState.showSnackbar(context.getString(R.string.editor_tunnel_conflict))
            }
        }
        if (nameError == null && hostError == null && portError == null &&
            sshUsernameError == null && sshPortError == null && sshKeyError == null &&
            !tunnelConflict
        ) {
            val ssh = if (sshEnabled) {
                SshCredentials(
                    host = sshHost.trim(),
                    username = sshUsername.trim(),
                    password = if (sshAuthMode == SshAuthMode.Password) sshPassword else "",
                    port = sshPortNumber ?: SshCredentials.DEFAULT_SSH_PORT,
                    hostKeyFingerprint = sshFingerprint.trim(),
                    authMode = sshAuthMode,
                    keyId = if (sshAuthMode == SshAuthMode.PrivateKey) sshKeyId else "",
                )
            } else {
                null
            }
            val draft = (connection ?: Connection(name = "", host = "")).copy(
                name = name.trim(),
                accent = accent,
                host = host.trim(),
                port = portNumber ?: Connection.DEFAULT_VNC_PORT,
                username = username.trim(),
                vncPassword = vncPassword,
                quality = quality,
                ssh = ssh,
                wireGuardConfig = wireGuardConfig?.takeIf { it.isNotBlank() },
                openVpnConfig = openVpnConfig?.takeIf { it.isNotBlank() },
            )
            onSave(draft)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        stringResource(
                            if (connection == null) {
                                R.string.editor_new_title
                            } else {
                                R.string.editor_edit_title
                            },
                        ),
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onCancel) {
                        Icon(
                            imageVector = Icons.Outlined.Close,
                            contentDescription = stringResource(R.string.editor_cancel),
                        )
                    }
                },
                actions = {
                    TextButton(onClick = onSaveClick) {
                        Text(stringResource(R.string.editor_save))
                    }
                },
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .imePadding(),
        ) {
            Column(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .widthIn(max = 640.dp)
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(stringResource(R.string.editor_name)) },
                    placeholder = { Text(stringResource(R.string.editor_name_placeholder)) },
                    singleLine = true,
                    isError = validate && nameError != null,
                    supportingText = if (validate && nameError != null) {
                        { Text(stringResource(nameError)) }
                    } else {
                        null
                    },
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.Words,
                        imeAction = ImeAction.Next,
                    ),
                )

                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = host,
                        onValueChange = { host = it },
                        modifier = Modifier.weight(1f),
                        label = { Text(stringResource(R.string.editor_host)) },
                        placeholder = { Text(stringResource(R.string.editor_host_placeholder)) },
                        singleLine = true,
                        isError = validate && hostError != null,
                        supportingText = if (validate && hostError != null) {
                            { Text(stringResource(hostError)) }
                        } else {
                            null
                        },
                        keyboardOptions = KeyboardOptions(
                            autoCorrectEnabled = false,
                            imeAction = ImeAction.Next,
                        ),
                    )
                    OutlinedTextField(
                        value = port,
                        onValueChange = { value -> port = value.filter(Char::isDigit) },
                        modifier = Modifier.width(112.dp),
                        label = { Text(stringResource(R.string.editor_port)) },
                        singleLine = true,
                        isError = validate && portError != null,
                        supportingText = if (validate && portError != null) {
                            { Text(stringResource(portError)) }
                        } else {
                            null
                        },
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Number,
                            imeAction = ImeAction.Next,
                        ),
                    )
                }

                OutlinedTextField(
                    value = username,
                    onValueChange = { username = it },
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(stringResource(R.string.editor_username)) },
                    singleLine = true,
                    supportingText = { Text(stringResource(R.string.editor_username_optional)) },
                    keyboardOptions = KeyboardOptions(
                        autoCorrectEnabled = false,
                        imeAction = ImeAction.Next,
                    ),
                )

                PasswordField(
                    value = vncPassword,
                    onValueChange = { vncPassword = it },
                    label = stringResource(R.string.editor_vnc_password),
                    supportingText = stringResource(R.string.editor_optional),
                )

                Text(
                    text = stringResource(R.string.editor_color),
                    style = MaterialTheme.typography.titleMedium,
                )
                val effectiveAccent = accent ?: autoAccent(
                    name.ifBlank { connection?.name.orEmpty() },
                )
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    ConnectionAccent.entries.forEach { option ->
                        val selected = option == effectiveAccent
                        val gradient = option.gradient
                        val label = stringResource(option.labelRes)
                        Box(
                            modifier = Modifier
                                .size(36.dp)
                                .clip(CircleShape)
                                .then(
                                    if (selected) {
                                        Modifier.border(
                                            2.dp,
                                            MaterialTheme.colorScheme.onSurface,
                                            CircleShape,
                                        )
                                    } else {
                                        Modifier
                                    },
                                )
                                .selectable(
                                    selected = selected,
                                    role = Role.RadioButton,
                                    onClick = { accent = option },
                                )
                                .semantics { contentDescription = label },
                            contentAlignment = Alignment.Center,
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(26.dp)
                                    .clip(CircleShape)
                                    .background(
                                        Brush.linearGradient(
                                            listOf(gradient.start, gradient.end),
                                        ),
                                    ),
                            )
                        }
                    }
                }

                Text(
                    text = stringResource(R.string.settings_streaming),
                    style = MaterialTheme.typography.titleMedium,
                )
                QualityPreset.entries.forEach { preset ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .selectable(
                                selected = quality == preset,
                                role = Role.RadioButton,
                                onClick = { quality = preset },
                            )
                            .padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = quality == preset, onClick = null)
                        Spacer(Modifier.width(12.dp))
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(preset.label(), style = MaterialTheme.typography.bodyLarge)
                            Text(
                                preset.summary(),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }

                HorizontalDivider(Modifier.padding(vertical = 4.dp))

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .toggleable(
                            value = sshEnabled,
                            role = Role.Switch,
                            onValueChange = { sshEnabled = it },
                        )
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Text(
                            text = stringResource(R.string.editor_ssh_toggle),
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Text(
                            text = stringResource(R.string.editor_ssh_description),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    Switch(checked = sshEnabled, onCheckedChange = null)
                }

                AnimatedVisibility(visible = sshEnabled) {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedTextField(
                            value = sshHost,
                            onValueChange = { sshHost = it },
                            modifier = Modifier.fillMaxWidth(),
                            label = { Text(stringResource(R.string.editor_ssh_host)) },
                            singleLine = true,
                            supportingText = {
                                Text(stringResource(R.string.editor_ssh_host_help))
                            },
                            keyboardOptions = KeyboardOptions(
                                autoCorrectEnabled = false,
                                imeAction = ImeAction.Next,
                            ),
                        )
                        OutlinedTextField(
                            value = sshUsername,
                            onValueChange = { sshUsername = it },
                            modifier = Modifier.fillMaxWidth(),
                            label = { Text(stringResource(R.string.editor_ssh_username)) },
                            singleLine = true,
                            isError = validate && sshUsernameError != null,
                            supportingText = if (validate && sshUsernameError != null) {
                                { Text(stringResource(sshUsernameError)) }
                            } else {
                                null
                            },
                            keyboardOptions = KeyboardOptions(
                                autoCorrectEnabled = false,
                                imeAction = ImeAction.Next,
                            ),
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            FilterChip(
                                selected = sshAuthMode == SshAuthMode.Password,
                                onClick = { sshAuthMode = SshAuthMode.Password },
                                label = { Text(stringResource(R.string.editor_ssh_auth_password)) },
                            )
                            FilterChip(
                                selected = sshAuthMode == SshAuthMode.PrivateKey,
                                onClick = { sshAuthMode = SshAuthMode.PrivateKey },
                                label = { Text(stringResource(R.string.editor_ssh_auth_key)) },
                            )
                        }
                        if (sshAuthMode == SshAuthMode.Password) {
                            PasswordField(
                                value = sshPassword,
                                onValueChange = { sshPassword = it },
                                label = stringResource(R.string.editor_ssh_password),
                                supportingText = stringResource(R.string.editor_ssh_password_optional),
                            )
                        } else {
                            Box {
                                OutlinedButton(
                                    onClick = { keyMenuExpanded = true },
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    Text(selectedSshKey?.name ?: stringResource(R.string.editor_ssh_select_key))
                                }
                                DropdownMenu(
                                    expanded = keyMenuExpanded,
                                    onDismissRequest = { keyMenuExpanded = false },
                                ) {
                                    sshKeys.forEach { key ->
                                        DropdownMenuItem(
                                            text = {
                                                Column {
                                                    Text(key.name)
                                                    Text(
                                                        text = key.fingerprint,
                                                        style = MaterialTheme.typography.labelSmall,
                                                        maxLines = 1,
                                                        overflow = TextOverflow.Ellipsis,
                                                    )
                                                }
                                            },
                                            onClick = {
                                                sshKeyId = key.id
                                                keyMenuExpanded = false
                                            },
                                        )
                                    }
                                }
                            }
                            Text(
                                text = stringResource(
                                    if (sshKeys.isEmpty()) {
                                        R.string.editor_ssh_no_keys
                                    } else {
                                        R.string.editor_ssh_manage_keys
                                    },
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = if (validate && sshKeyError != null) {
                                    MaterialTheme.colorScheme.error
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                },
                            )
                        }
                        OutlinedTextField(
                            value = sshPort,
                            onValueChange = { sshPort = it.filter(Char::isDigit) },
                            modifier = Modifier.fillMaxWidth(),
                            label = { Text(stringResource(R.string.editor_ssh_port)) },
                            singleLine = true,
                            isError = validate && sshPortError != null,
                            supportingText = if (validate && sshPortError != null) {
                                { Text(stringResource(sshPortError)) }
                            } else {
                                null
                            },
                            keyboardOptions = KeyboardOptions(
                                keyboardType = KeyboardType.Number,
                                imeAction = ImeAction.Next,
                            ),
                        )
                        OutlinedTextField(
                            value = sshFingerprint,
                            onValueChange = { sshFingerprint = it },
                            modifier = Modifier.fillMaxWidth(),
                            label = { Text(stringResource(R.string.editor_ssh_fingerprint)) },
                            singleLine = true,
                            supportingText = {
                                Text(stringResource(R.string.editor_ssh_fingerprint_help))
                            },
                            keyboardOptions = KeyboardOptions(
                                autoCorrectEnabled = false,
                                imeAction = ImeAction.Done,
                            ),
                        )
                    }
                }

                HorizontalDivider(Modifier.padding(vertical = 4.dp))

                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = stringResource(R.string.editor_wireguard_title),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(
                        text = stringResource(R.string.editor_wireguard_description),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    val selectedWireGuard = wireGuardConfig
                    if (selectedWireGuard.isNullOrBlank()) {
                        OutlinedButton(
                            onClick = {
                                wireGuardImportFailed = false
                                wireGuardPicker.launch(arrayOf("*/*"))
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(stringResource(R.string.editor_wireguard_import))
                        }
                    } else {
                        val preview = wireGuardPreview(selectedWireGuard)
                        OutlinedCard(modifier = Modifier.fillMaxWidth()) {
                            Row(
                                modifier = Modifier.padding(start = 16.dp, top = 8.dp, end = 8.dp, bottom = 8.dp),
                                verticalAlignment = Alignment.Top,
                            ) {
                                Column(
                                    modifier = Modifier
                                        .weight(1f)
                                        .padding(top = 4.dp),
                                    verticalArrangement = Arrangement.spacedBy(4.dp),
                                ) {
                                    Text(
                                        text = wireGuardFileName
                                            ?: stringResource(R.string.editor_wireguard_loaded),
                                        style = MaterialTheme.typography.titleSmall,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    if (preview.isNotBlank()) {
                                        Text(
                                            text = preview,
                                            style = MaterialTheme.typography.bodySmall,
                                            fontFamily = FontFamily.Monospace,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            maxLines = 4,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                }
                                TextButton(
                                    onClick = {
                                        wireGuardConfig = null
                                        wireGuardFileName = null
                                        wireGuardImportFailed = false
                                    },
                                ) {
                                    Text(stringResource(R.string.editor_wireguard_remove))
                                }
                            }
                        }
                    }
                    if (wireGuardImportFailed) {
                        Text(
                            text = stringResource(R.string.editor_wireguard_import_failed),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                    if (wireGuardConflict) {
                        Text(
                            text = stringResource(R.string.editor_wireguard_conflict),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                }

                HorizontalDivider(Modifier.padding(vertical = 4.dp))

                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = stringResource(R.string.editor_openvpn_title),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(
                        text = stringResource(R.string.editor_openvpn_description),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    val selectedOpenVpn = openVpnConfig
                    if (selectedOpenVpn.isNullOrBlank()) {
                        OutlinedButton(
                            onClick = {
                                openVpnImportError = null
                                openVpnPicker.launch(arrayOf("*/*"))
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(stringResource(R.string.editor_openvpn_import))
                        }
                    } else {
                        OutlinedCard(modifier = Modifier.fillMaxWidth()) {
                            Row(
                                modifier = Modifier.padding(start = 16.dp, top = 8.dp, end = 8.dp, bottom = 8.dp),
                                verticalAlignment = Alignment.Top,
                            ) {
                                Column(
                                    modifier = Modifier
                                        .weight(1f)
                                        .padding(top = 4.dp),
                                    verticalArrangement = Arrangement.spacedBy(4.dp),
                                ) {
                                    Text(
                                        text = openVpnFileName
                                            ?: stringResource(R.string.editor_openvpn_loaded),
                                        style = MaterialTheme.typography.titleSmall,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    val summary = openVpnSummary
                                    if (!summary.isNullOrBlank()) {
                                        Text(
                                            text = summary,
                                            style = MaterialTheme.typography.bodySmall,
                                            fontFamily = FontFamily.Monospace,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                }
                                TextButton(
                                    onClick = {
                                        openVpnConfig = null
                                        openVpnFileName = null
                                        openVpnSummary = null
                                        openVpnImportError = null
                                    },
                                ) {
                                    Text(stringResource(R.string.editor_openvpn_remove))
                                }
                            }
                        }
                    }
                    openVpnImportError?.let { message ->
                        Text(
                            text = message,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                    if (openVpnConflict) {
                        Text(
                            text = stringResource(R.string.editor_openvpn_conflict),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                }

                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

@Composable
private fun PasswordField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    supportingText: String,
) {
    var visible by rememberSaveable { mutableStateOf(false) }
    val showLabel = stringResource(R.string.editor_show_password)
    val hideLabel = stringResource(R.string.editor_hide_password)

    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth(),
        label = { Text(label) },
        singleLine = true,
        visualTransformation = if (visible) {
            VisualTransformation.None
        } else {
            PasswordVisualTransformation()
        },
        keyboardOptions = KeyboardOptions(
            keyboardType = KeyboardType.Password,
            imeAction = ImeAction.Done,
        ),
        trailingIcon = {
            IconButton(onClick = { visible = !visible }) {
                Icon(
                    imageVector = if (visible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                    contentDescription = if (visible) hideLabel else showLabel,
                )
            }
        },
        supportingText = { Text(supportingText) },
    )
}

private const val WIREGUARD_CONFIG_MAX_BYTES = 64 * 1024

/** Reads a picked wg-quick file; null when it is unreadable, empty, or over 64 KiB. */
private fun readWireGuardConfig(context: Context, uri: Uri): String? = runCatching {
    context.contentResolver.openInputStream(uri)?.use { stream ->
        val bytes = ByteArray(WIREGUARD_CONFIG_MAX_BYTES + 1)
        var total = 0
        while (total < bytes.size) {
            val count = stream.read(bytes, total, bytes.size - total)
            if (count < 0) break
            total += count
        }
        check(total <= WIREGUARD_CONFIG_MAX_BYTES) { "WireGuard config exceeds 64 KiB" }
        String(bytes, 0, total, Charsets.UTF_8)
    }
}.getOrNull()?.takeIf { it.isNotBlank() }

private const val OPENVPN_CONFIG_MAX_BYTES = 256 * 1024

/** Reads a picked .ovpn profile; null when it is unreadable, empty, or over 256 KiB. */
private fun readOpenVpnConfig(context: Context, uri: Uri): String? = runCatching {
    context.contentResolver.openInputStream(uri)?.use { stream ->
        val bytes = ByteArray(OPENVPN_CONFIG_MAX_BYTES + 1)
        var total = 0
        while (total < bytes.size) {
            val count = stream.read(bytes, total, bytes.size - total)
            if (count < 0) break
            total += count
        }
        check(total <= OPENVPN_CONFIG_MAX_BYTES) { "OpenVPN profile exceeds 256 KiB" }
        String(bytes, 0, total, Charsets.UTF_8)
    }
}.getOrNull()?.takeIf { it.isNotBlank() }

/** A few non-secret lines so the selected config can be recognised later. */
private fun wireGuardPreview(config: String): String {
    val secretKeys = setOf("privatekey", "presharedkey")
    return config.lineSequence()
        .map(String::trim)
        .filter { it.isNotEmpty() && !it.startsWith("#") && !it.startsWith(";") }
        .filterNot { secretKeys.contains(it.substringBefore('=').trim().lowercase()) }
        .take(4)
        .joinToString("\n")
        .take(240)
}
