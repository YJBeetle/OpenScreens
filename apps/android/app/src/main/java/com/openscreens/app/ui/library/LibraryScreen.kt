package com.openscreens.app.ui.library

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ViewList
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Monitor
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openscreens.app.R
import com.openscreens.app.data.Connection
import com.openscreens.app.ui.theme.ThemedSystemBarIcons
import com.openscreens.app.ui.theme.autoAccent
import com.openscreens.app.ui.theme.gradient
import java.net.URI

private enum class LibrarySort(@StringRes val labelRes: Int) {
    Az(R.string.library_sort_az),
    Za(R.string.library_sort_za),
    Recent(R.string.library_sort_recent),
}

private enum class LibraryView(@StringRes val labelRes: Int) {
    Grid(R.string.library_view_grid),
    List(R.string.library_view_list),
}

@Composable
fun LibraryScreen(
    connections: List<Connection>,
    onOpenConnection: (Connection) -> Unit,
    onAddConnection: () -> Unit,
    onEditConnection: (Connection) -> Unit,
    onOpenSettings: () -> Unit,
    onQuickConnect: (host: String, port: Int, username: String?) -> Unit,
) {
    ThemedSystemBarIcons()
    var searchActive by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    var sort by rememberSaveable { mutableStateOf(LibrarySort.Az) }
    var view by rememberSaveable { mutableStateOf(LibraryView.Grid) }
    var viewMenuExpanded by remember { mutableStateOf(false) }
    var moreMenuExpanded by remember { mutableStateOf(false) }
    var quickConnectOpen by rememberSaveable { mutableStateOf(false) }
    val focusRequester = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current

    LaunchedEffect(searchActive) {
        if (searchActive) {
            focusRequester.requestFocus()
        }
    }

    val visible = remember(connections, query, sort) {
        val filtered = if (query.isBlank()) {
            connections
        } else {
            connections.filter { connection ->
                connection.name.contains(query, ignoreCase = true) ||
                    connection.address.contains(query, ignoreCase = true)
            }
        }
        when (sort) {
            LibrarySort.Az -> filtered.sortedWith(
                compareBy(String.CASE_INSENSITIVE_ORDER) { connection: Connection -> connection.name },
            )
            LibrarySort.Za -> filtered.sortedWith(
                compareByDescending(String.CASE_INSENSITIVE_ORDER) { connection: Connection ->
                    connection.name
                },
            )
            LibrarySort.Recent -> filtered.sortedByDescending { it.lastConnectedAt ?: 0L }
        }
    }

    Scaffold(
        topBar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .windowInsetsPadding(WindowInsets.statusBars),
            ) {
                if (searchActive) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        IconButton(
                            onClick = {
                                searchActive = false
                                query = ""
                                focusManager.clearFocus()
                            },
                        ) {
                            Icon(
                                imageVector = Icons.Outlined.Close,
                                contentDescription = stringResource(R.string.library_close_search),
                            )
                        }
                        BasicTextField(
                            value = query,
                            onValueChange = { query = it },
                            singleLine = true,
                            textStyle = MaterialTheme.typography.bodyLarge.copy(
                                color = MaterialTheme.colorScheme.onSurface,
                            ),
                            cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                            modifier = Modifier
                                .weight(1f)
                                .focusRequester(focusRequester),
                            decorationBox = { innerTextField ->
                                Box(Modifier.fillMaxWidth()) {
                                    if (query.isEmpty()) {
                                        Text(
                                            text = stringResource(R.string.library_search_placeholder),
                                            style = MaterialTheme.typography.bodyLarge,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                    innerTextField()
                                }
                            },
                        )
                    }
                } else {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 8.dp, end = 4.dp, top = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Spacer(Modifier.weight(1f))
                        IconButton(onClick = { searchActive = true }) {
                            Icon(
                                imageVector = Icons.Outlined.Search,
                                contentDescription = stringResource(R.string.library_search),
                            )
                        }
                        IconButton(onClick = onAddConnection) {
                            Icon(
                                imageVector = Icons.Outlined.Add,
                                contentDescription = stringResource(R.string.library_add_connection),
                            )
                        }
                        IconButton(onClick = { quickConnectOpen = true }) {
                            Icon(
                                imageVector = Icons.Outlined.Bolt,
                                contentDescription = stringResource(R.string.library_quick_connect),
                            )
                        }
                        Box {
                            IconButton(onClick = { viewMenuExpanded = true }) {
                                Icon(
                                    imageVector = when (view) {
                                        LibraryView.Grid -> Icons.Outlined.GridView
                                        LibraryView.List -> Icons.AutoMirrored.Outlined.ViewList
                                    },
                                    contentDescription = stringResource(R.string.library_view_options),
                                )
                            }
                            ViewOptionsMenu(
                                expanded = viewMenuExpanded,
                                view = view,
                                sort = sort,
                                onDismiss = { viewMenuExpanded = false },
                                onViewSelected = {
                                    view = it
                                    viewMenuExpanded = false
                                },
                                onSortSelected = {
                                    sort = it
                                    viewMenuExpanded = false
                                },
                            )
                        }
                        Box {
                            IconButton(onClick = { moreMenuExpanded = true }) {
                                Icon(
                                    imageVector = Icons.Outlined.MoreVert,
                                    contentDescription = stringResource(R.string.library_more),
                                )
                            }
                            DropdownMenu(
                                expanded = moreMenuExpanded,
                                onDismissRequest = { moreMenuExpanded = false },
                            ) {
                                DropdownMenuItem(
                                    text = { Text(stringResource(R.string.library_settings)) },
                                    leadingIcon = {
                                        Icon(Icons.Outlined.Settings, contentDescription = null)
                                    },
                                    onClick = {
                                        moreMenuExpanded = false
                                        onOpenSettings()
                                    },
                                )
                            }
                        }
                    }
                    Text(
                        text = stringResource(R.string.library_title),
                        style = MaterialTheme.typography.headlineMedium,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 2.dp),
                    )
                    Text(
                        text = stringResource(R.string.library_count, visible.size),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(
                            start = 20.dp,
                            end = 20.dp,
                            top = 2.dp,
                            bottom = 8.dp,
                        ),
                    )
                }
            }
        },
    ) { innerPadding ->
        if (connections.isEmpty()) {
            EmptyLibrary(
                onAddConnection = onAddConnection,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding),
            )
        } else {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding),
            ) {
                if (visible.isEmpty()) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(32.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = stringResource(R.string.library_no_results),
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                } else {
                    when (view) {
                        LibraryView.Grid -> LazyVerticalGrid(
                            columns = GridCells.Fixed(2),
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(top = 4.dp),
                            contentPadding = PaddingValues(
                                start = 16.dp,
                                end = 16.dp,
                                bottom = 24.dp,
                            ),
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            items(visible, key = { it.id }) { connection ->
                                ConnectionCard(
                                    connection = connection,
                                    onClick = { onOpenConnection(connection) },
                                    onEdit = { onEditConnection(connection) },
                                )
                            }
                        }

                        LibraryView.List -> LazyColumn(
                            modifier = Modifier.fillMaxSize(),
                            contentPadding = PaddingValues(
                                start = 16.dp,
                                end = 16.dp,
                                top = 4.dp,
                                bottom = 24.dp,
                            ),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            items(visible, key = { it.id }) { connection ->
                                ConnectionRow(
                                    connection = connection,
                                    onClick = { onOpenConnection(connection) },
                                    onEdit = { onEditConnection(connection) },
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    if (quickConnectOpen) {
        QuickConnectDialog(
            onDismiss = { quickConnectOpen = false },
            onConnect = { target ->
                quickConnectOpen = false
                onQuickConnect(target.host, target.port, target.username)
            },
        )
    }
}

@Composable
private fun ViewOptionsMenu(
    expanded: Boolean,
    view: LibraryView,
    sort: LibrarySort,
    onDismiss: () -> Unit,
    onViewSelected: (LibraryView) -> Unit,
    onSortSelected: (LibrarySort) -> Unit,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        LibraryView.entries.forEach { option ->
            DropdownMenuItem(
                text = { Text(stringResource(option.labelRes)) },
                leadingIcon = {
                    MenuLead(
                        selected = option == view,
                        icon = when (option) {
                            LibraryView.Grid -> Icons.Outlined.GridView
                            LibraryView.List -> Icons.AutoMirrored.Outlined.ViewList
                        },
                    )
                },
                onClick = { onViewSelected(option) },
            )
        }
        HorizontalDivider(Modifier.padding(vertical = 4.dp))
        LibrarySort.entries.forEach { option ->
            DropdownMenuItem(
                text = { Text(stringResource(option.labelRes)) },
                leadingIcon = { MenuLead(selected = option == sort) },
                onClick = { onSortSelected(option) },
            )
        }
    }
}

@Composable
private fun MenuLead(selected: Boolean, icon: ImageVector? = null) {
    Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
        when {
            selected -> Icon(
                imageVector = Icons.Outlined.Check,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
            )
            icon != null -> Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun QuickConnectDialog(
    onDismiss: () -> Unit,
    onConnect: (QuickConnectTarget) -> Unit,
) {
    var url by rememberSaveable { mutableStateOf("") }
    val target = remember(url) { parseQuickConnectUrl(url) }
    val focusRequester = remember { FocusRequester() }

    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    AlertDialog(
        onDismissRequest = onDismiss,
        icon = {
            Icon(
                imageVector = Icons.Outlined.Bolt,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(28.dp),
            )
        },
        title = { Text(stringResource(R.string.library_quick_connect)) },
        text = {
            Column {
                Text(
                    text = stringResource(R.string.library_quick_connect_subtitle),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = url,
                    onValueChange = { url = it },
                    singleLine = true,
                    label = { Text(stringResource(R.string.library_quick_connect_url)) },
                    placeholder = { Text("vnc://user@host:5900") },
                    isError = url.isNotBlank() && target == null,
                    supportingText = {
                        Text(
                            stringResource(
                                if (url.isNotBlank() && target == null) {
                                    R.string.library_quick_connect_invalid
                                } else {
                                    R.string.library_quick_connect_hint
                                },
                            ),
                        )
                    },
                    keyboardOptions = KeyboardOptions(
                        autoCorrectEnabled = false,
                        keyboardType = KeyboardType.Uri,
                        imeAction = ImeAction.Go,
                    ),
                    modifier = Modifier
                        .fillMaxWidth()
                        .focusRequester(focusRequester),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { target?.let(onConnect) },
                enabled = target != null,
            ) {
                Text(stringResource(R.string.library_quick_connect_action))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.library_cancel))
            }
        },
    )
}

@Composable
private fun ConnectionCard(
    connection: Connection,
    onClick: () -> Unit,
    onEdit: () -> Unit,
) {
    val gradient = (connection.accent ?: autoAccent(connection.name)).gradient
    val thumbnailDescription = stringResource(R.string.library_connection_thumbnail)
    val editDescription = stringResource(R.string.library_edit_connection)

    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(18.dp),
    ) {
        Column {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(92.dp)
                    .background(Brush.linearGradient(listOf(gradient.start, gradient.end)))
                    .semantics { contentDescription = thumbnailDescription },
            ) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .padding(10.dp)
                        .size(30.dp)
                        .clip(RoundedCornerShape(9.dp))
                        .background(Color.Black.copy(alpha = 0.18f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Monitor,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(17.dp),
                    )
                }
                Box(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(6.dp)
                        .size(28.dp)
                        .clip(CircleShape)
                        .background(Color.Black.copy(alpha = 0.26f))
                        .clickable(onClick = onEdit)
                        .semantics { contentDescription = editDescription },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Edit,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(15.dp),
                    )
                }
            }
            Column(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = connection.name,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = connection.address,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun ConnectionRow(
    connection: Connection,
    onClick: () -> Unit,
    onEdit: () -> Unit,
) {
    val gradient = (connection.accent ?: autoAccent(connection.name)).gradient
    val editDescription = stringResource(R.string.library_edit_connection)

    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(18.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(64.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(Brush.linearGradient(listOf(gradient.start, gradient.end))),
            ) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomStart)
                        .padding(8.dp)
                        .size(30.dp)
                        .clip(RoundedCornerShape(9.dp))
                        .background(Color.Black.copy(alpha = 0.18f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Monitor,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(17.dp),
                    )
                }
            }
            Spacer(Modifier.width(12.dp))
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = connection.name,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = connection.address,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            IconButton(onClick = onEdit) {
                Icon(
                    imageVector = Icons.Outlined.Edit,
                    contentDescription = editDescription,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun EmptyLibrary(onAddConnection: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            modifier = Modifier
                .size(88.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Outlined.Monitor,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onPrimaryContainer,
                modifier = Modifier.size(40.dp),
            )
        }
        Spacer(Modifier.height(24.dp))
        Text(
            text = stringResource(R.string.library_empty_title),
            style = MaterialTheme.typography.titleLarge,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = stringResource(R.string.library_empty_body),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(24.dp))
        Button(onClick = onAddConnection) {
            Icon(Icons.Outlined.Add, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.library_empty_action))
        }
    }
}
