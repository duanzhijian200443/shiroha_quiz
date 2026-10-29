import io
import json
import sys
import unittest
from controlled_response_loss import SelectedReply, pump


def request(key="C", name="propose_generated_questions", request_id=7):
    return {"jsonrpc": "2.0", "id": request_id, "method": "tools/call",
            "params": {"name": name, "arguments": {"submission": {"submissionKey": key}}}}


def reply(key="C", request_id=7):
    return {"jsonrpc": "2.0", "id": request_id, "result": {"structuredContent": {
        "profileVersion": 2, "error": None,
        "data": {"submissionKey": key, "publication": "STAGED", "formalCommit": "NOT_REPORTED"}}}}


class ControlledLossTests(unittest.TestCase):
    def test_only_exact_successful_publication_is_withheld_once(self):
        selected = SelectedReply("C")
        selected.observe(request())
        self.assertFalse(selected.withhold(reply("B")))
        self.assertFalse(selected.withhold(reply(request_id="7")))
        self.assertFalse(selected.withhold({"id": 7, "error": {"code": -1}}))
        self.assertTrue(selected.withhold(reply()))
        self.assertFalse(selected.withhold(reply()))

    def test_queries_and_other_keys_never_arm_loss(self):
        for packet in [request("A"), request(name="get_question_proposal")]:
            selected = SelectedReply("C")
            selected.observe(packet)
            self.assertFalse(selected.withhold(reply()))

    def test_original_child_eof_settles_and_selected_reply_never_reaches_client(self):
        # A real subprocess emits the matched response and exits only after its
        # original stdin reaches EOF. No Android/credential/network is used.
        program = ("import sys,json; r=json.loads(sys.stdin.buffer.readline()); "
                   f"print(json.dumps({reply()!r}),flush=True); "
                   "sys.stdin.buffer.read(); sys.exit(0)")
        source = io.BytesIO((json.dumps(request()) + "\n").encode())
        destination, evidence = io.BytesIO(), io.StringIO()
        result = pump([sys.executable, "-c", program], "C", evidence, source, destination)
        self.assertEqual(result, 0)
        self.assertEqual(destination.getvalue(), b"")
        records = [json.loads(line) for line in evidence.getvalue().splitlines()]
        self.assertEqual(records[0]["phase"], "publication_response_withheld")
        self.assertEqual(records[0]["selectedResponseBytesForwarded"], 0)
        self.assertEqual(records[-1]["exitCode"], 0)
        self.assertNotIn("submissionKey", evidence.getvalue())


if __name__ == "__main__":
    unittest.main()
