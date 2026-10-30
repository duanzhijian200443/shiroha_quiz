import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

import '../application/external/external_file_read_test_support.dart';
import '../application/external/local_host_test_support.dart'
    show OfflineReadiness;

void main() {
  initializeGeneratedTests();
  for (final version in [2, 3]) {
    test('profile $version keeps the original file selection and passage path',
        () async {
      final files = FileReadHarness();
      await files.open(learningSpace: false);
      final host = LocalHostDispatchCore(
          gateway: ExternalCapabilityGateway(
              stages: files.s.service, reads: files.read),
          readiness: OfflineReadiness(() async {}));
      await host.startOffline();
      final app = VnextMcpAppComposition(
          host: host,
          reads: files.read,
          stages: files.s.service,
          authentication:
              VnextMcpSessionAuthentication(() async => files.s.session),
          approvedTargets: const [],
          profileVersion: version,
          source: const VnextDataSource('windows', 'local'));
      Future<Map> data(String tool, Map<String, dynamic> arguments) async {
        final result = await app.call(tool, arguments,
            cancelled: const Stream.empty(), available: () => true);
        expect(result['profileVersion'], version);
        expect(result['error'], isNull, reason: '$tool: $result');
        return result['data'] as Map;
      }

      try {
        final parent = await files.context();
        final open = version == 3 ? 'open_context' : 'open_generation_context';
        final choices = await data(open, {'contextRef': parent});
        final selected = await data(open, {
          'contextRef': parent,
          'fileRefs': [(choices['items'] as List).first['fileRef']]
        });
        final context = selected['contextRef'];
        final hits = await data('retrieve_file_content',
            {'contextRef': context, 'query': 'needle', 'limit': 1});
        final hit = (hits['items'] as List).single as Map;
        final passage = await data('get_file_passage', {
          'contextRef': context,
          'passageRef': hit['passageRef'],
        });
        expect(passage['items'], isNotEmpty);
        expect(files.index.searched, everyElement('file-a'));
        expect(files.generation.calls, 2,
            reason: 'External reads never regenerate a source artifact.');
      } finally {
        await app.close();
        await host.shutdown();
        await files.close();
      }
    });
  }
}
