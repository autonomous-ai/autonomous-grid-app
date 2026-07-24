import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/playground_models.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/shared/widgets/modality_mark.dart';

/// The model list mixes chat models with the media *modes* a grid's nodes offer,
/// and the glyph is the only thing that tells them apart. These pin what each one
/// may and may not say.
void main() {
  group('modalityIcon', () {
    test('three kinds of row, three marks — a shared glyph would tell them '
        'apart not at all', () {
      expect({
        modalityIcon(PlaygroundModality.text),
        modalityIcon(PlaygroundModality.image),
        modalityIcon(PlaygroundModality.video),
      }, hasLength(3));
    });

    test('a text model is never marked with the glyph that means "a chat"', () {
      // The composer's list holds model *names*. Marking them with the speech
      // bubble the command palette puts on "Open a chat" made a row of models
      // read as a row of conversations — which is what a user reported.
      final chatGlyphs = {
        Icons.chat_bubble_outline_rounded,
        Icons.chat_bubble_outline,
        Icons.chat_bubble,
        Icons.forum_outlined,
        Icons.message,
      };
      expect(
        chatGlyphs,
        isNot(contains(modalityIcon(PlaygroundModality.text))),
      );
    });
  });

  group('modelIcon', () {
    PlaygroundModelOption option(ModelHosting hosting) => PlaygroundModelOption(
      id: 'm',
      label: 'm',
      modality: PlaygroundModality.text,
      hosting: hosting,
    );

    test(
      'a cloud relay and a machine on the grid never share a mark — which '
      'one is about to answer is the thing the row can least afford to hide',
      () {
        expect(
          modelIcon(option(ModelHosting.cloud)),
          isNot(modelIcon(option(ModelHosting.onGrid))),
        );
      },
    );

    test('a model we cannot place claims neither', () {
      final unplaced = modelIcon(option(ModelHosting.unknown));
      expect(unplaced, isNot(modelIcon(option(ModelHosting.cloud))));
      expect(unplaced, isNot(modelIcon(option(ModelHosting.onGrid))));
      expect(unplaced, modalityIcon(PlaygroundModality.text));
    });

    test('the media modes keep their own marks, hosting or not', () {
      for (final modality in [
        PlaygroundModality.image,
        PlaygroundModality.video,
      ]) {
        expect(
          modelIcon(
            PlaygroundModelOption(
              id: 'x',
              label: 'x',
              modality: modality,
              hosting: ModelHosting.cloud,
            ),
          ),
          modalityIcon(modality),
        );
      }
    });
  });

  group('modalityTone', () {
    test('text stays in the quiet ink and only the media modes are tinted — '
        'colour marks what differs, not everything', () {
      final text = modalityTone(PlaygroundModality.text);
      expect(modalityTone(PlaygroundModality.image), isNot(text));
      expect(modalityTone(PlaygroundModality.video), isNot(text));
    });
  });
}
