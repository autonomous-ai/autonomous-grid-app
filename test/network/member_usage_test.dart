import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/member_usage_provider.dart';
import 'package:grid_app/infrastructure/api/models/member_usage.dart';

MemberUsage _usage(
  String email, {
  int requests = 0,
  int tokensIn = 0,
  int tokensCached = 0,
  int tokensOut = 0,
}) => MemberUsage(
  email: email,
  requests: requests,
  tokensIn: tokensIn,
  tokensCached: tokensCached,
  tokensOut: tokensOut,
);

Map<String, MemberUsage> _byEmail(List<MemberUsage> rows) => {
  for (final row in rows) row.email!.toLowerCase(): row,
};

void main() {
  group('MemberUsage.fromJson', () {
    test('reads the four figures the relay sends', () {
      final row = MemberUsage.fromJson({
        'email': 'a@example.com',
        'requests': 12,
        'tokens_in': 900,
        'tokens_cached': 300,
        'tokens_out': 150,
      });

      expect(row?.email, 'a@example.com');
      expect(row?.requests, 12);
      expect(row?.tokensIn, 900);
      expect(row?.tokensCached, 300);
      expect(row?.tokensOut, 150);
    });

    test('cached is a share of input, so the split sums to what passed '
        'through', () {
      // Billing charges `(in − cached)·input + cached·cache + out·output`, so a
      // UI showing three token figures must use the fresh leg. Printing
      // `tokens_in` raw beside cache would count the cached prefill twice.
      final row = MemberUsage.fromJson({
        'tokens_in': 1000,
        'tokens_cached': 400,
        'tokens_out': 150,
      })!;

      expect(row.freshInputTokens, 600);
      expect(row.freshInputTokens + row.tokensCached + row.tokensOut, 1150);
      expect(row.totalTokens, 1150); // in + out, NOT in + cached + out
    });

    test('a cache larger than the input it is part of is clamped', () {
      // An old row or a provider bug would otherwise hand the panel a negative
      // fresh-input leg and a bar drawn past its own track.
      final row = MemberUsage.fromJson({
        'tokens_in': 100,
        'tokens_cached': 400,
      })!;

      expect(row.tokensCached, 100);
      expect(row.freshInputTokens, 0);
    });

    test(
      'a figure of the wrong type degrades to zero rather than throwing',
      () {
        // This arrives from a relay we do not control. A `TypeError` mid-parse
        // would cost the whole panel instead of one row's numbers.
        final row = MemberUsage.fromJson({
          'email': 'a@example.com',
          'requests': 'twelve',
          'tokens_in': null,
        })!;

        expect(row.requests, 0);
        expect(row.tokensIn, 0);
        expect(row.email, 'a@example.com');
      },
    );

    test('a row that is not an object is dropped, not guessed at', () {
      expect(MemberUsage.fromJson('nope'), isNull);
      expect(MemberUsage.fromJson(null), isNull);
    });

    test('a consumer the relay could not name keeps its figures', () {
      // `users` is written on first authentication and a transaction can outlive
      // it. Usage nobody can name is still usage — dropping it would stop the
      // rows adding up against the grid total.
      final row = MemberUsage.fromJson({'tokens_in': 42})!;

      expect(row.email, isNull);
      expect(row.tokensIn, 42);
    });
  });

  group('sortMembersByUsage', () {
    test('busiest reader first, so the panel opens on who is using the '
        'grid', () {
      final members = ['quiet@x.com', 'busy@x.com', 'middling@x.com'];
      final usage = _byEmail([
        _usage('quiet@x.com', tokensIn: 10),
        _usage('busy@x.com', tokensIn: 9000),
        _usage('middling@x.com', tokensIn: 500),
      ]);

      expect(sortMembersByUsage(members, usage, emailOf: (m) => m), [
        'busy@x.com',
        'middling@x.com',
        'quiet@x.com',
      ]);
    });

    test('a member the grid has no figure for sorts below a measured zero', () {
      // Someone counted and found idle is a different fact from someone the
      // grid never heard from, and the order has to keep them apart.
      final members = ['never-heard@x.com', 'measured-idle@x.com'];
      final usage = _byEmail([_usage('measured-idle@x.com')]);

      expect(sortMembersByUsage(members, usage, emailOf: (m) => m), [
        'measured-idle@x.com',
        'never-heard@x.com',
      ]);
    });

    test('ties break on the address, so a poll cannot shuffle the list', () {
      final members = ['charlie@x.com', 'alpha@x.com', 'bravo@x.com'];
      final usage = _byEmail([
        _usage('charlie@x.com', tokensIn: 500),
        _usage('alpha@x.com', tokensIn: 500),
        _usage('bravo@x.com', tokensIn: 500),
      ]);

      expect(sortMembersByUsage(members, usage, emailOf: (m) => m), [
        'alpha@x.com',
        'bravo@x.com',
        'charlie@x.com',
      ]);
    });

    test('no usage at all degrades to alphabetical, the old behaviour', () {
      // An older master, or a grid nobody used. The list still has to be a list.
      final members = ['zeta@x.com', 'Alpha@x.com'];

      expect(sortMembersByUsage(members, null, emailOf: (m) => m), [
        'Alpha@x.com',
        'zeta@x.com',
      ]);
    });

    test('leaves the roster it was given alone', () {
      final original = ['b@x.com', 'a@x.com'];

      sortMembersByUsage(original, null, emailOf: (m) => m);

      expect(original, ['b@x.com', 'a@x.com']);
    });

    test('the roster decides who is listed, usage only decides the order', () {
      // A consumer the relay still knows but the roster has dropped is not a
      // member any more and must not reappear in the panel.
      final members = ['still@x.com'];
      final usage = _byEmail([
        _usage('still@x.com', tokensIn: 1),
        _usage('removed@x.com', tokensIn: 9000),
      ]);

      expect(sortMembersByUsage(members, usage, emailOf: (m) => m), [
        'still@x.com',
      ]);
    });
  });

  group('memberUsageFor', () {
    test('matches an address whatever case each side stored it in', () {
      // The control plane stores what the user typed, the relay what the token
      // carried. A mismatch here shows a busy person as having done nothing.
      final usage = _byEmail([_usage('a@example.com', tokensIn: 5)]);

      expect(memberUsageFor(usage, 'A@Example.com')?.tokensIn, 5);
      expect(memberUsageFor(usage, '  a@example.com '), isNotNull);
    });

    test('null usage yields null, never a zero row', () {
      expect(memberUsageFor(null, 'a@example.com'), isNull);
    });
  });

  group('memberInputTotalLabel', () {
    test('totals the same leg the rows print, so the column adds up', () {
      // The header sits over a column of fresh-input figures. Totalling
      // `tokensIn` raw would give a header larger than the numbers beneath it.
      final label = memberInputTotalLabel([
        _usage('a@x.com', tokensIn: 1000, tokensCached: 400),
        _usage('b@x.com', tokensIn: 500, tokensCached: 100),
      ], 86400);

      expect(label, '1K input · 24h'); // 600 + 400
    });

    test('a member the grid has no figure for adds nothing, not an error', () {
      final label = memberInputTotalLabel([
        _usage('a@x.com', tokensIn: 900),
        null,
      ], 86400);

      expect(label, startsWith('900 input'));
    });

    test('names the span, because a bare count reads as all-time', () {
      expect(memberInputTotalLabel([], 86400), endsWith('· 24h'));
      expect(memberInputTotalLabel([], 3600), endsWith('· 1h'));
    });

    test('a relay that reported no span leaves the figure unqualified rather '
        'than inventing one', () {
      // Better a number with no window than a window nobody measured.
      expect(memberInputTotalLabel([], 0), '0 input');
    });
  });

  group('memberUsageLines', () {
    test('names the fresh input leg, not the raw total', () {
      final text = memberUsageLines(
        _usage(
          'a@x.com',
          requests: 12,
          tokensIn: 1000,
          tokensCached: 400,
          tokensOut: 150,
        ),
      ).join(' · ');

      expect(text, contains('600 input tokens'));
      expect(text, contains('400 from cache'));
      expect(text, contains('150 output tokens'));
      expect(text, contains('12 requests'));
    });

    test('splits into exactly two lines, asked then answered', () {
      // Two, because four figures on one line ran past the panel and were
      // ellipsized from the right — losing cache and output, the two a reader
      // cannot infer from the row above. And exactly two, because the panel
      // reserves that height whether or not a row is hovered: a list that grew
      // a line under the pointer would push the rows being read.
      final lines = memberUsageLines(
        _usage(
          'a@x.com',
          requests: 12,
          tokensIn: 1000,
          tokensCached: 400,
          tokensOut: 150,
        ),
      );

      expect(lines, hasLength(2));
      expect(lines.first, '12 requests · 600 input tokens');
      expect(lines.last, '400 from cache · 150 output tokens');
    });

    test('shortens a big figure the way every other count on screen is', () {
      final lines = memberUsageLines(_usage('a@x.com', tokensOut: 1240000));

      expect(lines.last, contains('1.2M output tokens'));
    });
  });
}
