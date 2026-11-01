package com.openscreens.app.ui.library

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ViewList
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Monitor
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
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
import com.openscreens.app.data.ConnectionGroup
import com.openscreens.app.data.LibrarySortOrder
import com.openscreens.app.data.sortedForLibrary
import com.openscreens.app.ui.theme.ThemedSystemBarIcons
import com.openscreens.app.ui.theme.autoAccent
import com.openscreens.app.ui.theme.gradient
import java.net.URI

private enum class LibraryView(@StringRes val labelRes: Int) {
    Grid(R.string.library_view_grid),
    List(R.string.library_view_list),
}

@StringRes
private fun LibrarySortOrder.labelRes(): Int = when (this) {
    LibrarySortOrder.Manual -> R.string.library_sort_manual
    LibrarySortOrder.Az -> R.string.library_sort_az
    LibrarySortOrder.Za -> R.string.library_sort_za
    LibrarySortOrder.Recent -> R.string.library_sort_recent
}

private sealed interface GroupDialog {
    data object Create : GroupDialog

    data class Rename(val group: ConnectionGroup) : GroupDialog
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(
    connections: List<Connection>,
    groups: List<ConnectionGroup>,
    sort: LibrarySortOrder,
    onSortChange: (LibrarySortOrder) -> Unit,
    onAddGroup: (String) -> Unit,
    onRenameGroup: (id: String, name: String) -> Unit,
    onDeleteGroup: (id: String) -> Unit,
    onMoveConnection: (id: String, offset: Int, orderedIds: List<String>) -> Unit,
    onOpenConnection: (Connection) -> Unit,
    onOpenInNewWindow: (Connection) -> Unit,
    onAddConnection: () -> Unit,
    onEditConnection: (Connection) -> Unit,
    onOpenSettings: () -> Unit,
    onQuickConnect: (host: String, port: Int, username: String?) -> Unit,
) {
    ThemedSystemBarIcons()
    var searchActive by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    var selectedGroupId by rememberSaveable { mutableStateOf<String?>(null) }
    var groupDialog by remember { mutableStateOf<GroupDialog?>(null) }
    var deleteGroup by remember { mutableStateOf<ConnectionGroup?>(null) }
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

    LaunchedEffect(groups, selectedGroupId) {
        val selected = selectedGroupId
        if (selected != null && groups.none { it.id == selected }) {
            selectedGroupId = null
        }
    }

    val visible = remember(connections, query, sort, selectedGroupId) {
        val scoped = if (selectedGroupId == null) {
            connections
        } else {
            connections.filter { it.groupId == selectedGroupId }
        }
        val filtered = if (query.isBlank()) {
            scoped
        } else {
            scoped.filter { connection ->
                connection.name.contains(query, ignoreCase = true) ||
                    connection.address.contains(query, ignoreCase = true)
            }
        }
        filtered.sortedForLibrary(sort)
    }

    Scaffold(
        topBar = {
            if (searchActive) {
                TopAppBar(
                    navigationIcon = {
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
                    },
                    title = {
                        BasicTextField(
                            value = query,
                            onValueChange = { query = it },
                            singleLine = true,
                            textStyle = MaterialTheme.typography.bodyLarge.copy(
                                color = MaterialTheme.colorScheme.onSurface,
                            ),
                            cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                            modifier = Modifier
                                .fillMaxWidth()
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
                    },
                )
            } else {
                TopAppBar(
                    title = {
                        Text(
                            text = stringResource(R.string.library_title),
                            fontWeight = FontWeight.SemiBold,
                        )
                    },
                    actions = {
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
                                    onSortChange(it)
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
                    },
                )
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
                GroupChipsRow(
                    groups = groups,
                    selectedGroupId = selectedGroupId,
                    onSelect = { selectedGroupId = it },
                    onCreate = { groupDialog = GroupDialog.Create },
                    onRename = { groupDialog = GroupDialog.Rename(it) },
                    onDelete = { deleteGroup = it },
                    modifier = Modifier.padding(top = 8.dp),
                )
                Text(
                    text = stringResource(R.string.library_count, visible.size),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(
                        start = 16.dp,
                        end = 16.dp,
                        top = 8.dp,
                        bottom = 4.dp,
                    ),
                )
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
                    val visibleIds = remember(visible) { visible.map { it.id } }
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
                            itemsIndexed(visible, key = { _, it -> it.id }) { index, connection ->
                                val manual = sort == LibrarySortOrder.Manual
                                ConnectionCard(
                                    connection = connection,
                                    onClick = { onOpenConnection(connection) },
                                    onEdit = { onEditConnection(connection) },
                                    onOpenInNewWindow = { onOpenInNewWindow(connection) },
                                    onMoveUp = if (manual && index > 0) {
                                        ({ onMoveConnection(connection.id, -1, visibleIds) })
                                    } else {
                                        null
                                    },
                                    onMoveDown = if (manual && index < visible.lastIndex) {
                                        ({ onMoveConnection(connection.id, 1, visibleIds) })
                                    } else {
                                        null
                                    },
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
                            itemsIndexed(visible, key = { _, it -> it.id }) { index, connection ->
                                val manual = sort == LibrarySortOrder.Manual
                                ConnectionRow(
                                    connection = connection,
                                    onClick = { onOpenConnection(connection) },
                                    onEdit = { onEditConnection(connection) },
                                    onOpenInNewWindow = { onOpenInNewWindow(connection) },
                                    onMoveUp = if (manual && index > 0) {
                                        ({ onMoveConnection(connection.id, -1, visibleIds) })
                                    } else {
                                        null
                                    },
                                    onMoveDown = if (manual && index < visible.lastIndex) {
                                        ({ onMoveConnection(connection.id, 1, visibleIds) })
                                    } else {
                                        null
                                    },
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

    when (val dialog = groupDialog) {
        is GroupDialog.Create -> GroupNameDialog(
            title = stringResource(R.string.library_new_group),
            initialName = "",
            confirmLabel = stringResource(R.string.library_group_create),
            onDismiss = { groupDialog = null },
            onConfirm = { name ->
                groupDialog = null
                onAddGroup(name)
            },
        )

        is GroupDialog.Rename -> GroupNameDialog(
            title = stringResource(R.string.library_rename_group),
            initialName = dialog.group.name,
            confirmLabel = stringResource(R.string.library_group_rename),
            onDismiss = { groupDialog = null },
            onConfirm = { name ->
                groupDialog = null
                onRenameGroup(dialog.group.id, name)
            },
        )

        null -> Unit
    }

    deleteGroup?.let { group ->
        AlertDialog(
            onDismissRequest = { deleteGroup = null },
            title = { Text(stringResource(R.string.library_delete_group_title)) },
            text = { Text(stringResource(R.string.library_delete_group_body, group.name)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        deleteGroup = null
                        onDeleteGroup(group.id)
                    },
                ) {
                    Text(
                        text = stringResource(R.string.library_delete_group_action),
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteGroup = null }) {
                    Text(stringResource(R.string.library_cancel))
                }
            },
        )
    }
}

@Composable
private fun GroupChipsRow(
    groups: List<ConnectionGroup>,
    selectedGroupId: String?,
    onSelect: (String?) -> Unit,
    onCreate: () -> Unit,
    onRename: (ConnectionGroup) -> Unit,
    onDelete: (ConnectionGroup) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        LibraryChip(
            label = stringResource(R.string.library_group_all),
            selected = selectedGroupId == null,
            onClick = { onSelect(null) },
        )
        groups.forEach { group ->
            var menuExpanded by remember { mutableStateOf(false) }
            Box {
                LibraryChip(
                    label = group.name,
                    selected = selectedGroupId == group.id,
                    onClick = { onSelect(group.id) },
                    onLongClick = { menuExpanded = true },
                )
                DropdownMenu(
                    expanded = menuExpanded,
                    onDismissRequest = { menuExpanded = false },
                ) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.library_rename_group)) },
                        leadingIcon = { Icon(Icons.Outlined.Edit, contentDescription = null) },
                        onClick = {
                            menuExpanded = false
                            onRename(group)
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.library_delete_group_title)) },
                        leadingIcon = { Icon(Icons.Outlined.Delete, contentDescription = null) },
                        onClick = {
                            menuExpanded = false
                            onDelete(group)
                        },
                    )
                }
            }
        }
        LibraryChip(
            label = stringResource(R.string.library_new_group),
            selected = false,
            icon = Icons.Outlined.Add,
            onClick = onCreate,
        )
    }
}

