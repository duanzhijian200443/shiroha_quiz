"""Pure guards only; never starts Codex or an operating-system process."""
import json
import os
from pathlib import Path
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import offline_codex_shutdown as driver
from offline_mcp_shutdown import Protocol, Records, close_resource


class Guards(unittest.TestCase):
    def test_candidate_manifest_binds_exact_artifacts_and_fixed_limits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            executable = root / 'target/dev-small/codex.exe'
            executable.parent.mkdir(parents=True)
            source = root / 'source.json'
            patch_file = root / 'candidate.patch'
            for file in (executable, source, patch_file):
                file.write_bytes(b'synthetic artifact')
            value = {'formatVersion': 1, 'kind': 'isolated-codex-graceful-close',
                     'executable': str(executable), 'sha256': driver.digest(executable),
                     'sourceBase': driver.CANDIDATE_BASE, 'sourceManifestPath': str(source),
                     'sourceManifestSha256': driver.digest(source), 'patchPath': str(patch_file),
                     'patchSha256': driver.digest(patch_file), 'shutdownGraceMs': 3000,
                     'shutdownBoundMs': 9000, 'toolchain': {'rustc': 'synthetic rustc',
                         'cargo': 'synthetic cargo', 'target': 'x86_64-pc-windows-msvc',
                         'profile': 'dev-small'}}
            manifest = root / 'candidate.json'
            with patch.object(driver, 'CANDIDATE_ROOT', root):
                manifest.write_text(json.dumps(value))
                self.assertEqual(driver.load_candidate(manifest), value)
                for key, replacement in [('extra', 'not-allowed'), ('shutdownGraceMs', 3001),
                                         ('shutdownBoundMs', 9001), ('formatVersion', True),
                                         ('executable', str(driver.CODEX)),
                                         ('patchPath', str(root.parent / 'outside.patch')),
                                         ('sha256', '0' * 64), ('sourceBase', '0' * 40)]:
                    manifest.write_text(json.dumps({**value, key: replacement}))
                    with self.assertRaises(ValueError):
                        driver.load_candidate(manifest)
                manifest.write_text(json.dumps(value)[:-1] + ',"formatVersion":1}')
                with self.assertRaises(ValueError):
                    driver.load_candidate(manifest)
                manifest.write_text(json.dumps(value))
                source.write_bytes(b'changed')
                with self.assertRaises(ValueError):
                    driver.load_candidate(manifest)

    def test_candidate_config_changes_only_fixture_scenario_argument(self):
        case = Path('C:/synthetic')
        original = tomllib.loads(driver.config(case, 'a' * 32, 'http://127.0.0.1:123/v1'))
        for scenario in driver.SCENARIOS:
            candidate = tomllib.loads(driver.config(case, 'a' * 32, 'http://127.0.0.1:123/v1', scenario))
            self.assertEqual(candidate['mcp_servers']['shiroha_vnext']['args'].pop(), scenario)
            self.assertEqual(candidate, original)

    def test_cleanup_delay_occurs_after_begin_and_before_original_resource_close(self):
        for scenario, delay in [(None, None), ('normal', None), ('delayed', .75), ('hang', 30)]:
            events = []
            class Resource:
                def close(self): events.append('closed')
            close_resource(Resource(), lambda stage: events.append(stage), scenario,
                           sleep=lambda seconds: events.append(seconds))
            self.assertEqual(events, ['cleanup_begin', *([] if delay is None else [delay]),
                                      'closed', 'cleanup_end'])

    @staticmethod
    def candidate_rows(scenario, terminal=True):
        base = 10_000_000_000
        fields = [
            ('start', {'pid': 1, 'parent': 2, 'started': '123', 'sha256': 'a' * 64,
                       'scenario': scenario, 'cleanupDelayMs': driver.SCENARIO_DELAY_MS[scenario]}),
            ('initialize', {'protocol': '2025-11-25'}), ('list', {'count': 1}),
            ('call', {'count': 1}), ('eof', {}), ('cleanup_begin', {})]
        if terminal:
            fields += [('cleanup_end', {}), ('terminal', {'complete': True, 'calls': 1})]
        rows = []
        for index, (stage, extra) in enumerate(fields, 1):
            timestamp = base + index * 1_000_000
            if index >= 7:
                timestamp += driver.SCENARIO_DELAY_MS[scenario] * 1_000_000
            rows.append({'fixtureVersion': 2, 'sequence': index, 'stage': stage,
                         'monotonicNs': timestamp, **extra})
        return rows

    def test_candidate_normal_and_delayed_need_real_complete_and_sufficient_delay(self):
        result = {'executionComplete': True, 'forced': False, 'cleanupFailed': False,
                  'hostExit': 0, 'mcpExit': 0}
        for scenario in ('normal', 'delayed'):
            rows = self.candidate_rows(scenario)
            observed = driver.candidate_outcome(result, rows, scenario,
                                                10_000_000_000, 11_000_000_000, 11_000_000_000)
            self.assertTrue(observed['compatible'])
            self.assertTrue(observed['scenarioPassed'])
            self.assertFalse(observed['timeoutProtectionPassed'])
            for altered in [rows[:-1], rows + [rows[-1]], self.candidate_rows('hang')]:
                self.assertFalse(driver.candidate_outcome(result, altered, scenario,
                    10_000_000_000, 11_000_000_000, 11_000_000_000)['scenarioPassed'])
        rows = self.candidate_rows('delayed')
        rows[6]['monotonicNs'] = rows[5]['monotonicNs'] + 749_000_000
        self.assertFalse(driver.candidate_outcome(result, rows, 'delayed',
            10_000_000_000, 11_000_000_000, 11_000_000_000)['compatible'])

    def test_v2_record_shape_rejects_extra_fields_and_regressing_clock(self):
        for field, value in [('fixtureVersion', True), ('sequence', True),
                             ('monotonicNs', -1), ('unexpected', 'SENTINEL')]:
            rows = self.candidate_rows('normal')
            rows[2][field] = value
            self.assertFalse(driver.candidate_record_shape(rows, 'normal', terminal=True))
        rows = self.candidate_rows('normal')
        rows[2]['monotonicNs'] = rows[1]['monotonicNs'] - 1
        self.assertFalse(driver.candidate_record_shape(rows, 'normal', terminal=True))

    def test_largest_v2_header_stays_in_existing_line_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.jsonl'
            records = Records(path, version=2)
            records.add('start', pid=4294967295, parent=4294967295,
                        started='18446744073709551615', sha256='a' * 64,
                        scenario='delayed', cleanupDelayMs=750)
            records.file.close()
            self.assertLessEqual(len(path.read_bytes()), 512)
            row = json.loads(path.read_text())
            self.assertEqual(row['fixtureVersion'], 2)
            self.assertIs(type(row['monotonicNs']), int)

    def test_hang_protection_is_not_graceful_and_requires_bounded_original_exit(self):
        result = {'executionComplete': True, 'forced': False, 'cleanupFailed': False,
                  'hostExit': 0, 'mcpExit': 1}
        rows = self.candidate_rows('hang', terminal=False)
        observed = driver.candidate_outcome(result, rows, 'hang',
                                            10_000_000_000, 13_100_000_000, 13_000_000_000,
                                            12_900_000_000)
        self.assertTrue(observed['scenarioPassed'])
        self.assertTrue(observed['timeoutProtectionPassed'])
        self.assertFalse(observed['compatible'])
        for changed, host_time, child_time in [
            ({**result, 'forced': True}, 13_100_000_000, 13_000_000_000),
            ({**result, 'mcpExit': 0}, 13_100_000_000, 13_000_000_000),
            (result, 11_000_000_000, 11_000_000_000),
            (result, 19_000_000_001, 19_000_000_001),
            (result, None, 13_000_000_000)]:
            self.assertFalse(driver.candidate_outcome(changed, rows, 'hang',
                10_000_000_000, host_time, child_time, 12_900_000_000)['scenarioPassed'])

    def test_hang_protection_rejects_client_failure_or_crash(self):
        rows = self.candidate_rows('hang', terminal=False)
        for exit_code in (1, 101, 0xC0000409, None):
            with self.subTest(exit_code=exit_code):
                result = {'executionComplete': True, 'forced': False, 'cleanupFailed': False,
                          'hostExit': exit_code, 'mcpExit': 1}
                observed = driver.candidate_outcome(result, rows, 'hang',
                    10_000_000_000, 13_100_000_000, 13_000_000_000, 12_900_000_000)
                self.assertFalse(observed['timeoutProtectionPassed'])
                self.assertFalse(observed['scenarioPassed'])
                self.assertFalse(observed['compatible'])

    def test_late_exit_observation_cannot_prove_prior_process_survival(self):
        result = {'executionComplete': True, 'forced': False, 'cleanupFailed': False,
                  'hostExit': 0, 'mcpExit': 1}
        rows = self.candidate_rows('hang', terminal=False)
        for last_alive in (None, 10_100_000_000):
            observed = driver.candidate_outcome(result, rows, 'hang',
                10_000_000_000, 18_000_000_000, 18_000_000_000, last_alive)
            self.assertGreater(observed['cleanupExitObservedUpperBoundMs'], 2500)
            self.assertFalse(observed['timeoutProtectionPassed'])
            self.assertFalse(observed['scenarioPassed'])

    def test_alive_timestamp_is_from_before_successful_liveness_query_only(self):
        events = []
        class Native:
            exited_value = False
            def exited(self, handle):
                events.append(('query', handle))
                return self.exited_value
        timestamps = iter([100, 800, 900])
        def clock():
            value = next(timestamps)
            events.append(('clock', value))
            return value
        native = Native()
        last_alive, exited = driver.observe_original_process(native, 42, None, None, clock)
        self.assertEqual((last_alive, exited), (100, None))
        self.assertEqual(events, [('clock', 100), ('query', 42)])
        native.exited_value = True
        last_alive, exited = driver.observe_original_process(native, 42, last_alive, exited, clock)
        self.assertEqual((last_alive, exited), (100, 900))
        self.assertEqual(events[-3:], [('clock', 800), ('query', 42), ('clock', 900)])
        self.assertEqual(driver.observe_original_process(native, 42, last_alive, exited, clock),
                         (100, 900))

    @staticmethod
    def completed_client(config_path=None):
        observed = driver.ClientObservation('a' * 32, config_path)
        value = {'data': {'ok': True, 'nonce': 'a' * 32}}
        observed.accept({'type': 'item.completed', 'item': {'type': 'mcp_tool_call',
            'server': 'shiroha_vnext', 'tool': 'probe_read', 'status': 'completed',
            'error': None, 'result': {'content': [{'type': 'text', 'text': json.dumps(value)}],
                                     'structured_content': value}}})
        observed.accept({'type': 'item.completed', 'item': {'type': 'agent_message',
            'text': 'Offline probe complete: ' + 'a' * 32}})
        observed.accept({'type': 'turn.completed'})
        return observed

    def test_exact_isolation_warning_is_bound_to_this_config_and_single_feature(self):
        config_path = Path('C:/synthetic-case/home/config.toml')
        message = driver.expected_isolation_warning(config_path)
        observed = self.completed_client(config_path)
        observed.accept({'type': 'item.completed', 'item': {'type': 'error', 'message': message}})
        summary = observed.summary()
        self.assertTrue(summary['protocolPassed'])
        self.assertEqual(summary['expectedIsolationWarnings'], 1)
        self.assertEqual(summary['isolationWarningFeature'], 'skip_host_skill_discovery')
        self.assertNotIn(str(config_path), json.dumps(summary))
        observed.accept({'type': 'item.completed', 'item': {'type': 'error', 'message': message}})
        self.assertFalse(observed.summary()['protocolPassed'])
        for altered in [message + ' ', message.replace('skip_host_skill_discovery.',
                                                       'skip_host_skill_discovery, other.'),
                        message.replace('skip_host_skill_discovery', 'other'),
                        driver.expected_isolation_warning(Path('C:/other/home/config.toml'))]:
            observed = self.completed_client(config_path)
            observed.accept({'type': 'item.completed', 'item': {'type': 'error', 'message': altered}})
            self.assertFalse(observed.summary()['protocolPassed'])
            self.assertEqual(observed.summary()['expectedIsolationWarnings'], 0)
        observed = self.completed_client()
        observed.accept({'type': 'item.completed', 'item': {'type': 'error', 'message': message}})
        self.assertFalse(observed.summary()['protocolPassed'])

    def test_isolation_warning_cannot_hide_top_level_or_business_failure(self):
        path = Path('C:/synthetic-case/home/config.toml')
        observed = self.completed_client(path)
        observed.accept({'type': 'error', 'message': driver.expected_isolation_warning(path)})
        self.assertFalse(observed.summary()['protocolPassed'])
        self.assertEqual(observed.summary()['topLevelErrors'], 1)
        empty = driver.ClientObservation('a' * 32, path)
        empty.accept({'type': 'item.completed', 'item': {'type': 'error',
                      'message': driver.expected_isolation_warning(path)}})
        self.assertFalse(empty.summary()['protocolPassed'])

    def test_exact_fixture_warning_once_is_separate_from_business_result(self):
        observed = self.completed_client()
        observed.accept({'type': 'item.completed', 'item': {'type': 'error',
                         'message': driver.EXPECTED_FIXTURE_WARNING}})
        summary = observed.summary()
        self.assertTrue(summary['protocolPassed'])
        self.assertEqual(summary['expectedFixtureWarnings'], 1)
        self.assertTrue(all(summary['predicates'].values()))
        self.assertEqual(summary['unexpectedItems'], {})
        observed.accept({'type': 'item.completed', 'item': {'type': 'error',
                         'message': driver.EXPECTED_FIXTURE_WARNING}})
        self.assertFalse(observed.summary()['protocolPassed'])

    def test_similar_unknown_and_top_level_errors_remain_failures(self):
        for message in [driver.EXPECTED_FIXTURE_WARNING + ' ',
                        driver.EXPECTED_FIXTURE_WARNING.replace('offline-shutdown', 'other'),
                        'SENTINEL_PRIVATE_ERROR']:
            observed = self.completed_client()
            observed.accept({'type': 'item.completed', 'item': {'type': 'error', 'message': message}})
            self.assertFalse(observed.summary()['protocolPassed'])
            self.assertEqual(observed.summary()['unexpectedItems'], {'error': 1})
            self.assertNotIn('SENTINEL', json.dumps(observed.summary()))
        observed = self.completed_client()
        observed.accept({'type': 'error', 'message': driver.EXPECTED_FIXTURE_WARNING})
        self.assertFalse(observed.summary()['protocolPassed'])
        self.assertEqual(observed.summary()['topLevelErrors'], 1)

    def test_warning_never_fills_missing_or_invalid_call_predicates(self):
        observed = driver.ClientObservation('a' * 32)
        observed.accept({'type': 'item.completed', 'item': {'type': 'error',
                         'message': driver.EXPECTED_FIXTURE_WARNING}})
        self.assertFalse(observed.summary()['protocolPassed'])
        observed.accept({'type': 'item.completed', 'item': {'type': 'mcp_tool_call',
            'server': 'other', 'tool': 'probe_read', 'status': 'completed', 'result': {}}})
        self.assertFalse(observed.summary()['predicates']['server'])
        self.assertFalse(observed.summary()['predicates']['resultExact'])
        self.assertFalse(observed.summary()['protocolPassed'])

    def test_environment_never_inherits_private_or_global_values(self):
        with patch.dict(os.environ, {'OPENAI_API_KEY': 'SENTINEL',
                                     'CODEX_HOME': 'SENTINEL',
                                     'HTTPS_PROXY': 'SENTINEL'}):
            env = driver.environment(Path('C:/synthetic'))
        self.assertNotIn('SENTINEL', json.dumps(env))
        self.assertNotIn('OPENAI_API_KEY', env)
        self.assertEqual(env['CODEX_HOME'], str(Path('C:/synthetic') / 'home'))

    def test_config_only_local_provider_and_fixed_fixture(self):
        text = driver.config(Path('C:/synthetic'), 'a' * 32, 'http://127.0.0.1:12345/v1')
        value = tomllib.loads(text)
        self.assertEqual(value['cli_auth_credentials_store'], 'file')
        self.assertEqual(value['mcp_oauth_credentials_store'], 'file')
        self.assertFalse(value['model_providers']['offline']['requires_openai_auth'])
        self.assertFalse(value['model_providers']['offline']['supports_websockets'])
        self.assertEqual(value['model_providers']['offline']['request_max_retries'], 0)
        self.assertEqual(value['model_providers']['offline']['stream_max_retries'], 0)
        self.assertEqual(value['mcp_servers']['shiroha_vnext']['enabled_tools'], ['probe_read'])
        self.assertEqual(value['mcp_servers']['shiroha_vnext']['command'], sys.executable)
        self.assertTrue(value['features']['skip_host_skill_discovery'])
        self.assertFalse(value['features']['shell_tool'])
        self.assertNotIn('env_key', value['model_providers']['offline'])
        self.assertIn('model_provider="offline"', driver.overrides(text))
        self.assertIn('project_root_markers=[]', driver.overrides(text))
        dotted = driver.config(Path('C:/synthetic.a/b.c'), 'a' * 32,
                               'http://127.0.0.1:12345/v1')
        project_override = next(arg for arg in driver.overrides(dotted)
                                if arg.startswith('projects='))
        self.assertEqual(tomllib.loads(project_override)['projects'],
                         {str(Path('C:/synthetic.a/b.c') / 'work'):
                          {'trust_level': 'untrusted'}})
        for uri in ['https://example.invalid/v1', 'http://127.0.0.1:8@evil/v1',
                    'http://127.0.0.1:0/v1', 'http://localhost:8/v1']:
            with self.assertRaises(ValueError):
                driver.config(Path('C:/synthetic'), 'a' * 32, uri)

    def test_protocol_negotiation_original_nonce_and_single_call(self):
        records = []
        protocol = Protocol('a' * 32, lambda stage, **fields: records.append(stage))
        def call(method, params):
            return protocol.receive({'jsonrpc': '2.0', 'id': 1,
                                     'method': method, 'params': params})
        with self.assertRaises(ValueError):
            call('tools/list', {})
        self.assertEqual(call('initialize', {'protocolVersion': 'future'})[
            'result']['protocolVersion'], '2025-11-25')
        advertised = call('tools/list', {})['result']['tools']
        self.assertEqual(len(advertised), 1)
        self.assertEqual(advertised[0]['annotations'], {
            'readOnlyHint': True, 'destructiveHint': False, 'openWorldHint': False})
        result = call('tools/call', {'name': 'probe_read', 'arguments': {}})['result']
        self.assertTrue(driver.exact_result(result, 'a' * 32))
        self.assertFalse(driver.exact_result(result, 'b' * 32))
        self.assertFalse(driver.exact_result({**result, 'isError': True}, 'a' * 32))
        for flag in ['isError', 'is_error']:
            for value in [True, 0, None, 'false']:
                self.assertFalse(driver.exact_result({**result, flag: value}, 'a' * 32))
        self.assertFalse(driver.exact_result({**result, 'error': 'SENTINEL'}, 'a' * 32))
        with self.assertRaises(ValueError):
            call('tools/call', {'name': 'probe_read', 'arguments': {}})
        self.assertEqual(records, ['initialize', 'list', 'call'])

    def test_call_observation_has_only_allowlisted_category_and_shape(self):
        message = 'MCP tool call requires approval, but approval policy is never'
        self.assertEqual(driver.call_observation({'status': 'failed',
                         'error': {'message': message}})['errorCategory'],
                         'approval_required_never')
        for error in [message + ' SENTINEL', {'message': 'SENTINEL'}, 9]:
            value = driver.call_observation({'status': 'SENTINEL', 'error': error,
                                            'result': {'secret': 'SENTINEL'}})
            self.assertEqual(value, {'status': 'other', 'errorCategory': 'other',
                                    'errorPresent': True, 'resultPresent': True})
            self.assertNotIn('SENTINEL', json.dumps(value))
        self.assertEqual(driver.call_observation({'status': 'completed', 'result': {}}),
                         {'status': 'completed', 'errorCategory': 'none',
                          'errorPresent': False, 'resultPresent': True})

    def test_unbound_process_identity_never_becomes_cleanup_handle(self):
        class Native:
            closed = False
            def open(self, pid): return 11
            def identity(self, handle):
                return {'pid': 5, 'started': '15', 'parent': 7, 'sha256': 'hash',
                        'image': sys.executable}
            def close(self, handle): self.closed = True
        for field, value in [('pid', 8), ('started', '99'), ('sha256', 'foreign')]:
            native = Native()
            header = {'fixtureVersion': 1, 'stage': 'start', 'pid': 5,
                      'started': '15', 'sha256': 'hash', 'parent': 7}
            header[field] = value
            with self.assertRaises(ValueError):
                driver.bind_child(native, header, {'pid': 7, 'started': '10'}, 'hash')
            self.assertTrue(native.closed)

    def test_evidence_create_new_bound_and_missing_terminal(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.jsonl'
            records = Records(path)
            with self.assertRaises(FileExistsError):
                Records(path)
            for _ in range(12):
                records.add('synthetic')
            with self.assertRaises(ValueError):
                records.add('synthetic')
            records.file.close()
            self.assertLessEqual(path.stat().st_size, 12 * 512)
            self.assertFalse(driver.complete_records(driver.read_records(Path(directory))))
            before = path.read_bytes()
            with self.assertRaises(FileExistsError):
                driver.write_new(path, {'fabricated': True})
            self.assertEqual(before, path.read_bytes())
            with path.open('ab') as stream:
                stream.write(b'{"partial":')
            with self.assertRaises(ValueError):
                driver.read_records(Path(directory), final=True)

    def test_cleanup_failure_does_not_skip_other_owned_handles(self):
        class Process:
            def __init__(self, handle): self._handle = handle
            def wait(self, timeout): raise TimeoutError()
        class Native:
            attempted = []
            def exited(self, handle): return False
            def terminate(self, handle):
                self.attempted.append(handle)
                raise ValueError('synthetic cleanup failure')
            def close(self, handle): self.attempted.append(-handle)
        native = Native()
        result = {'forced': False, 'cleanupFailed': False}
        driver.cleanup(native, [Process(1), Process(2)], 3, result)
        self.assertEqual(native.attempted, [2, 1, 3, -3])
        self.assertTrue(result['forced'])
        self.assertTrue(result['cleanupFailed'])
        self.assertEqual(result['status'], 'ABORTED')


if __name__ == '__main__':
    unittest.main()
