package com.openscreens.app.ui.editor

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.openscreens.app.R
import com.openscreens.app.data.Connection
import com.openscreens.app.data.SshCredentials
import com.openscreens.app.ui.theme.ThemedSystemBarIcons

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectionEditorScreen(
    connection: Connection?,
    onSave: (Connection) -> Unit,
    onCancel: () -> Unit,
) {
    ThemedSystemBarIcons()

    val editorKey = connection?.id
    var name by rememberSaveable(editorKey) { mutableStateOf(connection?.name.orEmpty()) }
    var host by rememberSaveable(editorKey) { mutableStateOf(connection?.host.orEmpty()) }
    var port by rememberSaveable(editorKey) {
        mutableStateOf((connection?.port ?: Connection.DEFAULT_VNC_PORT).toString())
    }
    var vncPassword by rememberSaveable(editorKey) {
        mutableStateOf(connection?.vncPassword.orEmpty())
    }
    var username by rememberSaveable(editorKey) {
        mutableStateOf(connection?.username.orEmpty())
    }
    var sshEnabled by rememberSaveable(editorKey) { mutableStateOf(connection?.ssh != null) }
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
    var validate by rememberSaveable { mutableStateOf(false) }

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

    val onSaveClick: () -> Unit = {
        validate = true
        if (nameError == null && hostError == null && portError == null &&
            sshUsernameError == null && sshPortError == null
        ) {
            val ssh = if (sshEnabled) {
                SshCredentials(
                    username = sshUsername.trim(),
                    password = sshPassword,
                    port = sshPortNumber ?: SshCredentials.DEFAULT_SSH_PORT,
                    hostKeyFingerprint = sshFingerprint.trim(),
                )
            } else {
                null
            }
            val draft = (connection ?: Connection(name = "", host = "")).copy(
                name = name.trim(),
                host = host.trim(),
                port = portNumber ?: Connection.DEFAULT_VNC_PORT,
                username = username.trim(),
                vncPassword = vncPassword,
                ssh = ssh,
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
                        PasswordField(
                            value = sshPassword,
                            onValueChange = { sshPassword = it },
                            label = stringResource(R.string.editor_ssh_password),
                            supportingText = stringResource(R.string.editor_ssh_password_optional),
                        )
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