@Composable
private fun LibraryChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
    icon: ImageVector? = null,
) {
    val container = if (selected) {
        MaterialTheme.colorScheme.secondaryContainer
    } else {
        Color.Transparent
    }
    val content = if (selected) {
        MaterialTheme.colorScheme.onSecondaryContainer
    } else {
        MaterialTheme.colorScheme.onSurfaceVariant
    }
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(container)
            .border(
                width = 1.dp,
                color = if (selected) Color.Transparent else MaterialTheme.colorScheme.outlineVariant,
                shape = CircleShape,
            )
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
            .padding(horizontal = 14.dp, vertical = 7.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon?.let {
            Icon(
                imageVector = it,
                contentDescription = null,
                tint = content,
                modifier = Modifier.size(16.dp),
            )
        }
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge,
            color = content,
        )
    }
}

@Composable
private fun GroupNameDialog(
    title: String,
    initialName: String,
    confirmLabel: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var name by rememberSaveable(initialName) { mutableStateOf(initialName) }
    val focusRequester = remember { FocusRequester() }

    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                singleLine = true,
                label = { Text(stringResource(R.string.library_group_name)) },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                modifier = Modifier
                    .fillMaxWidth()
                    .focusRequester(focusRequester),
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(name) },
                enabled = name.isNotBlank(),
            ) {
                Text(confirmLabel)
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
private fun ViewOptionsMenu(
    expanded: Boolean,
    view: LibraryView,
    sort: LibrarySortOrder,
    onDismiss: () -> Unit,
    onViewSelected: (LibraryView) -> Unit,
    onSortSelected: (LibrarySortOrder) -> Unit,
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
        LibrarySortOrder.entries.forEach { option ->
            DropdownMenuItem(
                text = { Text(stringResource(option.labelRes())) },
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
    onOpenInNewWindow: () -> Unit,
    onMoveUp: (() -> Unit)? = null,
    onMoveDown: (() -> Unit)? = null,
) {
    val gradient = (connection.accent ?: autoAccent(connection.name)).gradient
    val thumbnailDescription = stringResource(R.string.library_connection_thumbnail)
    val editDescription = stringResource(R.string.library_edit_connection)
    var menuExpanded by remember { mutableStateOf(false) }

    Box {
    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(
                onClick = onClick,
                onLongClick = { menuExpanded = true },
            ),
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
    DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
        DropdownMenuItem(
            text = { Text(stringResource(R.string.session_open_in_new_window)) },
            leadingIcon = { Icon(Icons.Outlined.OpenInNew, contentDescription = null) },
            onClick = {
                menuExpanded = false
                onOpenInNewWindow()
            },
        )
        DropdownMenuItem(
            text = { Text(stringResource(R.string.library_edit_connection)) },
            leadingIcon = { Icon(Icons.Outlined.Edit, contentDescription = null) },
            onClick = {
                menuExpanded = false
                onEdit()
            },
        )
        MoveMenuItems(
            onMoveUp = onMoveUp,
            onMoveDown = onMoveDown,
            onDismiss = { menuExpanded = false },
        )
    }
    }
}

@Composable
private fun ConnectionRow(
    connection: Connection,
    onClick: () -> Unit,
    onEdit: () -> Unit,
    onOpenInNewWindow: () -> Unit,
    onMoveUp: (() -> Unit)? = null,
    onMoveDown: (() -> Unit)? = null,
) {
    val gradient = (connection.accent ?: autoAccent(connection.name)).gradient
    val editDescription = stringResource(R.string.library_edit_connection)
    var menuExpanded by remember { mutableStateOf(false) }

    Box {
    ElevatedCard(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(
                onClick = onClick,
                onLongClick = { menuExpanded = true },
            ),
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
    DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
        DropdownMenuItem(
            text = { Text(stringResource(R.string.session_open_in_new_window)) },
            leadingIcon = { Icon(Icons.Outlined.OpenInNew, contentDescription = null) },
            onClick = {
                menuExpanded = false
                onOpenInNewWindow()
            },
        )
        DropdownMenuItem(
            text = { Text(stringResource(R.string.library_edit_connection)) },
            leadingIcon = { Icon(Icons.Outlined.Edit, contentDescription = null) },
            onClick = {
                menuExpanded = false
                onEdit()
            },
        )
        MoveMenuItems(
            onMoveUp = onMoveUp,
            onMoveDown = onMoveDown,
            onDismiss = { menuExpanded = false },
        )
    }
    }
}

@Composable
private fun MoveMenuItems(
    onMoveUp: (() -> Unit)?,
    onMoveDown: (() -> Unit)?,
    onDismiss: () -> Unit,
) {
    if (onMoveUp == null && onMoveDown == null) return
    HorizontalDivider(Modifier.padding(vertical = 4.dp))
    onMoveUp?.let { move ->
        DropdownMenuItem(
            text = { Text(stringResource(R.string.library_move_up)) },
            leadingIcon = { Icon(Icons.Outlined.ArrowUpward, contentDescription = null) },
            onClick = {
                onDismiss()
                move()
            },
        )
    }
    onMoveDown?.let { move ->
        DropdownMenuItem(
            text = { Text(stringResource(R.string.library_move_down)) },
            leadingIcon = { Icon(Icons.Outlined.ArrowDownward, contentDescription = null) },
            onClick = {
                onDismiss()
                move()
            },
        )
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
