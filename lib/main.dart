import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:process_run/process_run.dart' show shellArgument, whichSync;

const List<Color> hostColorChoices = [
  Color(0xFF1D4ED8),
  Color(0xFF7C3AED),
  Color(0xFF0F766E),
  Color(0xFFB45309),
  Color(0xFFFACC15),
  Color(0xFFDC2626),
  Color(0xFF0891B2),
  Color(0xFF4F46E5),
  Color(0xFF65A30D),
  Color(0xFFC0C0C0),
];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final packageInfo = await PackageInfo.fromPlatform();
  runApp(MyApp(version: packageInfo.version));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.storage, required this.version});

  final VibeDashStorage? storage;
  final String version;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VibeDash $version',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B8CFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0C111B),
        useMaterial3: true,
      ),
      home: VibeDashPrototype(storage: storage, version: version),
    );
  }
}

class VibeDashPrototype extends StatefulWidget {
  const VibeDashPrototype({super.key, this.storage, required this.version});

  final VibeDashStorage? storage;
  final String version;

  @override
  State<VibeDashPrototype> createState() => _VibeDashPrototypeState();
}

class _VibeDashPrototypeState extends State<VibeDashPrototype> {
  final List<VibeProject> _projects = List<VibeProject>.of(
    seedProjects(),
    growable: true,
  );
  final List<RemoteHost> _hosts = List<RemoteHost>.of(
    seedHosts(),
    growable: true,
  );
  final Map<String, String?> _deployments = seedDeployments();

  int _nextProjectNumber = 6;
  int _nextHostNumber = 5;
  bool _hostManagementUnlocked = false;
  bool _isLoading = true;
  String? _persistenceError;
  late final VibeDashStorage _storage;

  @override
  void initState() {
    super.initState();
    _storage = widget.storage ?? const FileVibeDashStorage();
    _loadPersistedState();
  }

  Map<String, VibeProject> get _projectsById => {
    for (final project in _projects) project.id: project,
  };

