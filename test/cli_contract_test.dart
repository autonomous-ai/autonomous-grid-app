import 'package:flutter_test/flutter_test.dart';
import 'package:toml/toml.dart';

import 'package:grid_app/infrastructure/api/models/chat_chunk.dart';
import 'package:grid_app/infrastructure/api/models/media_event.dart';
import 'package:grid_app/infrastructure/cli/parsers/catalog_entry.dart';
import 'package:grid_app/infrastructure/cli/parsers/denylist_entry.dart';
import 'package:grid_app/infrastructure/cli/parsers/download_progress.dart';
import 'package:grid_app/infrastructure/cli/parsers/member_entry.dart';
import 'package:grid_app/infrastructure/state/models/credentials_file.dart';
import 'package:grid_app/infrastructure/state/models/network_config.dart';

void main() {
  group('MemberEntry (§3.1)', () {
    test('parses an allowlist row', () {
      final m = MemberEntry.parse(
        'a@x.com\tactive\tprovider,consumer\tepoch=3',
      );
      expect(m, isNotNull);
      expect(m!.email, 'a@x.com');
      expect(m.status, 'active');
      expect(m.roles, ['provider', 'consumer']);
      expect(m.memberEpoch, 3);
    });

    test('garbage degrades to null, never throws', () {
      expect(MemberEntry.parse('not a row'), isNull);
      expect(MemberEntry.parseAll('header\njunk').isEmpty, isTrue);
    });
  });

  group('DenylistEntry (§3.2)', () {
    test('parses a denylist row', () {
      final d = DenylistEntry.parse('b@x.com\tby=admin@x.com\tat=2026-01-01');
      expect(d, isNotNull);
      expect(d!.email, 'b@x.com');
      expect(d.addedByEmail, 'admin@x.com');
      expect(d.addedAt, '2026-01-01');
    });
  });

  group('CatalogEntry (§3.3)', () {
    test('parses an entry without target', () {
      const line =
          '  qwen36-27b-mtp   unsloth/Qwen3.6-27B-MTP-GGUF/Qwen3.6-27B-UD-Q5_K_XL.gguf (min 24 GB, llm)';
      final c = CatalogEntry.parse(line);
      expect(c, isNotNull);
      expect(c!.label, 'qwen36-27b-mtp');
      expect(c.hfRepo, 'unsloth/Qwen3.6-27B-MTP-GGUF');
      expect(c.quantizedFile, 'Qwen3.6-27B-UD-Q5_K_XL.gguf');
      expect(c.target, isNull);
      expect(c.minVramGb, 24);
      expect(c.kind, 'llm');
      expect(
        c.pullSpec,
        'unsloth/Qwen3.6-27B-MTP-GGUF:Qwen3.6-27B-UD-Q5_K_XL.gguf',
      );
    });

    test('parses an entry with a target prefix', () {
      const line =
          '  big-model  org/repo/file.gguf (linux nvidia, min 48 GB, llm)';
      final c = CatalogEntry.parse(line);
      expect(c, isNotNull);
      expect(c!.target, 'linux nvidia');
      expect(c.minVramGb, 48);
    });
  });

  group('DownloadProgress (§3.4)', () {
    test('parses the full bar form', () {
      final p = DownloadProgress.parse(
        '[####    ]    123.4 / 456.7 MB ( 27.0%)',
      );
      expect(p, isNotNull);
      expect(p!.doneMb, 123.4);
      expect(p.totalMb, 456.7);
      expect(p.pct, 27.0);
      expect(p.isIndeterminate, isFalse);
    });

    test('parses the MB-only (unknown total) form', () {
      final p = DownloadProgress.parse('123.4 MB');
      expect(p, isNotNull);
      expect(p!.doneMb, 123.4);
      expect(p.isIndeterminate, isTrue);
    });

    test('latest() picks the freshest \\r segment', () {
      const raw =
          '\r123.4 MB\r[## ]  123.4 / 456.7 MB ( 27.0%)\r[####] 456.7 / 456.7 MB (100.0%)';
      final p = DownloadProgress.latest(raw);
      expect(p!.pct, 100.0);
    });
  });

  group('ChatChunk (§4.1)', () {
    test('extracts delta content', () {
      final c = ChatChunk.fromSseData(
        '{"choices":[{"delta":{"content":"hi"},"finish_reason":null}]}',
      );
      expect(c!.deltaContent, 'hi');
    });

    test('[DONE] sentinel is null', () {
      expect(ChatChunk.fromSseData('[DONE]'), isNull);
    });
  });

  group('MediaEvent (§4.2)', () {
    test('progress', () {
      final e = MediaEvent.fromSseData(
        '{"type":"progress","progress":42,"status":"running"}',
      );
      expect(e, isA<MediaProgress>());
      expect((e as MediaProgress).progress, 42);
    });

    test('result with output files', () {
      final e = MediaEvent.fromSseData(
        '{"type":"result","output_files":[{"filename":"a.png","content_base64":"AAAA"}]}',
      );
      expect(e, isA<MediaResult>());
      expect((e as MediaResult).files.single.filename, 'a.png');
    });

    test('error event', () {
      final e = MediaEvent.fromSseData('{"error":"boom"}');
      expect(e, isA<MediaError>());
      expect((e as MediaError).message, 'boom');
    });
  });

  group('credentials.toml (§1.1)', () {
    const toml = '''
api_url = "https://api-grid.autonomous.ai"
session_token = "sess-abc"
active_network = "grid-foo-abc12345"

[user]
email = "dev@autonomous.ai"

[[networks]]
network_id = "grid-foo-abc12345"
name = "foo"
network_type = "permissioned"
lan_signaling_url = "http://192.168.1.10:8090"
access_token = "jwt-access"
refresh_token = "jwt-refresh"
email = "dev@autonomous.ai"
roles = ["provider", "consumer"]
scopes = ["provider:poll", "consumer:chat"]
device_id = "dev-uuid"
node_id = "node-1"
member_epoch = 1
network_epoch = 1
expires_at = 1700000000
refresh_expires_at = 1700600000
''';

    test('parses session, user and active network with helpers', () {
      final creds = CredentialsFile.fromToml(TomlDocument.parse(toml).toMap());
      expect(creds.isLoggedIn, isTrue);
      expect(creds.userEmail, 'dev@autonomous.ai');
      final active = creds.active!;
      expect(active.networkId, 'grid-foo-abc12345');
      expect(active.relayBaseUrl, 'http://192.168.1.10:8090/relay/v1');
      expect(active.isProvider, isTrue);
      expect(active.isExpired(DateTime.utc(2026)), isTrue);
    });
  });

  group('network config.toml (§1.2)', () {
    const toml = '''
network_id = "grid-foo-abc12345"
name = "foo"
network_type = "permissioned"
port = 8090
lan_signaling_url = "http://192.168.1.10:8090"
api_url = "https://api-grid.autonomous.ai"
postgres_port = 54321
postgres_password = "pgpass"
postgres_container = "grid-postgres-grid-foo-abc12345"
server_pid = 12345
sync_pid = 12346
grid_admin_secret = "adminsecret"
''';

    test('parses pids and derives the health URL', () {
      final cfg = NetworkConfig.fromToml(TomlDocument.parse(toml).toMap());
      expect(cfg.serverPid, 12345);
      expect(cfg.hasServerPid, isTrue);
      expect(cfg.managedServer, isTrue);
      expect(cfg.serverInfoUrl, 'http://127.0.0.1:8090/server/info');
    });
  });
}
