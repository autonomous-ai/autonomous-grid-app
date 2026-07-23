import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_context_meter.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/logic/chat_reply.dart';
import 'package:grid_app/features/playground/logic/context_usage.dart';
import 'package:grid_app/infrastructure/api/models/grid_overview.dart';

Conversation _chat({
  List<ChatMessage> messages = const [],
  int? contextTokens,
  int? contextLimit,
  String model = 'qwen3.6-27b',
}) => Conversation(
  id: 'c1',
  title: 'A chat',
  model: model,
  createdAt: DateTime(2026, 7, 1),
  updatedAt: DateTime(2026, 7, 1),
  messages: messages,
  contextTokens: contextTokens,
  contextLimit: contextLimit,
);

ChatMessage _user(String text) => ChatMessage(role: ChatRole.user, text: text);

void main() {
  group('estimateTokens — the fallback when nothing reports usage', () {
    test('empty text costs nothing', () {
      expect(estimateTokens(''), 0);
    });

    test('an accented Vietnamese line costs more than the ASCII rule of thumb, '
        'so a chat in Vietnamese does not read as a third as full', () {
      const vietnamese = 'Cửa sổ ngữ cảnh đã dùng bao nhiêu phần trăm rồi?';
      expect(estimateTokens(vietnamese), greaterThan(vietnamese.length ~/ 4));
    });

    test('the whole conversation is counted, not just the last turn', () {
      final one = estimateConversationTokens([_user('hello there')]);
      final two = estimateConversationTokens([
        _user('hello there'),
        _user('hello there'),
      ]);
      expect(two, greaterThan(one));
    });

    test('an empty transcript costs nothing at all — not the system head', () {
      expect(estimateConversationTokens(const []), 0);
    });
  });

  group('ContextUsage — a share only when there is a window to share', () {
    test('no window means no share to draw', () {
      const usage = ContextUsage(usedTokens: 1000);
      expect(usage.fraction, isNull);
      expect(usage.percentUsed, isNull);
    });

    test('the share is rounded to a whole percent for the tooltip', () {
      const usage = ContextUsage(usedTokens: 62000, limitTokens: 258000);
      expect(usage.percentUsed, 24);
    });

    test('a model that compacts its own history can report more than the '
        'window it compacted into — the ring stays full, never overfull', () {
      const usage = ContextUsage(usedTokens: 300000, limitTokens: 258000);
      expect(usage.fraction, 1.0);
      expect(usage.percentUsed, 100);
    });

    test('a reporter that counts tokens but names no window takes the window '
        'offered to it, and one that named its own keeps it', () {
      const counted = ContextUsage(usedTokens: 5000);
      expect(counted.withLimit(128000).limitTokens, 128000);

      const reported = ContextUsage(usedTokens: 5000, limitTokens: 8192);
      expect(reported.withLimit(128000).limitTokens, 8192);
    });
  });

  group('formatTokenCount — two numbers the eye can compare', () {
    test('small counts stay exact, thousands and millions shorten', () {
      expect(formatTokenCount(840), '840');
      expect(formatTokenCount(1200), '1.2k');
      expect(formatTokenCount(62000), '62k');
      expect(formatTokenCount(258000), '258k');
      expect(formatTokenCount(1050000), '1.1M');
    });

    test('a round figure loses its trailing zero — "1k", not "1.0k"', () {
      expect(formatTokenCount(1000), '1k');
    });
  });

  group('extractUsage — both wire dialects, one reading', () {
    test('chat completions report prompt + completion tokens', () {
      final usage = extractUsage({
        'usage': {
          'prompt_tokens': 1200,
          'completion_tokens': 300,
          'total_tokens': 1500,
        },
      });
      expect(usage?.usedTokens, 1500);
      expect(usage?.limitTokens, isNull);
    });

    test('the Responses dialect reports input + output tokens', () {
      final usage = extractUsage({
        'usage': {'input_tokens': 900, 'output_tokens': 100},
      });
      expect(usage?.usedTokens, 1000);
    });

    test('a body with no usage block reports nothing rather than zero', () {
      expect(extractUsage({'choices': const []}), isNull);
      expect(extractUsage({'usage': 'nope'}), isNull);
      expect(extractUsage(null), isNull);
    });
  });

  group('chatContextUsage — what the composer ring may honestly show', () {
    test('a chat nobody has answered yet gets no ring', () {
      expect(chatContextUsage(_chat(), advertisedWindow: 128000), isNull);
    });

    test(
      'a window nobody publishes means no ring, not a guessed denominator',
      () {
        final usage = chatContextUsage(
          _chat(messages: [_user('hi')], contextTokens: 900),
          advertisedWindow: null,
        );
        expect(usage, isNull);
      },
    );

    test(
      'the count the model reported wins, and is not flagged an estimate',
      () {
        final usage = chatContextUsage(
          _chat(messages: [_user('hi')], contextTokens: 62000),
          advertisedWindow: 258000,
        );
        expect(usage!.usedTokens, 62000);
        expect(usage.estimated, isFalse);
        expect(usage.limitTokens, 258000);
      },
    );

    test('a window the answering agent named beats the one the grid '
        'advertises — it is the window the tokens were measured in', () {
      final usage = chatContextUsage(
        _chat(messages: [_user('hi')], contextTokens: 900, contextLimit: 8192),
        advertisedWindow: 258000,
      );
      expect(usage!.limitTokens, 8192);
    });

    test('an unreported chat falls back to counting itself, flagged so the '
        'tooltip can say "about"', () {
      final usage = chatContextUsage(
        _chat(messages: [_user('hello there, this is a fairly long line')]),
        advertisedWindow: 128000,
      );
      expect(usage!.estimated, isTrue);
      expect(usage.usedTokens, greaterThan(0));
    });
  });

  group('advertisedContextWindow — only what the grid actually published', () {
    AsyncValue<GridOverview> overviewOf(List<OverviewModel> models) =>
        AsyncValue.data(
          GridOverview(
            stats: const GridStats(models: 1, nodes: 1),
            models: models,
            nodes: const [],
          ),
        );

    test('reads the context length of the model that is answering', () {
      final window = advertisedContextWindow(
        overviewOf(const [
          OverviewModel(id: 'other', contextLength: 8192),
          OverviewModel(id: 'qwen3.6-27b', contextLength: 262144),
        ]),
        'qwen3.6-27b',
      );
      expect(window, 262144);
    });

    test('a model listed without a context length reads as unknown, never '
        'as zero', () {
      final window = advertisedContextWindow(
        overviewOf(const [OverviewModel(id: 'qwen3.6-27b')]),
        'qwen3.6-27b',
      );
      expect(window, isNull);
    });

    test('an overview that is still loading or offline knows nothing', () {
      expect(
        advertisedContextWindow(const AsyncValue.loading(), 'qwen3.6-27b'),
        isNull,
      );
    });
  });
}
