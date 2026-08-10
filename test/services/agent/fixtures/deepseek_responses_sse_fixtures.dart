const textDeltaAndCompletedSse = r'''
event: response.output_item.done
data: {"type":"response.output_item.done","output_index":0,"item":{"id":"reasoning-text-1","type":"reasoning","content":[{"type":"reasoning_text","text":"PRIVATE_REASONING_MARKER"}]}}

event: response.reasoning_summary_text.delta
data: {"type":"response.reasoning_summary_text.delta","delta":"PRIVATE_REASONING_MARKER"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"visible "}

event: response.thinking.delta
data: {"type":"response.thinking.delta","delta":"PRIVATE_THINKING_MARKER"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"answer"}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp-text-1"}}

''';

const functionAndWebSse = r'''
event: response.output_item.done
data: {"type":"response.output_item.done","output_index":0,"item":{"id":"reasoning-tool-1","type":"reasoning","content":[{"type":"reasoning_text","text":"PRIVATE_REASONING_MARKER"}]}}

event: response.output_item.added
data: {"type":"response.output_item.added","output_index":1,"item":{"id":"item-call-1","type":"function_call","call_id":"call-1","name":"search_questions","arguments":""}}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","item_id":"item-call-1","output_index":1,"delta":"{\"query\":"}

event: response.function_call_arguments.delta
data: {"type":"response.function_call_arguments.delta","item_id":"item-call-1","output_index":1,"delta":"\"fixture\"}"}

event: response.function_call_arguments.done
data: {"type":"response.function_call_arguments.done","item_id":"item-call-1","output_index":1,"arguments":"{\"query\":\"fixture\"}"}

event: response.output_item.done
data: {"type":"response.output_item.done","output_index":1,"item":{"id":"item-call-1","type":"function_call","call_id":"call-1","name":"search_questions","arguments":"{\"query\":\"fixture\"}"}}

event: response.output_item.added
data: {"type":"response.output_item.added","output_index":2,"item":{"id":"web-1","type":"web_search_call","status":"in_progress"}}

event: response.web_search_call.searching
data: {"type":"response.web_search_call.searching","item_id":"web-1"}

event: response.web_search_call.completed
data: {"type":"response.web_search_call.completed","item_id":"web-1"}

event: response.output_item.done
data: {"type":"response.output_item.done","output_index":2,"item":{"id":"web-1","type":"web_search_call","status":"completed"}}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp-tool-1"}}

''';

const incompleteSse = r'''
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"partial answer"}

event: response.incomplete
data: {"type":"response.incomplete","response":{"id":"resp-incomplete-1","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}

''';

const providerFailureSse = r'''
event: response.failed
data: {"type":"response.failed","response":{"error":{"code":"server_error","message":"PRIVATE_PROVIDER_BODY_MARKER"}}}

''';

const providerErrorSse = r'''
event: error
data: {"type":"error","error":{"code":"rate_limit_exceeded","message":"PRIVATE_RATE_BODY_MARKER"}}

''';

const malformedSse = r'''
event: response.output_text.delta
data: {not-json:PRIVATE_MALFORMED_BODY_MARKER}

''';
