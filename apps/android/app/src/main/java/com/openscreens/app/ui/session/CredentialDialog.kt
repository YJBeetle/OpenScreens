package com.openscreens.app.ui.session

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.openscreens.app.R
import com.openscreens.app.session.CredentialChallenge

@Composable
internal fun CredentialDialog(
    challenge: CredentialChallenge,
    endpoint: String,
    initialUsername: String,
    initiallyRemember: Boolean,
    onCancel: () -> Unit,
    onSubmit: (String, String, Boolean) -> Unit,
) {
    val requiresUsername = challenge == CredentialChallenge.MissingUsername
    var showUsername by remember { mutableStateOf(requiresUsername || initialUsername.isNotEmpty()) }
    var username by remember { mutableStateOf(initialUsername) }
    var password by remember { mutableStateOf("") }
    var rememberLogin by remember { mutableStateOf(initiallyRemember) }
    val canConnect = password.isNotEmpty() && (!requiresUsername || username.isNotBlank())
    val submit = { if (canConnect) onSubmit(username.trim(), password, rememberLogin) }
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text(stringResource(R.string.session_auth_required)) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(endpoint)
                if (challenge == CredentialChallenge.Rejected) {
                    Text(stringResource(R.string.session_auth_rejected), color = MaterialTheme.colorScheme.error)
                }
                if (showUsername) {
                    OutlinedTextField(
                        value = username, onValueChange = { username = it }, singleLine = true,
                        label = { Text(stringResource(R.string.editor_username)) },
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                    )
                } else {
                    TextButton(onClick = { showUsername = true }) { Text(stringResource(R.string.session_use_account)) }
                }
                OutlinedTextField(
                    value = password, onValueChange = { password = it }, singleLine = true,
                    label = { Text(stringResource(R.string.editor_ssh_auth_password)) },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { submit() }),
                )
                Row(
                    Modifier.toggleable(rememberLogin, role = Role.Checkbox) { rememberLogin = it },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Checkbox(checked = rememberLogin, onCheckedChange = null)
                    Text(stringResource(R.string.session_remember_credentials))
                }
            }
        },
        confirmButton = {
            TextButton(onClick = submit, enabled = canConnect) { Text(stringResource(R.string.library_quick_connect_action)) }
        },
        dismissButton = {
            TextButton(onClick = onCancel) { Text(stringResource(R.string.library_cancel)) }
        },
    )
}
