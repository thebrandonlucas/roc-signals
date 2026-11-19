app [main] { pf: platform "../../platform/main-native.roc" }

import pf.Engine exposing [Elem, In, Root, State]
import pf.Native

## SPIKE: the smallest native app: one piece of local state, a label that
## follows it and two buttons that change it, in a native window.
main : Engine.Program
main = Engine.program_startup({}, Engine.entries({ fallback: Some("/") }, [{ path: "/", route: 0.U8 }]), |_route| Engine.state(0, view))

view : State(In(Root, I64), I64) -> Elem(In(Root, I64))
view = |count|
	Native.column(
		[
			Native.label("Roc Signals, natively"),
			Native.row(
				[
					Native.button("-", count.update(|n| n - 1)),
					Native.label_s(count.signal().map(|n| "Count: ${n.to_str()}")),
					Native.button("+", count.update(|n| n + 1)),
				],
			),
		],
	)
