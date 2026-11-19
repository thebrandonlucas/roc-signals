import Engine
import Web

## SPIKE: a minimal native widget vocabulary for the experimental desktop
## host (`main-native.roc`, `host/native_mac.zig`). Each widget is an
## ordinary engine element in the `urn:roc-signals:native` namespace, so the
## unchanged engine builds, identifies, updates and disposes it, and the
## native host maps the closed set of local names below to platform views.
## Nothing here is part of the web platform's vocabulary.
Native := [].{

	## The namespace every native widget is created in.
	namespace : Str
	namespace = "urn:roc-signals:native"

	## A vertical stack of widgets.
	column : List(Engine.Elem(ctx)) -> Engine.Elem(ctx)
	column = |kids| Engine.element(Native.widget("column"), [], kids)

	## A horizontal stack of widgets.
	row : List(Engine.Elem(ctx)) -> Engine.Elem(ctx)
	row = |kids| Engine.element(Native.widget("row"), [], kids)

	## A static, non-editable line of text.
	label : Str -> Engine.Elem(ctx)
	label = |text| Engine.element(Native.widget("label"), [], [Engine.text(text)])

	## A line of text that follows a signal; the host's view is written only
	## when the text changes.
	label_s : Engine.Signal(ctx, Str) -> Engine.Elem(ctx)
	label_s = |text| Engine.element(Native.widget("label"), [], [Engine.text_s(text)])

	## A push button with a static title. Activating it delivers the native
	## `press` event, whose payload is empty, to `handler` as one turn.
	button : Str, Engine.Handler(ctx) -> Engine.Elem(ctx)
	button = |title, handler| Engine.element(Native.widget("button"), [Engine.on(Native.press, handler)], [Engine.text(title)])

	## A push button whose title follows a signal.
	button_s : Engine.Signal(ctx, Str), Engine.Handler(ctx) -> Engine.Elem(ctx)
	button_s = |title, handler| Engine.element(Native.widget("button"), [Engine.on(Native.press, handler)], [Engine.text_s(title)])

	## A single-line text entry. `value` is the text the app decides the
	## entry shows; each edit the user makes delivers the native `input`
	## event, whose payload is the entry's whole text, to `on_input` as one
	## turn. The host writes `value` into the entry only when it differs from
	## what the entry already shows, so writing back what the user typed
	## never disturbs the caret.
	field : Engine.Signal(ctx, Str), Engine.Handler(ctx) -> Engine.Elem(ctx)
	field = |value, on_input| Engine.element(Native.widget("field"), [Engine.attr_s(Native.value_attr, value), Engine.on(Native.input, on_input)], [])

	## The attribute that carries a field's text.
	value_attr : Web.AttrName
	value_attr = Web.AttrName.from_str("value") ?? crash "internal: value is a valid attribute name"

	## An edit of a native text entry.
	input : Web.EventType
	input = Web.EventType.from_str("input") ?? crash "internal: input is a valid event name"

	## Activation of a native control.
	press : Web.EventType
	press = Web.EventType.from_str("press") ?? crash "internal: press is a valid event name"

	## A widget's element name: its local name in the native namespace.
	widget : Str -> Web.Tag
	widget = |local| {
		tag = Web.Tag.from_str(local) ?? crash "internal: ${local} is a valid element name"
		tag.in_namespace({ namespace: Uri(Native.namespace) }) ?? crash "internal: ${local} is a valid native widget name"
	}
}
