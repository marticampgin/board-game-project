extends AcceptDialog
## Native development lobby. ENet networking remains in NetworkSession.
signal host_requested(port: int)
signal join_requested(address: String, port: int, token: String)
signal start_requested
signal leave_requested

var address: LineEdit
var port: SpinBox
var token: LineEdit
var status: Label
var seats: Label
var host_button: Button
var join_button: Button
var start_button: Button
var leave_button: Button

func _ready() -> void:
	title = "Multiplayer · development lobby"
	ok_button_text = "Close"
	var stack := VBoxContainer.new()
	stack.custom_minimum_size = Vector2(480, 360)
	stack.add_theme_constant_override("separation", 12)
	add_child(stack)
	var introduction := Label.new()
	introduction.text = "Host a native game or join its address.\nUnclaimed seats are bots; reconnect restores your seat."
	stack.add_child(introduction)
	var row := HBoxContainer.new()
	stack.add_child(row)
	address = LineEdit.new()
	address.text = "127.0.0.1"
	address.placeholder_text = "Host address"
	address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(address)
	port = SpinBox.new()
	port.min_value = 1024
	port.max_value = 65535
	port.value = 24567
	row.add_child(port)
	token = LineEdit.new()
	token.placeholder_text = "Reconnect token (leave empty for a new seat)"
	token.secret = true
	token.tooltip_text = "A reconnect token controls your reserved seat. Keep it private."
	stack.add_child(token)
	var connect_row := HBoxContainer.new()
	stack.add_child(connect_row)
	host_button = _button("Host game", func() -> void: host_requested.emit(int(port.value)))
	connect_row.add_child(host_button)
	join_button = _button("Join / reconnect", func() -> void: join_requested.emit(address.text.strip_edges(), int(port.value), token.text))
	connect_row.add_child(join_button)
	connect_row.add_child(_button("Copy my token", func() -> void: DisplayServer.clipboard_set(token.text)))
	status = Label.new()
	status.text = "Local ENet proof · direct address · no matchmaking service"
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(status)
	seats = Label.new()
	seats.text = "P1 — host\nP2 — available\nP3 — available\nP4 — available"
	stack.add_child(seats)
	var controls := HBoxContainer.new()
	stack.add_child(controls)
	start_button = _button("Start match", func() -> void: start_requested.emit())
	start_button.disabled = true
	controls.add_child(start_button)
	leave_button = _button("Leave session", func() -> void: leave_requested.emit())
	leave_button.disabled = true
	controls.add_child(leave_button)
	if OS.has_feature("web"):
		host_button.disabled = true
		join_button.disabled = true
		status.text = "ENet multiplayer runs in the native Windows build.\nThe browser version supports local and solo play."

func _button(caption: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(callback)
	return button

func update_lobby(lobby: Dictionary, host: bool, own_seat: String, reconnect: String) -> void:
	var lines: PackedStringArray = []
	for seat: Dictionary in lobby.get("seats", []):
		lines.append("%s · %s%s" % [String(seat.player_id).to_upper(), String(seat.kind).capitalize(), " · you" if seat.player_id == own_seat else ""])
	seats.text = "\n".join(lines)
	start_button.disabled = not host or lobby.get("started", false)
	leave_button.disabled = false
	if not reconnect.is_empty(): token.text = reconnect
	status.text = "%s · %s · %s" % ["Hosting" if host else "Connected", own_seat.to_upper(), "Match in progress" if lobby.get("started", false) else "Waiting for host to start"]

func show_error(message: String) -> void:
	status.text = message
	popup_centered()
