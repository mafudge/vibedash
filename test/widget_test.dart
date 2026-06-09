import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibedash/main.dart';

class MemoryVibeDashStorage implements VibeDashStorage {
  MemoryVibeDashStorage({VibeDashDocument? initialState})
    : _state = initialState;

  VibeDashDocument? _state;
  int writeCount = 0;

  VibeDashDocument? get state => _state;

  @override
  Future<VibeDashDocument?> readState() async => _state;

  @override
  Future<void> writeState(VibeDashDocument document) async {
    writeCount += 1;
    _state = VibeDashDocument.fromJson(document.toJson());
  }
}

Future<void> pumpDesktopApp(
  WidgetTester tester, {
  VibeDashStorage? storage,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MyApp(
      storage:
          storage ??
          MemoryVibeDashStorage(initialState: VibeDashDocument.seeded()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> dragProjectToHost(
  WidgetTester tester, {
  required String projectId,
  required String hostId,
}) async {
  final start = tester.getCenter(find.byKey(Key('project-tile-$projectId')));
  final end = tester.getCenter(find.byKey(Key('host-card-$hostId')));
  final gesture = await tester.startGesture(start);
  await gesture.moveTo(end);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('starts locked with host management disabled', (
    WidgetTester tester,
  ) async {
    await pumpDesktopApp(tester);

    expect(find.text('Remote Hosts'), findsOneWidget);
    expect(find.text('Host management is locked.'), findsNothing);
    expect(find.byKey(const Key('toggle-host-lock')), findsOneWidget);

    final addButton = tester.widget<FilledButton>(
      find.byKey(const Key('add-host-button')),
    );
    final addProjectButton = tester.widget<FilledButton>(
      find.byKey(const Key('add-project-button')),
    );
    final editButton = tester.widget<IconButton>(
      find.byKey(const Key('edit-host-h1')),
    );
    final deleteButton = tester.widget<IconButton>(
      find.byKey(const Key('delete-host-h1')),
    );
    final editProjectButton = tester.widget<IconButton>(
      find.byKey(const Key('edit-project-p1')),
    );
    final deleteProjectButton = tester.widget<IconButton>(
      find.byKey(const Key('delete-project-p1')),
    );
    final moveProjectDownButton = tester.widget<IconButton>(
      find.byKey(const Key('move-forward-project-p1')),
    );

    expect(addButton.onPressed, isNull);
    expect(addProjectButton.onPressed, isNull);
    expect(editButton.onPressed, isNull);
    expect(deleteButton.onPressed, isNull);
    expect(editProjectButton.onPressed, isNull);
    expect(deleteProjectButton.onPressed, isNull);
    expect(moveProjectDownButton.onPressed, isNull);
  });

  testWidgets('host cards stay compact with larger action buttons', (
    WidgetTester tester,
  ) async {
    await pumpDesktopApp(tester);

    final connectButton = tester.widget<IconButton>(
      find.byKey(const Key('connect-host-h1')),
    );
    expect(connectButton.visualDensity, VisualDensity.compact);

    final hostCardSize = tester.getSize(find.byKey(const Key('host-card-h1')));
    expect(hostCardSize.height, lessThanOrEqualTo(240));
  });

  testWidgets('locked mode still allows unassigning a project', (
    WidgetTester tester,
  ) async {
    await pumpDesktopApp(tester);

    expect(find.text('VibeDash'), findsWidgets);

    await tester.tap(find.byKey(const Key('unassign-host-h1')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('host-card-h1')),
        matching: find.byKey(const Key('host-status-h1')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('host-card-h1')),
        matching: find.text('Drop a project here'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('dragging to an empty host deploys immediately', (
    WidgetTester tester,
  ) async {
    await pumpDesktopApp(tester);

    await dragProjectToHost(tester, projectId: 'p2', hostId: 'h3');

    expect(
      find.descendant(
        of: find.byKey(const Key('host-card-h3')),
        matching: find.text('PromptForge'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('dragging to an occupied host asks before redeploying', (
    WidgetTester tester,
  ) async {
    await pumpDesktopApp(tester);

    await dragProjectToHost(tester, projectId: 'p2', hostId: 'h2');

    expect(find.text('Replace deployment?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('host-card-h2')),
        matching: find.text('GhostWriter API'),
      ),
      findsOneWidget,
    );

    await dragProjectToHost(tester, projectId: 'p2', hostId: 'h2');

    expect(find.text('Replace deployment?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-redeploy-button')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('host-card-h2')),
        matching: find.text('PromptForge'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('dragging an already deployed project asks before moving hosts', (
    WidgetTester tester,
  ) async {
    await pumpDesktopApp(tester);

    await dragProjectToHost(tester, projectId: 'p1', hostId: 'h3');

    expect(find.text('Move deployment?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('host-card-h1')),
        matching: find.text('VibeDash'),
      ),
      findsOneWidget,
    );

    await dragProjectToHost(tester, projectId: 'p1', hostId: 'h3');

    expect(find.text('Move deployment?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-move-button')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('host-card-h3')),
        matching: find.text('VibeDash'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('unlocking enables add and edit host flows', (
    WidgetTester tester,
  ) async {
    await pumpDesktopApp(tester);

    await tester.tap(find.byKey(const Key('toggle-host-lock')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-host-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('host-name-field')),
      'Railway Node',
    );
    await tester.tap(find.byKey(const Key('save-host-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('edit-host-h1')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('host-name-field')),
      'Hetzner Prime',
    );
    await tester.enterText(
      find.byKey(const Key('host-connect-field')),
      'ssh root@prime.vibedash.dev',
    );
    await tester.tap(find.byKey(const Key('save-host-button')));
    await tester.pumpAndSettle();

    expect(find.text('Hetzner Prime'), findsWidgets);

    final hostGridScrollable = find
        .descendant(
          of: find.byKey(const Key('host-grid-scroll-view')),
          matching: find.byType(Scrollable),
        )
        .first;

    await tester.scrollUntilVisible(
      find.byKey(const Key('host-name-h5')),
      300,
      scrollable: hostGridScrollable,
    );
    await tester.pumpAndSettle();

    expect(find.text('Railway Node'), findsWidgets);
    final connectButton = tester.widget<IconButton>(
      find.byKey(const Key('connect-host-h5')),
    );
    expect(connectButton.onPressed, isNull);
  });

  testWidgets('unlocking enables add edit and delete project flows', (
    WidgetTester tester,
  ) async {
    await pumpDesktopApp(tester);

    await tester.tap(find.byKey(const Key('toggle-host-lock')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-project-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('project-name-field')),
      'Agent Atlas',
    );
    await tester.enterText(
      find.byKey(const Key('project-github-field')),
      'https://github.com/mafudge/agent-atlas',
    );
    await tester.tap(find.byKey(const Key('save-project-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('edit-project-p6')), findsOneWidget);
    expect(find.text('Agent Atlas'), findsOneWidget);

    await tester.tap(find.byKey(const Key('edit-project-p1')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('project-name-field')),
      'VibeDash Prime',
    );
    await tester.enterText(
      find.byKey(const Key('project-github-field')),
      'https://github.com/mafudge/vibedash-prime',
    );
    await tester.tap(find.byKey(const Key('save-project-button')));
    await tester.pumpAndSettle();

    expect(find.text('VibeDash Prime'), findsWidgets);

    await tester.tap(find.byKey(const Key('delete-project-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-project')));
    await tester.pumpAndSettle();

    expect(find.text('VibeDash Prime'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('host-card-h1')),
        matching: find.text('Drop a project here'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('project cards expose clickable GitHub actions', (
    WidgetTester tester,
  ) async {
    await pumpDesktopApp(tester);

    expect(find.byKey(const Key('project-link-p1')), findsOneWidget);
    expect(find.byKey(const Key('open-project-link-p1')), findsOneWidget);
    expect(
      find.byKey(const Key('open-deployed-project-link-h1')),
      findsOneWidget,
    );
  });

  testWidgets('unlocking enables rearranging projects', (
    WidgetTester tester,
  ) async {
    await pumpDesktopApp(tester);

    await tester.tap(find.byKey(const Key('toggle-host-lock')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('move-forward-project-p1')));
    await tester.pumpAndSettle();

    final vibeDashPosition = tester.getTopLeft(
      find.byKey(const Key('project-tile-p1')),
    );
    final promptForgePosition = tester.getTopLeft(
      find.byKey(const Key('project-tile-p2')),
    );

    expect(promptForgePosition.dy, lessThan(vibeDashPosition.dy));

    final moveBackwardButton = tester.widget<IconButton>(
      find.byKey(const Key('move-backward-project-p1')),
    );
    expect(moveBackwardButton.onPressed, isNotNull);
  });

  testWidgets('unlocking enables rearrange and delete', (
    WidgetTester tester,
  ) async {
    await pumpDesktopApp(tester);

    await tester.tap(find.byKey(const Key('toggle-host-lock')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('move-forward-h1')));
    await tester.pumpAndSettle();

    final backwardAfter = tester.widget<IconButton>(
      find.byKey(const Key('move-backward-h1')),
    );
    expect(backwardAfter.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('delete-host-h4')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Home Lab'), findsNothing);
  });

  testWidgets('loads persisted dashboard state from JSON storage', (
    WidgetTester tester,
  ) async {
    final storage = MemoryVibeDashStorage(
      initialState: const VibeDashDocument(
        hosts: [
          RemoteHost(
            id: 'h10',
            name: 'Railway Blue',
            color: Color(0xFF0891B2),
            connectCommand: '',
          ),
        ],
        projects: [
          VibeProject(
            id: 'p10',
            name: 'Agent Atlas',
            githubUrl: 'https://github.com/mafudge/agent-atlas',
          ),
        ],
        assignments: [ProjectAssignment(hostId: 'h10', projectId: 'p10')],
      ),
    );

    await pumpDesktopApp(tester, storage: storage);

    expect(find.byKey(const Key('host-name-h10')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('host-card-h10')),
        matching: find.text('Agent Atlas'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('locking saves unlocked edits to JSON storage', (
    WidgetTester tester,
  ) async {
    final storage = MemoryVibeDashStorage(
      initialState: VibeDashDocument.seeded(),
    );

    await pumpDesktopApp(tester, storage: storage);

    await tester.tap(find.byKey(const Key('toggle-host-lock')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-host-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('host-name-field')),
      'Railway Node',
    );
    await tester.tap(find.byKey(const Key('save-host-button')));
    await tester.pumpAndSettle();

    expect(storage.writeCount, 0);

    await tester.tap(find.byKey(const Key('toggle-host-lock')));
    await tester.pumpAndSettle();

    expect(storage.writeCount, 1);
    expect(
      storage.state!.hosts.any((host) => host.name == 'Railway Node'),
      isTrue,
    );
  });

  testWidgets('locked assignment changes autosave to JSON storage', (
    WidgetTester tester,
  ) async {
    final storage = MemoryVibeDashStorage(
      initialState: VibeDashDocument.seeded(),
    );

    await pumpDesktopApp(tester, storage: storage);

    await dragProjectToHost(tester, projectId: 'p2', hostId: 'h3');

    expect(storage.writeCount, 1);
    expect(
      storage.state!.assignments.any(
        (assignment) =>
            assignment.hostId == 'h3' && assignment.projectId == 'p2',
      ),
      isTrue,
    );
  });
}
