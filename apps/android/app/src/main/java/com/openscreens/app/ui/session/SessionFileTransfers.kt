package com.openscreens.app.ui.session

import android.content.ClipData
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.openscreens.app.R
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

internal data class SessionTransferItem(val name: String, val folder: String, val localFile: File? = null)

@Composable
internal fun SessionFileTransfers(
    receivedFiles: List<SessionTransferItem>,
    sentFiles: List<SessionTransferItem>,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    var openFailed by remember { mutableStateOf(false) }
    var directories by remember { mutableStateOf<List<File>>(emptyList()) }
    val directory = directories.lastOrNull()
    var directoryItems by remember(directory) { mutableStateOf<List<SessionTransferItem>?>(null) }

    LaunchedEffect(directory) {
        if (directory != null) {
            directoryItems = withContext(Dispatchers.IO) {
                directory.listFiles().orEmpty().sortedBy { it.name }.map {
                    SessionTransferItem(it.name, directory.absolutePath, it)
                }
            }
        }
    }

    val visibleReceived = if (directory == null) receivedFiles else directoryItems.orEmpty()
    val visibleSent = if (directory == null) sentFiles else emptyList()
    val goBack = {
        openFailed = false
        directories = directories.dropLast(1)
    }
    AlertDialog(
        onDismissRequest = { if (directory == null) onDismiss() else goBack() },
        title = { Text(directory?.name ?: stringResource(R.string.session_file_transfers)) },
        text = {
            Column {
                if (openFailed) {
                    Text(
                        stringResource(R.string.session_transfer_open_failed),
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                if (directory != null && directoryItems == null) {
                    CircularProgressIndicator()
                } else if (visibleReceived.isEmpty() && visibleSent.isEmpty()) {
                    val message = if (directory == null) {
                        R.string.session_transfer_empty
                    } else {
                        R.string.session_transfer_directory_empty
                    }
                    Text(stringResource(message))
                } else {
                    LazyColumn(Modifier.heightIn(max = 400.dp)) {
                        if (visibleReceived.isNotEmpty()) {
                            if (directory == null) {
                                item {
                                    Text(
                                        stringResource(R.string.session_transfer_received),
                                        style = MaterialTheme.typography.titleSmall,
                                    )
                                }
                            }
                            items(visibleReceived) { item ->
                                ListItem(
                                    headlineContent = { Text(item.name) },
                                    supportingContent = {
                                        Column {
                                            SelectionContainer {
                                                Text(stringResource(R.string.session_transfer_saved_in, item.folder))
                                            }
                                            val file = item.localFile
                                            if (file?.isDirectory == true) {
                                                TextButton(onClick = {
                                                    openFailed = false
                                                    directories = directories + file
                                                }) { Text(stringResource(R.string.session_transfer_browse)) }
                                            } else if (file?.isFile == true) {
                                                Row {
                                                    TextButton(onClick = {
                                                        openFailed = !launchFileIntent(context, file, share = false)
                                                    }) { Text(stringResource(R.string.session_transfer_open)) }
                                                    TextButton(onClick = {
                                                        openFailed = !launchFileIntent(context, file, share = true)
                                                    }) { Text(stringResource(R.string.session_transfer_share)) }
                                                }
                                            }
                                        }
                                    },
                                )
                            }
                        }
                        if (visibleSent.isNotEmpty()) {
                            item {
                                Text(
                                    stringResource(R.string.session_transfer_sent),
                                    style = MaterialTheme.typography.titleSmall,
                                )
                            }
                            items(visibleSent) { item ->
                                ListItem(
                                    headlineContent = { Text(item.name) },
                                    supportingContent = {
                                        SelectionContainer {
                                            Text(stringResource(R.string.session_transfer_sent_to, item.folder))
                                        }
                                    },
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.session_transfer_done)) }
        },
        dismissButton = {
            if (directory != null) {
                TextButton(onClick = goBack) { Text(stringResource(R.string.session_transfer_back)) }
            }
        },
    )
}

private fun launchFileIntent(context: Context, file: File, share: Boolean): Boolean = runCatching {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.transfers", file)
    val mimeType = context.contentResolver.getType(uri) ?: "application/octet-stream"
    val intent = if (share) {
        Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri(file.name, uri)
        }
    } else {
        Intent(Intent.ACTION_VIEW).setDataAndType(uri, mimeType)
    }
    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(if (share) Intent.createChooser(intent, null) else intent)
}.isSuccess
