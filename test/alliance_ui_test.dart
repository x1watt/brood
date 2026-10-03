// Widget checks for the alliance screen and invitation cards, with a
// controller filled in by hand (no engine): an invitation from Computer 1,
// an existing alliance of Computers 2 and 3, scores for everyone.

import 'package:brood/engine/models.dart';
import 'package:brood/game/game_controller.dart';
import 'package:brood/ui/alliance_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AlliancePlayer _p(int slot, {required int group, int invitedBy = 0, bool open = true, int mined = 0, int built = 0, int killed = 0, int name = -1, int fighting = 0, int surrenderFrom = 0}) => AlliancePlayer(
  slot: slot,
  playing: slot < 4,
  active: slot < 4,
  group: group,
  open: open,
  invitedBy: invitedBy,
  color: slot,
  race: slot % 3,
  mineralsMined: mined,
  gasMined: 0,
  points: mined,
  ownPoints: mined,
  productionScore: built,
  killScore: killed,
  unitsKilled: killed ~/ 100,
  buildingsRazed: 0,
  unitsLost: 3,
  name: name,
  fighting: fighting,
  surrenderFrom: surrenderFrom,
  armyValue: 1000 + slot * 250,
  workers: 12,
  mineralRate: 600,
  gasRate: 150,
);

GameController _controller() {
  final c = GameController();
  c.myPlayer = 0;
  c.players = const [
    GamePlayer(slot: 0, race: 1, team: 0, human: true, name: 'You'),
    GamePlayer(slot: 1, race: 2, team: 0, human: false, name: 'Computer 1'),
    GamePlayer(slot: 2, race: 0, team: 0, human: false, name: 'Computer 2'),
    GamePlayer(slot: 3, race: 1, team: 0, human: false, name: 'Computer 3'),
  ];
  c.alliance = [
    _p(0, group: 0, invitedBy: 1 << 1, mined: 1200, built: 900),
    _p(1, group: 1, mined: 800, built: 1500, killed: 400),
    _p(2, group: 2, mined: 2600, built: 2100, killed: 1200, name: 1, fighting: 1 << 1),
    _p(3, group: 2, mined: 2600, built: 1800, name: 1),
    for (int s = 4; s < 8; ++s) _p(s, group: s),
  ];
  return c;
}

Future<void> _pump(WidgetTester tester, Widget child, {double height = 900}) async {
  tester.view.physicalSize = Size(1440, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child)));
}

void main() {
  testWidgets('invitation card names the inviter and offers Accept and Decline', (tester) async {
    final c = _controller();
    await _pump(tester, Center(child: InvitationCards(c: c)));
    expect(find.textContaining('Computer 1'), findsOneWidget);
    expect(find.textContaining('invites you to an alliance', findRichText: true), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('alliance panel shows scores, groups and the right actions', (tester) async {
    final c = _controller();
    await _pump(
      tester,
      Align(alignment: Alignment.centerRight, child: SizedBox(height: 2400, child: AlliancePanel(c: c, onClose: () {}, onToggleSide: () {}))),
      height: 2400,
    );
    expect(tester.takeException(), isNull);
    // Scoreboard: totals are mined + built + destroyed.
    expect(find.textContaining('#1'), findsWidgets);
    expect(find.text('5,900'), findsWidgets); // Computer 2: 2,600 + 2,100 + 1,200
    // Computer 1 invited me: its card offers to accept; the alliance of
    // Computers 2 and 3 (named, at war) can be invited.
    expect(find.text('Accept alliance'), findsOneWidget);
    expect(find.text('Iron Dawn'), findsOneWidget); // name code 1
    expect(find.text('Invite'), findsWidgets);
    expect(find.text('You'), findsWidgets); // my own card, no tag needed
    expect(find.textContaining('Fighting Computer 1'), findsWidgets);
  });

  testWidgets('a surrender offer shows its own card', (tester) async {
    final c = _controller();
    c.alliance = [
      _p(0, group: 0, surrenderFrom: 1 << 3),
      for (int s = 1; s < 8; ++s) _p(s, group: s),
    ];
    await _pump(tester, Center(child: InvitationCards(c: c)));
    expect(find.textContaining('offers to surrender to you', findRichText: true), findsOneWidget);
    expect(find.text('Accept surrender'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('score adds mining, building and destroying', () {
    final a = _p(1, group: 1, mined: 800, built: 1500, killed: 400);
    expect(a.score, 2700);
    expect(compactPoints(12345), '12.3k');
    expect(formatPoints(1234567), '1,234,567');
  });
}