  Future<void> _loadPersistedState() async {
    try {
      final persistedState = await _storage.readState();
      final nextState = persistedState ?? VibeDashDocument.seeded();
      if (!mounted) {
        return;
      }
      setState(() {
        _replaceDashboardState(nextState);
        _isLoading = false;
        _persistenceError = null;
      });
    } on FileSystemException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _replaceDashboardState(VibeDashDocument.seeded());
        _isLoading = false;
        _persistenceError = _describeFileSystemError(error, action: 'load');
      });
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _replaceDashboardState(VibeDashDocument.seeded());
        _isLoading = false;
        _persistenceError = 'Could not load dashboard state: ${error.message}';
      });
    }
  }

  Future<void> _persistCurrentState() async {
    final document = VibeDashDocument.fromState(
      projects: _projects,
      hosts: _hosts,
      deployments: _deployments,
    );

    try {
      await _storage.writeState(document);
      if (!mounted || _persistenceError == null) {
        return;
      }
      setState(() {
        _persistenceError = null;
      });
    } on FileSystemException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _persistenceError = _describeFileSystemError(error, action: 'save');
      });
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _persistenceError = 'Could not save dashboard state: ${error.message}';
      });
    }
  }

  Future<void> _persistIfLocked() async {
    if (!_hostManagementUnlocked) {
      await _persistCurrentState();
    }
  }

  void _replaceDashboardState(VibeDashDocument document) {
    _projects
      ..clear()
      ..addAll(document.projects);
    _hosts
      ..clear()
      ..addAll(document.hosts);
    _deployments
      ..clear()
      ..addAll(document.toDeploymentMap());
    _nextProjectNumber = nextIdNumber(
      ids: _projects.map((project) => project.id),
      prefix: 'p',
    );
    _nextHostNumber = nextIdNumber(
      ids: _hosts.map((host) => host.id),
      prefix: 'h',
    );
  }

  Future<void> _deployProjectToHost(String projectId, String hostId) async {
    final existingProjectId = _deployments[hostId];
    final sourceHostId = _hostForProject(projectId);
    if (existingProjectId == projectId) {
      return;
    }

    if (sourceHostId != null && sourceHostId != hostId) {
      final sourceHostIndex = _hosts.indexWhere(
        (candidate) => candidate.id == sourceHostId,
      );
      final sourceHost = sourceHostIndex == -1 ? null : _hosts[sourceHostIndex];
      final incomingProject = _projectsById[projectId];
      final targetHostIndex = _hosts.indexWhere(
        (candidate) => candidate.id == hostId,
      );
      final targetHost = targetHostIndex == -1 ? null : _hosts[targetHostIndex];

      final shouldMove = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Move deployment?'),
          content: Text(
            '${incomingProject?.name ?? 'This project'} is already deployed on '
            '${sourceHost?.name ?? 'another host'}. Move it to '
            '${targetHost?.name ?? 'this host'}?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('confirm-move-button'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Move'),
            ),
          ],
        ),
      );

      if (!mounted || shouldMove != true) {
        return;
      }
    }

    if (existingProjectId != null) {
      final existingProject = _projectsById[existingProjectId];
      final hostIndex = _hosts.indexWhere(
        (candidate) => candidate.id == hostId,
      );
      final host = hostIndex == -1 ? null : _hosts[hostIndex];
      final incomingProject = _projectsById[projectId];

      final shouldReplace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Replace deployment?'),
          content: Text(
            '${host?.name ?? 'This host'} is already running ${existingProject?.name ?? 'another project'}. '
            'Deploy ${incomingProject?.name ?? 'this project'} here instead?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('confirm-redeploy-button'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Deploy'),
            ),
          ],
        ),
      );

      if (!mounted || shouldReplace != true) {
        return;
      }
    }

    setState(() {
      for (final entry in _deployments.entries) {
        if (entry.value == projectId) {
          _deployments[entry.key] = null;
        }
      }
      _deployments[hostId] = projectId;
    });
    await _persistIfLocked();
  }

  String? _hostForProject(String projectId) {
    for (final entry in _deployments.entries) {
      if (entry.value == projectId) {
        return entry.key;
      }
    }
    return null;
  }

  Future<void> _addProject() async {
    final draft = await showDialog<ProjectDraft>(
      context: context,
      builder: (context) => const ProjectEditorDialog(
        title: 'Add project',
        confirmLabel: 'Add project',
      ),
    );

    if (!mounted || draft == null) {
      return;
    }

    setState(() {
      final projectId = 'p$_nextProjectNumber';
      _nextProjectNumber += 1;
      _projects.insert(
        0,
        VibeProject(
          id: projectId,
          name: draft.name,
          githubUrl: draft.githubUrl,
          label: draft.label,
        ),
      );
    });
  }

  Future<void> _editProject(VibeProject project) async {
    final draft = await showDialog<ProjectDraft>(
      context: context,
      builder: (context) => ProjectEditorDialog(
        title: 'Edit project',
        confirmLabel: 'Save changes',
        initialProject: project,
      ),
    );

    if (!mounted || draft == null) {
      return;
    }

    setState(() {
      final projectIndex = _projects.indexWhere(
        (candidate) => candidate.id == project.id,
      );
      if (projectIndex == -1) {
        return;
      }

      _projects[projectIndex] = project.copyWith(
        name: draft.name,
        githubUrl: draft.githubUrl,
        label: draft.label,
      );
    });
  }

  Future<void> _deleteProject(VibeProject project) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete project'),
        content: Text(
          _hostForProject(project.id) == null
              ? 'Delete ${project.name}?'
              : 'Delete ${project.name} and undeploy it from its host?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-delete-project'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (!mounted || shouldDelete != true) {
      return;
    }

    setState(() {
      _projects.removeWhere((candidate) => candidate.id == project.id);
      for (final entry in _deployments.entries) {
        if (entry.value == project.id) {
          _deployments[entry.key] = null;
        }
      }
    });
  }

  Future<void> _addHost() async {
    final draft = await showDialog<HostDraft>(
      context: context,
      builder: (context) =>
          const HostEditorDialog(title: 'Add host', confirmLabel: 'Add host'),
    );

    if (!mounted || draft == null) {
      return;
    }

    setState(() {
      final hostId = 'h$_nextHostNumber';
      _nextHostNumber += 1;
      _hosts.add(
        RemoteHost(
          id: hostId,
          name: draft.name,
          color: draft.color,
          connectCommand: draft.connectCommand,
        ),
      );
      _deployments[hostId] = null;
    });
  }

  Future<void> _editHost(RemoteHost host) async {
    final draft = await showDialog<HostDraft>(
      context: context,
      builder: (context) => HostEditorDialog(
        title: 'Edit host',
        confirmLabel: 'Save changes',
        initialHost: host,
      ),
    );

    if (!mounted || draft == null) {
      return;
    }

    setState(() {
      final hostIndex = _hosts.indexWhere(
        (candidate) => candidate.id == host.id,
      );
      if (hostIndex == -1) {
        return;
      }
      _hosts[hostIndex] = host.copyWith(
        name: draft.name,
        color: draft.color,
        connectCommand: draft.connectCommand,
      );
    });
  }

  void _moveHost(String hostId, int direction) {
    setState(() {
      final currentIndex = _hosts.indexWhere((host) => host.id == hostId);
      if (currentIndex == -1) {
        return;
      }

      final nextIndex = currentIndex + direction;
      if (nextIndex < 0 || nextIndex >= _hosts.length) {
        return;
      }

      final host = _hosts.removeAt(currentIndex);
      _hosts.insert(nextIndex, host);
    });
  }

  void _moveProject(String projectId, int direction) {
    setState(() {
      final currentIndex = _projects.indexWhere(
        (project) => project.id == projectId,
      );
      if (currentIndex == -1) {
        return;
      }

      final nextIndex = currentIndex + direction;
      if (nextIndex < 0 || nextIndex >= _projects.length) {
        return;
      }

      final project = _projects.removeAt(currentIndex);
      _projects.insert(nextIndex, project);
    });
  }

  Future<void> _unassignProjectFromHost(String hostId) async {
    setState(() {
      _deployments[hostId] = null;
    });
    await _persistIfLocked();
  }

  Future<void> _toggleDashboardLock() async {
    final isLockingDashboard = _hostManagementUnlocked;
    setState(() {
      _hostManagementUnlocked = !_hostManagementUnlocked;
    });
    if (isLockingDashboard) {
      await _persistCurrentState();
    }
  }

  Future<void> _exportDashboard() async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export VibeDash backup',
      fileName: 'vibedash-backup.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path == null) return;

    final document = VibeDashDocument.fromState(
      projects: _projects,
      hosts: _hosts,
      deployments: _deployments,
    );
    const encoder = JsonEncoder.withIndent('  ');
    final json = '${encoder.convert(document.toJson())}\n';

    try {
      await File(path).writeAsString(json);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Backup saved to $path'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on FileSystemException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save backup: ${error.message}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _importDashboard() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import VibeDash backup',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;

    try {
      final contents = await File(path).readAsString();
      final decoded = jsonDecode(contents);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Backup file must be a JSON object.');
      }
      final document = VibeDashDocument.fromJson(decoded);

      if (!mounted) return;
      final shouldReplace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Restore backup?'),
          content: const Text(
            'This will replace all current projects, hosts, and deployments. This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('confirm-restore-button'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );

      if (!mounted || shouldReplace != true) return;

      setState(() => _replaceDashboardState(document));
      await _persistCurrentState();
    } on FileSystemException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not read backup: ${error.message}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on FormatException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Invalid backup file: ${error.message}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _deleteHost(RemoteHost host) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete host'),
        content: Text(
          _deployments[host.id] == null
              ? 'Delete ${host.name}?'
              : 'Delete ${host.name} and unassign its deployed project?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (!mounted || shouldDelete != true) {
      return;
    }

    setState(() {
      _hosts.removeWhere((candidate) => candidate.id == host.id);
      _deployments.remove(host.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }

    final hostsById = {for (final host in _hosts) host.id: host};

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (_persistenceError != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                color: const Color(0xFF7F1D1D),
                child: Text(
                  _persistenceError!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.white),
                ),
              ),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 320,
                    child: ProjectPane(
                      projects: _projects,
                      hostsById: hostsById,
                      version: widget.version,
                      isUnlocked: _hostManagementUnlocked,
                      onAddProject: _addProject,
                      onDeleteProject: _deleteProject,
                      onEditProject: _editProject,
                      onMoveProjectBackward: (projectId) =>
                          _moveProject(projectId, -1),
                      onMoveProjectForward: (projectId) =>
                          _moveProject(projectId, 1),
                      hostForProject: _hostForProject,
                    ),
                  ),
                  const VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: Color(0xFF1A2233),
                  ),
                  Expanded(
                    child: HostGrid(
                      hosts: _hosts,
                      deployments: _deployments,
                      projectsById: _projectsById,
                      isUnlocked: _hostManagementUnlocked,
                      onToggleLock: _toggleDashboardLock,
                      onAddHost: _addHost,
                      onDeleteHost: _deleteHost,
                      onEditHost: _editHost,
                      onMoveHostBackward: (hostId) => _moveHost(hostId, -1),
                      onMoveHostForward: (hostId) => _moveHost(hostId, 1),
                      onProjectDropped: _deployProjectToHost,
                      onUnassignProject: _unassignProjectFromHost,
                      onExport: _exportDashboard,
                      onImport: _importDashboard,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ProjectPane extends StatefulWidget {
  const ProjectPane({
    super.key,
    required this.projects,
    required this.hostsById,
    required this.version,
    required this.isUnlocked,
    required this.onAddProject,
    required this.onDeleteProject,
    required this.onEditProject,
    required this.onMoveProjectBackward,
    required this.onMoveProjectForward,
    required this.hostForProject,
  });

  final List<VibeProject> projects;
  final Map<String, RemoteHost> hostsById;
  final String version;
  final bool isUnlocked;
  final VoidCallback onAddProject;
  final ValueChanged<VibeProject> onDeleteProject;
  final ValueChanged<VibeProject> onEditProject;
  final ValueChanged<String> onMoveProjectBackward;
  final ValueChanged<String> onMoveProjectForward;
  final String? Function(String projectId) hostForProject;

  @override
  State<ProjectPane> createState() => _ProjectPaneState();
}

class _ProjectPaneState extends State<ProjectPane> {
  String? _activeLabel;

  @override
  Widget build(BuildContext context) {
    final allLabels = widget.projects
        .map((p) => p.label)
        .where((l) => l.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    final effectiveLabel =
        _activeLabel != null && allLabels.contains(_activeLabel)
            ? _activeLabel
            : null;

    final filtered = effectiveLabel == null
        ? widget.projects
        : widget.projects.where((p) => p.label == effectiveLabel).toList();

    return ColoredBox(
      color: const Color(0xFF101826),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'VibeDash ${widget.version}',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Projects',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(
              widget.isUnlocked
                  ? 'Project management is unlocked. You can add, edit, delete, or arrange projects.'
                  : 'Drag a project onto a host card to assign its deployment.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white54),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('add-project-button'),
                onPressed: widget.isUnlocked ? widget.onAddProject : null,
                icon: const Icon(Icons.add),
                label: const Text('Add project'),
              ),
            ),
            if (allLabels.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  FilterChip(
                    label: const Text('All'),
                    selected: effectiveLabel == null,
                    onSelected: (_) => setState(() => _activeLabel = null),
                    visualDensity: VisualDensity.compact,
                  ),
                  for (final label in allLabels)
                    FilterChip(
                      label: Text(label),
                      selected: effectiveLabel == label,
                      onSelected: (_) => setState(() {
                        _activeLabel = effectiveLabel == label ? null : label;
                      }),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Expanded(
              child: ListView.separated(
                key: const Key('project-list-scroll-view'),
                itemCount: filtered.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final project = filtered[index];
                  final hostId = widget.hostForProject(project.id);
                  final host = hostId == null ? null : widget.hostsById[hostId];
                  final fullIndex = widget.projects.indexOf(project);
                  return ProjectTile(
                    project: project,
                    assignedHost: host,
                    isUnlocked: widget.isUnlocked,
                    canMoveBackward: effectiveLabel == null && fullIndex > 0,
                    canMoveForward:
                        effectiveLabel == null &&
                        fullIndex < widget.projects.length - 1,
                    onDelete: () => widget.onDeleteProject(project),
                    onEdit: () => widget.onEditProject(project),
                    onMoveBackward: () =>
                        widget.onMoveProjectBackward(project.id),
                    onMoveForward: () =>
                        widget.onMoveProjectForward(project.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ProjectTile extends StatelessWidget {
  const ProjectTile({
    super.key,
    required this.project,
    required this.assignedHost,
    required this.isUnlocked,
    required this.canMoveBackward,
    required this.canMoveForward,
    required this.onDelete,
    required this.onEdit,
    required this.onMoveBackward,
    required this.onMoveForward,
  });

  final VibeProject project;
  final RemoteHost? assignedHost;
  final bool isUnlocked;
  final bool canMoveBackward;
  final bool canMoveForward;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback onMoveBackward;
  final VoidCallback onMoveForward;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      key: Key('project-tile-${project.id}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF172235),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF243148)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 24,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            project.name,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          _GitHubLinkRow(
            linkKey: Key('project-link-${project.id}'),
            buttonKey: Key('open-project-link-${project.id}'),
            url: project.githubUrl,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              if (project.label.isNotEmpty)
                _ProjectBadge(
                  label: project.label,
                  color: const Color(0xFF2563EB),
                ),
              const Spacer(),
              _ProjectBadge(
                label: assignedHost == null ? 'Unassigned' : assignedHost!.name,
                color: assignedHost?.color ?? const Color(0xFF374151),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              IconButton.outlined(
                key: Key('edit-project-${project.id}'),
                onPressed: isUnlocked ? onEdit : null,
                tooltip: isUnlocked ? 'Edit project' : null,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton.outlined(
                key: Key('move-backward-project-${project.id}'),
                onPressed: isUnlocked && canMoveBackward
                    ? onMoveBackward
                    : null,
                tooltip: isUnlocked && canMoveBackward
                    ? 'Move project earlier'
                    : null,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton.outlined(
                key: Key('move-forward-project-${project.id}'),
                onPressed: isUnlocked && canMoveForward ? onMoveForward : null,
                tooltip: isUnlocked && canMoveForward
                    ? 'Move project later'
                    : null,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_downward),
              ),
              IconButton.outlined(
                key: Key('delete-project-${project.id}'),
                onPressed: isUnlocked ? onDelete : null,
                tooltip: isUnlocked ? 'Delete project' : null,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ],
      ),
    );

    return Draggable<String>(
      data: project.id,
      feedback: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Opacity(opacity: 0.95, child: card),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.45, child: card),
      child: card,
    );
  }
}

class HostGrid extends StatelessWidget {
  const HostGrid({
    super.key,
    required this.hosts,
    required this.deployments,
    required this.projectsById,
    required this.isUnlocked,
    required this.onToggleLock,
    required this.onAddHost,
    required this.onDeleteHost,
    required this.onEditHost,
    required this.onMoveHostBackward,
    required this.onMoveHostForward,
    required this.onProjectDropped,
    required this.onUnassignProject,
    required this.onExport,
    required this.onImport,
  });

  final List<RemoteHost> hosts;
  final Map<String, String?> deployments;
  final Map<String, VibeProject> projectsById;
  final bool isUnlocked;
  final Future<void> Function() onToggleLock;
  final VoidCallback onAddHost;
  final ValueChanged<RemoteHost> onDeleteHost;
  final ValueChanged<RemoteHost> onEditHost;
  final ValueChanged<String> onMoveHostBackward;
  final ValueChanged<String> onMoveHostForward;
  final Future<void> Function(String projectId, String hostId) onProjectDropped;
  final Future<void> Function(String hostId) onUnassignProject;
  final Future<void> Function() onExport;
  final Future<void> Function() onImport;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Remote Hosts',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      isUnlocked
                          ? 'Host management is unlocked. You can add, edit, arrange, or delete hosts.'
                          : 'Host management is locked. You can still assign or unassign projects.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyLarge?.copyWith(color: Colors.white60),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  if (isUnlocked) ...[
                    OutlinedButton.icon(
                      key: const Key('backup-button'),
                      onPressed: () async => onExport(),
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Backup'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('restore-button'),
                      onPressed: () async => onImport(),
                      icon: const Icon(Icons.download),
                      label: const Text('Restore'),
                    ),
                  ],
                  OutlinedButton.icon(
                    key: const Key('toggle-host-lock'),
                    onPressed: () async {
                      await onToggleLock();
                    },
                    icon: Icon(isUnlocked ? Icons.lock_open : Icons.lock),
                    label: Text(
                      isUnlocked ? 'Lock dashboard' : 'Unlock dashboard',
                    ),
                  ),
                  FilledButton.icon(
                    key: const Key('add-host-button'),
                    onPressed: isUnlocked ? onAddHost : null,
                    icon: const Icon(Icons.add),
                    label: const Text('Add host'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const spacing = 14.0;
                const minTileWidth = 280.0;
                const minTileHeight = 170.0;
                const maxTileHeight = 240.0;
                final maxColumnsByWidth = math.max(
                  1,
                  ((constraints.maxWidth + spacing) / (minTileWidth + spacing))
                      .floor(),
                );
                final candidateMaxColumns = math.min(
                  hosts.isEmpty ? 1 : hosts.length,
                  math.max(maxColumnsByWidth, 1),
                );
                var crossAxisCount = 1;
                for (
                  var columns = candidateMaxColumns;
                  columns >= 1;
                  columns--
                ) {
                  final rows = math.max(1, (hosts.length / columns).ceil());
                  final tileHeight =
                      (constraints.maxHeight - (spacing * (rows - 1))) / rows;
                  if (tileHeight >= minTileHeight || columns == 1) {
                    crossAxisCount = columns;
                    break;
                  }
                }
                final rows = math.max(
                  1,
                  (hosts.length / crossAxisCount).ceil(),
                );
                final tileHeight = math.max(
                  minTileHeight,
                  math.min(
                    maxTileHeight,
                    (constraints.maxHeight - (spacing * (rows - 1))) / rows,
                  ),
                );

                return GridView.builder(
                  key: const Key('host-grid-scroll-view'),
                  physics: rows <= 2
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: spacing,
                    mainAxisExtent: tileHeight,
                  ),
                  itemCount: hosts.length,
                  itemBuilder: (context, index) {
                    final host = hosts[index];
                    final assignedProjectId = deployments[host.id];
                    return HostCard(
                      host: host,
                      assignedProject: assignedProjectId == null
                          ? null
                          : projectsById[assignedProjectId],
                      isUnlocked: isUnlocked,
                      canMoveBackward: index > 0,
                      canMoveForward: index < hosts.length - 1,
                      onDelete: () => onDeleteHost(host),
                      onEdit: () => onEditHost(host),
                      onMoveBackward: () => onMoveHostBackward(host.id),
                      onMoveForward: () => onMoveHostForward(host.id),
                      onProjectDropped: (projectId) =>
                          onProjectDropped(projectId, host.id),
                      onUnassign: () => onUnassignProject(host.id),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class HostCard extends StatelessWidget {
  const HostCard({
    super.key,
    required this.host,
    required this.assignedProject,
    required this.isUnlocked,
    required this.canMoveBackward,
    required this.canMoveForward,
    required this.onDelete,
    required this.onEdit,
    required this.onMoveBackward,
    required this.onMoveForward,
    required this.onProjectDropped,
    required this.onUnassign,
  });

  final RemoteHost host;
  final VibeProject? assignedProject;
  final bool isUnlocked;
  final bool canMoveBackward;
  final bool canMoveForward;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback onMoveBackward;
  final VoidCallback onMoveForward;
  final Future<void> Function(String projectId) onProjectDropped;
  final Future<void> Function() onUnassign;

  Future<void> _connectToHost(BuildContext context) async {
    try {
      await launchTerminalWithCommand(host.connectCommand);
    } on ProcessException catch (error) {
      if (!context.mounted) return;
      final message = error.message.isEmpty ? error.toString() : error.message;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not connect to ${host.name}: $message'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    const actionSpacing = 8.0;
    final hasConnectCommand = host.connectCommand.trim().isNotEmpty;

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data.isNotEmpty,
      onAcceptWithDetails: (details) => onProjectDropped(details.data),
      builder: (context, candidateData, rejectedData) {
        final isActive = candidateData.isNotEmpty;
        return AnimatedContainer(
          key: Key('host-card-${host.id}'),
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              isActive
                  ? host.color.withValues(alpha: 0.18)
                  : host.color.withValues(alpha: 0.08),
              const Color(0xFF101826),
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isActive ? host.color : host.color.withValues(alpha: 0.65),
              width: isActive ? 2.2 : 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: host.color.withValues(alpha: isActive ? 0.18 : 0.08),
                blurRadius: 24,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: host.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        host.name,
                        key: Key('host-name-${host.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        assignedProject == null ? 'empty' : 'assigned',
                        key: Key('host-status-${host.id}'),
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    IconButton.outlined(
                      key: Key('connect-host-${host.id}'),
                      onPressed: hasConnectCommand
                          ? () => _connectToHost(context)
                          : null,
                      icon: const Icon(Icons.terminal, size: 20),
                      tooltip: hasConnectCommand ? 'Connect' : null,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: actionSpacing),
                    IconButton.outlined(
                      key: Key('edit-host-${host.id}'),
                      onPressed: isUnlocked ? onEdit : null,
                      tooltip: isUnlocked ? 'Edit host' : null,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.edit_outlined, size: 20),
                    ),
                    const SizedBox(width: actionSpacing),
                    IconButton.outlined(
                      key: Key('move-backward-${host.id}'),
                      onPressed: isUnlocked && canMoveBackward
                          ? onMoveBackward
                          : null,
                      tooltip: isUnlocked && canMoveBackward
                          ? 'Move host earlier'
                          : null,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.arrow_back, size: 20),
                    ),
                    const SizedBox(width: actionSpacing),
                    IconButton.outlined(
                      key: Key('move-forward-${host.id}'),
                      onPressed: isUnlocked && canMoveForward
                          ? onMoveForward
                          : null,
                      tooltip: isUnlocked && canMoveForward
                          ? 'Move host later'
                          : null,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.arrow_forward, size: 20),
                    ),
                    const SizedBox(width: actionSpacing),
                    IconButton.outlined(
                      key: Key('delete-host-${host.id}'),
                      onPressed: isUnlocked ? onDelete : null,
                      tooltip: isUnlocked ? 'Delete host' : null,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.delete_outline, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (assignedProject == null)
                  SizedBox(
                    height: 72,
                    child: Center(
                      child: Text(
                        isActive ? 'Drop to assign' : 'Drop a project here',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(color: Colors.white54),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                else
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          assignedProject!.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 2),
                        _GitHubLinkRow(
                          linkKey: Key('deployed-project-link-${host.id}'),
                          buttonKey: Key(
                            'open-deployed-project-link-${host.id}',
                          ),
                          url: assignedProject!.githubUrl,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.launch,
                              size: 14,
                              color: Colors.white.withValues(alpha: 0.45),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Deployed here',
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: Colors.white54),
                              ),
                            ),
                            IconButton(
                              key: Key('unassign-host-${host.id}'),
                              onPressed: () async {
                                await onUnassign();
                              },
                              tooltip: 'Unassign',
                              visualDensity: VisualDensity.compact,
                              iconSize: 18,
                              icon: const Icon(Icons.link_off),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class HostEditorDialog extends StatefulWidget {
  const HostEditorDialog({
    super.key,
    required this.title,
    required this.confirmLabel,
    this.initialHost,
  });

  final String title;
  final String confirmLabel;
  final RemoteHost? initialHost;

  @override
  State<HostEditorDialog> createState() => _HostEditorDialogState();
}

class _HostEditorDialogState extends State<HostEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _connectController;
  late Color _selectedColor;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.initialHost?.name ?? '',
    );
    _connectController = TextEditingController(
      text: widget.initialHost?.connectCommand ?? '',
    );
    _selectedColor = widget.initialHost?.color ?? hostColorChoices.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _connectController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    Navigator.of(context).pop(
      HostDraft(
        name: _nameController.text.trim(),
        color: _selectedColor,
        connectCommand: _connectController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                key: const Key('host-name-field'),
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Host name',
                  hintText: 'Hetzner Alpha',
                ),
                textInputAction: TextInputAction.next,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter a host name.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('host-connect-field'),
                controller: _connectController,
                decoration: const InputDecoration(
                  labelText: 'Connect command (optional)',
                  hintText: 'ssh root@example-host',
                ),
                minLines: 2,
                maxLines: 3,
              ),
              const SizedBox(height: 18),
              Text('Host color', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final color in hostColorChoices)
                    GestureDetector(
                      onTap: () => setState(() => _selectedColor = color),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: color == _selectedColor
                                ? Colors.white
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: color == _selectedColor
                            ? const Icon(Icons.check, size: 18)
                            : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('save-host-button'),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class ProjectEditorDialog extends StatefulWidget {
  const ProjectEditorDialog({
    super.key,
    required this.title,
    required this.confirmLabel,
    this.initialProject,
  });

  final String title;
  final String confirmLabel;
  final VibeProject? initialProject;

  @override
  State<ProjectEditorDialog> createState() => _ProjectEditorDialogState();
}

class _ProjectEditorDialogState extends State<ProjectEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _githubUrlController;
  late final TextEditingController _labelController;
  String _labelPreview = '';

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.initialProject?.name ?? '',
    );
    _githubUrlController = TextEditingController(
      text: widget.initialProject?.githubUrl ?? '',
    );
    _labelController = TextEditingController(
      text: widget.initialProject?.label ?? '',
    );
    _labelPreview = slugifyLabel(_labelController.text);
    _labelController.addListener(() {
      setState(() {
        _labelPreview = slugifyLabel(_labelController.text);
      });
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _githubUrlController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    Navigator.of(context).pop(
      ProjectDraft(
        name: _nameController.text.trim(),
        githubUrl: _githubUrlController.text.trim(),
        label: _labelPreview,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                key: const Key('project-name-field'),
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Project name',
                  hintText: 'PromptForge',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter a project name.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('project-github-field'),
                controller: _githubUrlController,
                decoration: const InputDecoration(
                  labelText: 'GitHub URL',
                  hintText: 'https://github.com/mafudge/project-name',
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter a GitHub URL.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('project-label-field'),
                controller: _labelController,
                decoration: const InputDecoration(
                  labelText: 'Label (optional)',
                  hintText: 'work, for mom, client-x',
                ),
              ),
              if (_labelPreview.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Stored as: $_labelPreview',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white54,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('save-project-button'),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _ProjectBadge extends StatelessWidget {
  const _ProjectBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _GitHubLinkRow extends StatelessWidget {
  const _GitHubLinkRow({
    required this.linkKey,
    required this.buttonKey,
    required this.url,
  });

  final Key linkKey;
  final Key buttonKey;
  final String url;

  @override
  Widget build(BuildContext context) {
    final linkStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: const Color(0xFF93C5FD),
      decoration: TextDecoration.underline,
      decorationColor: const Color(0xFF93C5FD),
    );

    return Row(
      children: [
        Expanded(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: linkKey,
              onTap: () => openExternalUrl(context, url),
              child: Text(
                url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: linkStyle,
              ),
            ),
          ),
        ),
        IconButton(
          key: buttonKey,
          onPressed: () => openExternalUrl(context, url),
          tooltip: 'Open GitHub repository',
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          icon: const Icon(Icons.open_in_new),
        ),
      ],
    );
  }
}

class HostDraft {
  const HostDraft({
    required this.name,
    required this.color,
    required this.connectCommand,
  });

  final String name;
  final Color color;
  final String connectCommand;
}

class ProjectDraft {
  const ProjectDraft({required this.name, required this.githubUrl, required this.label});

  final String name;
  final String githubUrl;
  final String label;
}

class VibeProject {
  const VibeProject({
    required this.id,
    required this.name,
    required this.githubUrl,
    this.label = '',
  });

  final String id;
  final String name;
  final String githubUrl;
  final String label;

  factory VibeProject.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final githubUrl = json['githubUrl'];
    if (id is! String || name is! String || githubUrl is! String) {
      throw const FormatException(
        'Each project must include id, name, and githubUrl strings.',
      );
    }
    final label = json['label'];
    return VibeProject(
      id: id,
      name: name,
      githubUrl: githubUrl,
      label: label is String ? label : '',
    );
  }

  VibeProject copyWith({String? name, String? githubUrl, String? label}) {
    return VibeProject(
      id: id,
      name: name ?? this.name,
      githubUrl: githubUrl ?? this.githubUrl,
      label: label ?? this.label,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'githubUrl': githubUrl,
    'label': label,
  };
}

class RemoteHost {
  const RemoteHost({
    required this.id,
    required this.name,
    required this.color,
    required this.connectCommand,
  });

  final String id;
  final String name;
  final Color color;
  final String connectCommand;

  factory RemoteHost.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final colorValue = json['color'];
    final connectCommand = json['connectCommand'];
    if (id is! String ||
        name is! String ||
        colorValue is! int ||
        connectCommand is! String) {
      throw const FormatException(
        'Each host must include id, name, color, and connectCommand values.',
      );
    }
    return RemoteHost(
      id: id,
      name: name,
      color: Color(colorValue),
      connectCommand: connectCommand,
    );
  }

  RemoteHost copyWith({String? name, Color? color, String? connectCommand}) {
    return RemoteHost(
      id: id,
      name: name ?? this.name,
      color: color ?? this.color,
      connectCommand: connectCommand ?? this.connectCommand,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'color': color.toARGB32(),
    'connectCommand': connectCommand,
  };
}

class ProjectAssignment {
  const ProjectAssignment({required this.hostId, required this.projectId});

  final String hostId;
  final String projectId;

  factory ProjectAssignment.fromJson(Map<String, dynamic> json) {
    final hostId = json['hostId'];
    final projectId = json['projectId'];
    if (hostId is! String || projectId is! String) {
      throw const FormatException(
        'Each assignment must include hostId and projectId strings.',
      );
    }
    return ProjectAssignment(hostId: hostId, projectId: projectId);
  }

  Map<String, dynamic> toJson() => {'hostId': hostId, 'projectId': projectId};
}

class VibeDashDocument {
  const VibeDashDocument({
    required this.hosts,
    required this.projects,
    required this.assignments,
  });

  final List<RemoteHost> hosts;
  final List<VibeProject> projects;
  final List<ProjectAssignment> assignments;

  factory VibeDashDocument.seeded() {
    return VibeDashDocument(
      hosts: seedHosts(),
      projects: seedProjects(),
      assignments: seedAssignments(),
    );
  }

  factory VibeDashDocument.fromJson(Map<String, dynamic> json) {
    final hosts = _readObjectList(
      json,
      key: 'hosts',
    ).map(RemoteHost.fromJson).toList(growable: false);
    final projects = _readObjectList(
      json,
      key: 'projects',
    ).map(VibeProject.fromJson).toList(growable: false);
    final assignments = _readObjectList(
      json,
      key: 'assignments',
    ).map(ProjectAssignment.fromJson).toList(growable: false);
    return VibeDashDocument(
      hosts: hosts,
      projects: projects,
      assignments: assignments,
    ).normalized();
  }

  factory VibeDashDocument.fromState({
    required List<RemoteHost> hosts,
    required List<VibeProject> projects,
    required Map<String, String?> deployments,
  }) {
    return VibeDashDocument(
      hosts: List<RemoteHost>.of(hosts, growable: false),
      projects: List<VibeProject>.of(projects, growable: false),
      assignments: [
        for (final host in hosts)
          if (deployments[host.id] case final String projectId)
            ProjectAssignment(hostId: host.id, projectId: projectId),
      ],
    );
  }

  VibeDashDocument normalized() {
    final seenHostIds = <String>{};
    final dedupedHosts = <RemoteHost>[
      for (final host in hosts)
        if (seenHostIds.add(host.id)) host,
    ];

    final seenProjectIds = <String>{};
    final dedupedProjects = <VibeProject>[
      for (final project in projects)
        if (seenProjectIds.add(project.id)) project,
    ];

    final validHostIds = dedupedHosts.map((host) => host.id).toSet();
    final validProjectIds = dedupedProjects
        .map((project) => project.id)
        .toSet();
    final assignedHosts = <String>{};
    final assignedProjects = <String>{};
    final normalizedAssignments = <ProjectAssignment>[
      for (final assignment in assignments)
        if (validHostIds.contains(assignment.hostId) &&
            validProjectIds.contains(assignment.projectId) &&
            assignedHosts.add(assignment.hostId) &&
            assignedProjects.add(assignment.projectId))
          assignment,
    ];

    return VibeDashDocument(
      hosts: dedupedHosts,
      projects: dedupedProjects,
      assignments: normalizedAssignments,
    );
  }

  Map<String, String?> toDeploymentMap() {
    final deployments = {for (final host in hosts) host.id: null as String?};
    for (final assignment in assignments) {
      deployments[assignment.hostId] = assignment.projectId;
    }
    return deployments;
  }

  Map<String, dynamic> toJson() => {
    'hosts': [for (final host in hosts) host.toJson()],
    'projects': [for (final project in projects) project.toJson()],
    'assignments': [for (final assignment in assignments) assignment.toJson()],
  };
}

abstract interface class VibeDashStorage {
  Future<VibeDashDocument?> readState();
  Future<void> writeState(VibeDashDocument document);
}

class FileVibeDashStorage implements VibeDashStorage {
  const FileVibeDashStorage({this.fileProvider});

  final Future<File> Function()? fileProvider;

  Future<File> _resolveFile() async {
    if (fileProvider != null) {
      return fileProvider!();
    }
    final directory = dashboardStateDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}vibedash-state.json',
    );
  }

  @override
  Future<VibeDashDocument?> readState() async {
    final file = await _resolveFile();
    if (!await file.exists()) {
      return null;
    }

    final contents = await file.readAsString();
    final decoded = jsonDecode(contents);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Dashboard state must be a JSON object.');
    }
    return VibeDashDocument.fromJson(decoded);
  }

  @override
  Future<void> writeState(VibeDashDocument document) async {
    final file = await _resolveFile();
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString('${encoder.convert(document.toJson())}\n');
  }
}

List<Map<String, dynamic>> _readObjectList(
  Map<String, dynamic> json, {
  required String key,
}) {
  final value = json[key];
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw FormatException('Expected "$key" to be a JSON array.');
  }
  return [
    for (final entry in value)
      if (entry is Map)
        Map<String, dynamic>.from(entry)
      else
        throw FormatException('Expected each "$key" entry to be an object.'),
  ];
}

String _describeFileSystemError(
  FileSystemException error, {
  required String action,
}) {
  final message = error.message.isEmpty ? error.toString() : error.message;
  return 'Could not $action dashboard state: $message';
}

Future<void> launchTerminalWithCommand(String command) async {
  if (command.trim().isEmpty) return;

  if (Platform.isWindows) {
    if (await _isWindowsGuiApp(command)) {
      // GUI app: it creates its own window — launch directly, no terminal needed.
      final (exe, args) = _parseWindowsCommand(command);
      await Process.start(exe, args, mode: ProcessStartMode.detached);
    } else {
      // Console/interactive command: open a terminal window.
      // Prefer PowerShell Core (pwsh) over Windows PowerShell 5 (powershell).
      // cmd /c start opens a new visible window; PowerShell handles paths with
      // spaces via the & call operator (cmd /k strips outer quotes and breaks them).
      final ps = whichSync('pwsh') != null ? 'pwsh' : 'powershell';
      await Process.start(
        'cmd',
        ['/c', 'start', ps, '-NoExit', '-Command', _toWindowsShellCommand(command)],
        mode: ProcessStartMode.detached,
      );
    }
  } else if (Platform.isMacOS) {
    final escaped = command.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    await Process.start(
      'osascript',
      ['-e', 'tell application "Terminal" to do script "$escaped"'],
      mode: ProcessStartMode.detached,
    );
  } else {
    // WSL: no Linux terminal emulator is typically installed — open a
    // Windows-side terminal instead.
    if (_isWsl()) {
      await _launchWslTerminal(command);
      return;
    }

    // Native Linux: use whichSync to find the first available terminal.
    const candidates = [
      'x-terminal-emulator',
      'gnome-terminal',
      'konsole',
      'xfce4-terminal',
      'lxterminal',
      'mate-terminal',
      'xterm',
    ];
    final terminal = candidates.where((t) => whichSync(t) != null).firstOrNull;
    if (terminal == null) {
      throw ProcessException(
        'No terminal emulator found. Install one with: sudo apt install xterm',
        [],
      );
    }
    final args = switch (terminal) {
      'gnome-terminal' => ['--', 'bash', '-c', command],
      'konsole' || 'xfce4-terminal' => ['-e', 'bash -c ${shellArgument(command)}'],
      _ => ['-e', command],
    };
    await Process.start(terminal, args, mode: ProcessStartMode.detached);
  }
}

bool _isWsl() {
  try {
    return File('/proc/version')
        .readAsStringSync()
        .toLowerCase()
        .contains('microsoft');
  } catch (_) {
    return false;
  }
}

Future<void> _launchWslTerminal(String command) async {
  // Prefer Windows Terminal (wt.exe); fall back to a plain cmd window.
  if (whichSync('wt.exe') != null) {
    await Process.start(
      'wt.exe',
      ['bash', '-c', command],
      mode: ProcessStartMode.detached,
    );
  } else {
    final escaped = command.replaceAll('"', '\\"');
    await Process.start(
      'cmd.exe',
      ['/c', 'start', 'cmd', '/k', 'bash -c "$escaped"'],
      mode: ProcessStartMode.detached,
    );
  }
}

// Reads the Windows PE header to check whether the executable is a GUI app
// (IMAGE_SUBSYSTEM_WINDOWS_GUI == 2). GUI apps create their own window so
// we can launch them directly without opening a terminal.
Future<bool> _isWindowsGuiApp(String command) async {
  final (exe, _) = _parseWindowsCommand(command);
  final exePath = RegExp(r'^[A-Za-z]:\\').hasMatch(exe) ? exe : whichSync(exe);
  if (exePath == null) return false;
  try {
    final raf = await File(exePath).open();
    try {
      // Read enough bytes to cover the PE optional header (usually < 512 bytes in).
      final bytes = (await raf.read(4096)).buffer.asByteData();
      if (bytes.lengthInBytes < 0x40) return false;
      final peOffset = bytes.getUint32(0x3C, Endian.little);
      final end = peOffset + 4 + 20 + 70; // sig + COFF header + subsystem field
      if (end > bytes.lengthInBytes) return false;
      // Verify 'PE\0\0' signature.
      if (bytes.getUint32(peOffset, Endian.little) != 0x00004550) return false;
      // Subsystem: offset 68 into the optional header (after 4-byte sig + 20-byte COFF).
      final subsystem = bytes.getUint16(peOffset + 24 + 68, Endian.little);
      return subsystem == 2; // IMAGE_SUBSYSTEM_WINDOWS_GUI
    } finally {
      await raf.close();
    }
  } catch (_) {
    return false;
  }
}

// Splits a raw command string into (executable, arguments).
// Strips any surrounding quotes from the executable path.
(String, List<String>) _parseWindowsCommand(String command) {
  final trimmed = command.trim();
  // Quoted executable: "C:\Program Files\foo.exe" arg1 arg2
  final quoted = RegExp(r'^"([^"]+)"(?:\s+(.*))?$').firstMatch(trimmed);
  if (quoted != null) {
    final exe = quoted.group(1)!;
    final rest = quoted.group(2)?.trim() ?? '';
    return (exe, rest.isEmpty ? [] : rest.split(RegExp(r'\s+')));
  }
  // Unquoted: detect exe boundary by extension then whitespace.
  final unquoted =
      RegExp(r'^(.+?\.[a-zA-Z0-9]{1,4})(?:\s+(.*))?$').firstMatch(trimmed);
  if (unquoted != null) {
    final exe = unquoted.group(1)!;
    final rest = unquoted.group(2)?.trim() ?? '';
    return (exe, rest.isEmpty ? [] : rest.split(RegExp(r'\s+')));
  }
  final parts = trimmed.split(RegExp(r'\s+'));
  return (parts.first, parts.skip(1).toList());
}

// Converts a raw connect command into a form PowerShell can execute.
// Unquoted Windows absolute paths with spaces are wrapped with the & call
// operator so PowerShell does not mistake the space as an argument boundary.
// shellArgument (process_run) handles cross-platform quoting.
String _toWindowsShellCommand(String command) {
  final trimmed = command.trim();
  if (trimmed.startsWith('"') ||
      trimmed.startsWith("'") ||
      !trimmed.contains(' ') ||
      !RegExp(r'^[A-Za-z]:\\').hasMatch(trimmed)) {
    return trimmed;
  }

  // Split at the first file-extension boundary to separate exe from args.
  final match =
      RegExp(r'^(.+?\.[a-zA-Z0-9]{1,4})(?:\s+(.*))?$').firstMatch(trimmed);
  if (match != null) {
    final exe = shellArgument(match.group(1)!);
    final args = match.group(2)?.trim() ?? '';
    return args.isEmpty ? '& $exe' : '& $exe $args';
  }

  return '& ${shellArgument(trimmed)}';
}

Future<void> openExternalUrl(BuildContext context, String url) async {
  final parsedUrl = Uri.tryParse(url);
  if (parsedUrl == null ||
      !parsedUrl.hasScheme ||
      (parsedUrl.scheme != 'http' && parsedUrl.scheme != 'https')) {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('This GitHub URL is not valid.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    return;
  }

  final command = switch (Platform.operatingSystem) {
    'macos' => ('open', <String>[url]),
    'windows' => ('cmd', <String>['/c', 'start', '', url]),
    _ => ('xdg-open', <String>[url]),
  };

  try {
    await Process.start(
      command.$1,
      command.$2,
      mode: ProcessStartMode.detached,
      runInShell: Platform.isWindows,
    );
  } on ProcessException catch (error) {
    if (!context.mounted) {
      return;
    }
    final message = error.message.isEmpty ? error.toString() : error.message;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not open GitHub link: $message'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

String slugifyLabel(String label) {
  return label
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}

int nextIdNumber({required Iterable<String> ids, required String prefix}) {
  final pattern = RegExp('^${RegExp.escape(prefix)}(\\d+)\$');
  var highestNumber = 0;
  for (final id in ids) {
    final match = pattern.firstMatch(id);
    if (match == null) {
      continue;
    }
    final value = int.tryParse(match.group(1)!);
    if (value != null && value > highestNumber) {
      highestNumber = value;
    }
  }
  return highestNumber + 1;
}

List<VibeProject> seedProjects() => const [
  VibeProject(
    id: 'p1',
    name: 'VibeDash',
    githubUrl: 'https://github.com/mafudge/vibedash',
    label: 'personal',
  ),
  VibeProject(
    id: 'p2',
    name: 'PromptForge',
    githubUrl: 'https://github.com/mafudge/promptforge',
    label: 'work',
  ),
  VibeProject(
    id: 'p3',
    name: 'GhostWriter API',
    githubUrl: 'https://github.com/mafudge/ghostwriter-api',
    label: 'work',
  ),
  VibeProject(
    id: 'p4',
    name: 'Campus Concierge',
    githubUrl: 'https://github.com/mafudge/campus-concierge',
    label: 'school',
  ),
  VibeProject(
    id: 'p5',
    name: 'Syllabus Synth',
    githubUrl: 'https://github.com/mafudge/syllabus-synth',
    label: 'school',
  ),
];

List<RemoteHost> seedHosts() => const [
  RemoteHost(
    id: 'h1',
    name: 'Hetzner Alpha',
    color: Color(0xFF1D4ED8),
    connectCommand: 'ssh root@alpha.vibedash.dev',
  ),
  RemoteHost(
    id: 'h2',
    name: 'DO Builder',
    color: Color(0xFF7C3AED),
    connectCommand: 'ssh deploy@builder.vibedash.dev',
  ),
  RemoteHost(
    id: 'h3',
    name: 'Fly Edge',
    color: Color(0xFF0F766E),
    connectCommand: 'fly ssh console -a vibe-edge',
  ),
  RemoteHost(
    id: 'h4',
    name: 'Home Lab',
    color: Color(0xFFB45309),
    connectCommand: 'ssh mafudge@homelab.local',
  ),
];

List<ProjectAssignment> seedAssignments() => const [
  ProjectAssignment(hostId: 'h1', projectId: 'p1'),
  ProjectAssignment(hostId: 'h2', projectId: 'p3'),
  ProjectAssignment(hostId: 'h4', projectId: 'p4'),
];

Map<String, String?> seedDeployments() =>
    VibeDashDocument.seeded().toDeploymentMap();

Directory dashboardStateDirectory() {
  final separator = Platform.pathSeparator;
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    final userProfile = Platform.environment['USERPROFILE'];
    final basePath = appData ?? userProfile;
    if (basePath != null && basePath.isNotEmpty) {
      return Directory('$basePath${separator}VibeDash');
    }
  }

  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory(
        '$home${separator}Library${separator}Application Support${separator}VibeDash',
      );
    }
  }

  final xdgConfigHome = Platform.environment['XDG_CONFIG_HOME'];
  if (xdgConfigHome != null && xdgConfigHome.isNotEmpty) {
    return Directory('$xdgConfigHome${separator}vibedash');
  }

  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    return Directory('$home$separator.config${separator}vibedash');
  }

  return Directory('${Directory.current.path}$separator.vibedash');
}
