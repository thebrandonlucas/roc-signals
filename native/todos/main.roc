app [main] { pf: platform "../../platform/main-native.roc" }

import pf.Engine exposing [Elem, In, Root, Row, RowRef, State]
import pf.Native

## SPIKE: a native to-do list. One local state holds the draft and the
## items; `each` keeps one keyed row per item, so removing an item
## disposes exactly its row and adding one creates exactly one.
main : Engine.Program
main = Engine.program_startup({}, Engine.entries({ fallback: Some("/") }, [{ path: "/", route: 0.U8 }]), |_route| Engine.state({ draft: "", items: [], next: 0 }, view))

Item : { id : Str, title : Str }

Todos : { draft : Str, items : List(Item), next : U64 }

Ctx : In(Root, Todos)

view : State(Ctx, Todos) -> Elem(Ctx)
view = |todos|
	Native.column(
		[
			Native.label("To do"),
			Native.row(
				[
					Native.field(todos.signal().map(|t| t.draft), todos.set_value(|t, text| { ..t, draft: text })),
					Native.button("Add", todos.update(add)),
				],
			),
			Engine.each(todos.signal().map(|t| t.items), |item| item.id, |r| item_row(todos, r)),
			Native.label_s(todos.signal().map(|t| summary(t.items.len()))),
		],
	)

item_row : State(Ctx, Todos), RowRef(Ctx, Item) -> Elem(Row(Ctx, Item))
item_row = |todos, r|
	Native.row(
		[
			Native.label_s(r.field(|item| item.title)),
			Native.button_s(r.field(|item| "Remove ${item.title}"), todos.lift_row().update_by(r.key(), |t, id| { ..t, items: t.items.keep_if(|item| item.id != id) })),
		],
	)

## A blank draft adds nothing; any other adds one item and clears the draft.
add : Todos -> Todos
add = |t| {
	title = t.draft.trim()
	if title.is_empty() t else { draft: "", items: t.items.append({ id: "todo-${t.next.to_str()}", title }), next: t.next + 1 }
}

summary : U64 -> Str
summary = |n| if n == 1 "1 item" else "${n.to_str()} items"

expect add({ draft: "  milk ", items: [], next: 0 }) == { draft: "", items: [{ id: "todo-0", title: "milk" }], next: 1 }
expect add({ draft: "   ", items: [], next: 3 }) == { draft: "   ", items: [], next: 3 }
