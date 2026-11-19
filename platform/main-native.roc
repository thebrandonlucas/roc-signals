## SPIKE: an experimental native desktop platform root over the same pure
## engine as `main.roc`. An app built against it runs as a desktop program:
## the native host owns the window, keeps the one
## opaque engine state between calls exactly as the Wasm host does, applies
## the command stream to platform views and routes their events back as
## turns. It offers only mount, turns and teardown: no workers, no spec
## runner and no hosted effects. Widgets come from `Native.roc`. On macOS
## the host draws AppKit views (`host/native_mac.zig`); on Linux, GTK 4
## widgets (`host/native_gtk.zig`), both over `host/native_runtime.zig`.
platform ""
	requires {
		[Store : st] for main : Engine.Program(st)
	}
	exposes [Engine, Native, Web]
	packages { cbor: "https://github.com/lukewilliamboswell/roc-cbor/releases/download/0.6.3/J3xX4n61WoMZKK3tdWTnZBdKaVbi8SvXvmtC5i3qDAER.tar.zst", parser: "https://github.com/lukewilliamboswell/roc-parser/releases/download/6.0.0-rc.5/822J9njyNR1vgyX1KG4ck496dBx3AnLfvn2zHXn15Ksw.tar.zst", unicode: "https://github.com/roc-lang/unicode/releases/download/4.3.3/AJfFMmhvmbgn7THAF1E1sofC3dZaVWPFmVV7GH8Bc7k7.tar.zst" }
	provides {
		"roc_engine_drop": drop_for_host,
		"roc_engine_event": event_for_host,
		"roc_engine_init": init_for_host,
		"roc_engine_keys": keys_for_host,
		"roc_engine_version": version_for_host,
	}
	targets: {
		inputs_dir: "targets-native/",
		arm64mac: { inputs: ["libhost.a", app] },
		x64mac: { inputs: ["libhost.a", app] },
		arm64glibc: { inputs: ["crt1.o", "libhost.a", app, "libc.so"] },
	}

import Core
import Engine
import Native
import ProtocolFacts
import Web

## One host call's result, as in `main.roc`.
Step : { cmds : List(U8), state : Handle, work : List(U8) }

## The one opaque engine state the host keeps between calls, as in
## `main.roc` (including the roc-lang/roc#12953 one-item `Iter` workaround).
Handle : Box({ store : Store, sites : Box(Iter(Core.Sites(Store))) })

hold : Core.App(Store) -> Handle
hold = |engine| {
	(store, sites) = Core.split(engine)
	Box.box({
		store,
		sites: Box.box(
			Iter.custom(
				Some(sites),
				Ok(1),
				|seed|
					match seed {
						Some(state) => Ok((state, None))
						None => Err(NoMore)
					},
			),
		),
	})
}

release : Handle -> Core.App(Store)
release = |handle| {
	{ store, sites } = Box.unbox(handle)
	match Box.unbox(sites).next() {
		One({ item, rest: _ }) => Core.join(store, item)
		_ => crash "internal: the host passed an engine handle whose state was already taken"
	}
}

## The wire protocol version the engine speaks.
version_for_host : () -> U32
version_for_host = || Core.driver(main).version

## The program's declaration sections.
keys_for_host : () -> List(U8)
keys_for_host = || ProtocolFacts.append_declaration((Core.driver(main).keys)())

## Mount with the boot bytes (empty: every default).
init_for_host : List(U8) -> Step
init_for_host = |boot| {
	(state, cmds, work) = (Core.driver(main).init)(boot)
	{ cmds, state: hold(state), work }
}

## One turn for an event a native view raised.
event_for_host : Handle, List(U8), List(U8), U32, U32, List(U8) -> Step
event_for_host = |boxed, buf, wbuf, node, handler, payload| {
	(next, cmds, work) = (Core.driver(main).event)(release(boxed), buf, wbuf, node, handler, payload)
	{ cmds, state: hold(next), work }
}

## Teardown: the state and both buffers are released with the call.
drop_for_host : Handle, List(U8), List(U8) -> {}
drop_for_host = |_boxed, _buf, _wbuf| {}
