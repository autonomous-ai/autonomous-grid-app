import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/scheduled/logic/scheduled_job.dart';
import 'package:grid_app/features/scheduled/logic/task_model_fallback.dart';
import 'package:grid_app/features/scheduled/logic/task_models.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';

ScheduledJob _job({
  String id = 'j1',
  String? model,
  String? lastError,
  String name = 'Daily digest',
}) => ScheduledJob(
  id: id,
  name: name,
  prompt: 'Summarise',
  cron: '0 8 * * *',
  enabled: true,
  model: model,
  lastError: lastError,
);

PlaygroundModelOption _option(
  String id, {
  PlaygroundModality modality = PlaygroundModality.text,
}) => PlaygroundModelOption(id: id, label: id, modality: modality);

void main() {
  group('a task whose model stopped working falls back to the router', () {
    test('a model the grid no longer serves is swapped — nobody is watching at '
        '8am to notice it went quiet', () {
      final jobs = [_job(model: 'qwen3.6-27b-office')];

      expect(autoFallbackTargets(jobs, {'auto', 'minimax/minimax-m3'}), ['j1']);
    });

    test(
      'a last run that blames the model is swapped; one that blames the task '
      'is left alone, so a swap never hides a broken prompt',
      () {
        final blamed = _job(
          id: 'blamed',
          model: 'qwen3.6-27b-office',
          lastError: 'RuntimeError: no providers available for this model',
        );
        final ownFault = _job(
          id: 'own-fault',
          model: 'qwen3.6-27b-office',
          lastError: 'ToolError: rg: command not found',
        );

        expect(autoFallbackTargets([blamed, ownFault], const {}), ['blamed']);
      },
    );

    test('an unloaded model list moves nothing — reading "not known yet" as '
        '"all gone" would re-point every task on the first sweep', () {
      final jobs = [_job(model: 'qwen3.6-27b-office')];

      expect(autoFallbackTargets(jobs, const {}), isEmpty);
    });

    test(
      'a task already on the router, and one that follows the computer, have '
      'nowhere to fall',
      () {
        final jobs = [_job(id: 'router', model: 'auto'), _job(id: 'unpinned')];

        expect(autoFallbackTargets(jobs, {'minimax/minimax-m3'}), isEmpty);
      },
    );

    test('the reason names the task and the evidence — the app is overriding a '
        'choice the user made', () {
      final gone = _job(model: 'qwen3.6-27b-office');
      final reason = autoFallbackReason(gone, {'minimax/minimax-m3'});

      expect(reason, contains('Daily digest'));
      expect(reason, contains('qwen3.6-27b-office'));
    });
  });

  group('which models a task may be pinned to', () {
    test('the router leads, and the seat models the assistant cannot answer '
        'with are not offered at all', () {
      final options = taskModelOptions([
        _option('claude:claude-sonnet-5'),
        _option('qwen3.6-27b-office'),
        _option('auto'),
        _option('codex-cli:gpt-5.5'),
      ]);

      expect(options.map((o) => o.id), ['auto', 'qwen3.6-27b-office']);
    });

    test('the media modes are dropped — a task has no chat endpoint to call on '
        'an image mode', () {
      final options = taskModelOptions([
        _option('qwen3.6-27b-office'),
        _option('Image', modality: PlaygroundModality.image),
      ]);

      expect(options.map((o) => o.id), ['qwen3.6-27b-office']);
    });

    test(
      'a new task starts on the model the user last chatted with, and on the '
      'router when that model is not on this grid',
      () {
        final options = taskModelOptions([
          _option('auto'),
          _option('qwen3.6-27b-office'),
        ]);

        expect(
          defaultTaskModel(options, 'qwen3.6-27b-office'),
          'qwen3.6-27b-office',
        );
        expect(defaultTaskModel(options, 'gone/elsewhere'), 'auto');
        expect(defaultTaskModel(options, null), 'auto');
        expect(defaultTaskModel(const [], 'qwen3.6-27b-office'), '');
      },
    );
  });
}
