import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hotline/platform/herdr_client.dart';

void main() {
  test('parses a local herdr agent list fixture', () {
    final source = File('test/fixtures/herdr_agent_list.json')
        .readAsStringSync();
    final agents = HerdrClient.parseAgentList(source);

    expect(agents, hasLength(3));
    expect(agents.first.paneId, 'wQ:p1');
    expect(agents.first.agent, 'claude');
    expect(agents.first.agentStatus, 'idle');
    expect(agents.first.terminalTitleStripped, 'app-init-orchestator');
    expect(agents.first.workspaceId, 'wQ');
    expect(agents.first.cwd, '/home/luisnquin/.dotfiles');
    expect(agents.first.stateChangeSeq, 248);
  });

  test('a lookup failure is not a refused connection', () {
    // Dart words the DNS failure in the exception's own message; the errno
    // beneath is EAI_*, a namespace that cannot be told from a connect errno
    // by number, which is why this reads the words.
    expect(
      HerdrClient.isLookupFailure(
        const SocketException(
          "Failed host lookup: 'nope.invalid'",
          osError: OSError('No address associated with hostname', -5),
        ),
      ),
      isTrue,
    );
    expect(
      HerdrClient.isLookupFailure(
        const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 111),
        ),
      ),
      isFalse,
    );
    // A tarpit that accepts and never speaks is a timeout, not a lookup.
    expect(
      HerdrClient.isLookupFailure(
        const SocketException('Connection timed out'),
      ),
      isFalse,
    );
  });

  test('rejects a response from an unknown protocol shape', () {
    expect(
      () => HerdrClient.parseAgentList(
        '{"protocol":22,"result":{"type":"other"}}',
      ),
      throwsA(
        isA<HerdrProtocolMismatch>().having(
          (error) => error.protocol,
          'protocol',
          22,
        ),
      ),
    );
  });
}
