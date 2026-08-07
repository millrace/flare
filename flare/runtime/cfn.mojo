# Storable C-function proxies for flare's dlopen'd helper library.
#
# Mojo 1.0 changed `OwnedDLHandle.get_function` to return an origin-bound
# `_DLCallable` that borrows the handle, which cannot be stored in a struct
# next to the handle it borrows, and takes only the return type (arguments
# are forwarded per call over the C ABI). Flare resolves its shim symbols
# once and stores/calls them across the codebase, so this module provides
# the storable equivalent: `_cfn[Ret](lib, "name")` resolves a symbol and
# wraps it as a `_CFn[Ret]` value that forwards calls over the C ABI.
#
# Safety: every caller owns (or borrows) the `OwnedDLHandle` for at least as
# long as the returned proxy — flare's handles live for the process lifetime
# (module-level singletons) or in the same struct that stores the proxy.
# A missing symbol aborts: the symbols come from flare's own shipped shim
# library, so absence is a packaging bug, not a runtime condition (this
# matches the pre-1.0 `get_function` behavior).

from std.ffi import OwnedDLHandle
from std.os import abort


@fieldwise_init
struct _CFn[R: RegisterPassable](TrivialRegisterPassable):
    """A stored C-function proxy resolved via `_cfn`."""

    var _opaque: Pointer[NoneType, MutUntrackedOrigin]

    @always_inline
    def __call__[*T: AnyType](self, *args: *T) -> Self.R:
        # Same reinterpret dance as stdlib `_DLCallable.__call__`: the opaque
        # field's address is viewed as a function-pointer slot and loaded.
        var typed_fn = Pointer(to=self._opaque).unsafe_bitcast[
            def(* a: * T) thin abi("C") -> Self.R
        ]()[]
        return typed_fn(*args)


def _cfn[R: RegisterPassable](lib: OwnedDLHandle, name: StringSlice) -> _CFn[R]:
    """Resolves `name` in `lib` and wraps it as a storable `_CFn` proxy."""
    var sym = lib.get_symbol[NoneType](name)
    if not sym:
        abort(String("flare: symbol not found: ", name))
    return _CFn[R](
        sym.unsafe_value()
        .unsafe_mut_cast[True]()
        .unsafe_origin_cast[MutUntrackedOrigin]()
    )
