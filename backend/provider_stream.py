"""Bounded OpenAI-compatible SSE decoding and coach-answer projection.

Protocol: https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events
Only the coach.answer JSON string may be projected. Tool arguments, reasoning,
credentials and surrounding JSON never enter the public text channel. Text is
provisional until the normal full-result validator commits the final snapshot.
"""
import json
import time

MAX_BYTES = 2_000_000
_DECODER = json.JSONDecoder()


def answer_prefix(raw, path=('coach', 'answer')):
    """Walk actual JSON object keys; never regex-match a quoted nested payload."""
    pos = 0
    while pos < len(raw) and raw[pos].isspace():
        pos += 1
    if pos >= len(raw) or raw[pos] != '{':
        return None
    pos += 1
    seen = set()
    while True:
        while pos < len(raw) and raw[pos].isspace():
            pos += 1
        try:
            key, end = _DECODER.raw_decode(raw, pos)
        except ValueError:
            return None
        if not isinstance(key, str) or key in seen:
            return None
        seen.add(key)
        pos = end
        while pos < len(raw) and raw[pos].isspace():
            pos += 1
        if pos >= len(raw) or raw[pos] != ':':
            return None
        pos += 1
        while pos < len(raw) and raw[pos].isspace():
            pos += 1
        if key == path[0]:
            if len(path) > 1:
                return answer_prefix(raw[pos:], path[1:])
            if pos >= len(raw) or raw[pos] != '"':
                return None
            start = pos
            pos += 1
            escaped = False
            while pos < len(raw):
                char = raw[pos]
                if char == '"' and not escaped:
                    try:
                        return json.loads(raw[start:pos + 1])
                    except ValueError:
                        return None
                escaped = char == '\\' and not escaped
                pos += 1
            # Trim only incomplete escape sequences at the end, never invent text.
            partial = raw[start:]
            for trim in range(min(7, len(partial))):
                candidate = partial if trim == 0 else partial[:-trim]
                try:
                    value = json.loads(candidate + '"')
                    # A split UTF-16 surrogate escape is not displayable until paired.
                    if value and 0xD800 <= ord(value[-1]) <= 0xDFFF:
                        value = value[:-1]
                    return value
                except ValueError:
                    continue
            return None
        try:
            _, pos = _DECODER.raw_decode(raw, pos)
        except ValueError:
            return None
        while pos < len(raw) and raw[pos].isspace():
            pos += 1
        if pos >= len(raw) or raw[pos] != ',':
            return None
        pos += 1


def read_chat_stream(response, deadline, on_prefix):
    fragments, pending, size = [], [], 0
    finish, usage, done = None, {}, False
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError()
        sock = getattr(getattr(getattr(response, 'fp', None), 'raw', None), '_sock', None)
        if sock:
            sock.settimeout(remaining)
        line = response.readline(262145)
        if not line:
            break
        size += len(line)
        if size > MAX_BYTES or len(line) > 262144:
            raise ValueError('stream exceeds bounds')
        line = line.decode('utf-8').rstrip('\r\n')
        if line:
            if line.startswith('data:'):
                pending.append(line[5:].lstrip(' '))
            continue
        if not pending:
            continue
        payload = '\n'.join(pending)
        pending = []
        if payload == '[DONE]':
            done = True
            break
        frame = json.loads(payload)
        if not isinstance(frame, dict) or frame.get('error'):
            raise ValueError('invalid stream frame')
        if isinstance(frame.get('usage'), dict):
            usage = frame['usage']
        choices = frame.get('choices', [])
        if not isinstance(choices, list):
            raise ValueError('invalid stream choices')
        for choice in choices:
            if choice.get('index', 0) != 0:
                continue
            delta = choice.get('delta') or {}
            if not isinstance(delta, dict) or delta.get('refusal') or delta.get('tool_calls'):
                raise ValueError('refused or unexpected tool stream')
            piece = delta.get('content')
            if piece is not None:
                if not isinstance(piece, str):
                    raise ValueError('invalid text delta')
                fragments.append(piece)
                prefix = answer_prefix(''.join(fragments))
                if prefix is not None:
                    on_prefix(prefix)
            if choice.get('finish_reason') is not None:
                finish = choice['finish_reason']
    if not done or finish != 'stop' or pending:
        raise ValueError('incomplete provider stream')
    return {'choices': [{'message': {'content': ''.join(fragments)}, 'finish_reason': finish}], 'usage': usage}
