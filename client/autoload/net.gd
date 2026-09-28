extends Node
## Phase 3 stub: the WebSocket link to the Town Hall (ws://127.0.0.1:<port>/ws, PROTOCOL.md).
## Planned: WebSocketPeer with a 4 MiB buffer, awaitable requests with string request_ids,
## reconnect with backoff, and a get_state snapshot when an event seq gap is seen.

signal connection_changed(online: bool)
## Town Hall events ({v, type, seq, payload, ...}) once connected.
signal event_received(event: Dictionary)

var online: bool = false


func is_online() -> bool:
	return online
