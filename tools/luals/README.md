# Static check with Lua Language Server

`check.sh` runs [Lua Language Server](https://github.com/LuaLS/lua-language-server)
in check mode over program folders, with the ComputerCraft 1.63 API as the
only API available. It reports:

- functions that do not exist in ComputerCraft 1.63, such as `turtle.inspect`
  or `os.getenv` (`undefined-field`)
- names used but never defined (`undefined-global`)
- values that may be nil where a table is indexed (`need-check-nil`)

## Running it

Download a Lua Language Server release for your system from
https://github.com/LuaLS/lua-language-server/releases, unpack it, then:

```
LUALS=/path/to/lua-language-server/bin/lua-language-server bash tools/luals/check.sh . cairn
```

Each argument is a folder of programs. Files without an extension are checked
as Lua. A guarded call such as `if turtle.inspect then` is still listed,
because the checker cannot tell it is guarded.

## The API definitions

`library/cc163.lua` lists every function ComputerCraft 1.63 provides. It was
built by `gen_cc163.lua` from the ROM in the ComputerCraft jar plus the Java
API method names read from the jar's classes. To rebuild it after extracting
the ROM with `sim/fetch_rom.sh`:

```
luajit tools/luals/gen_cc163.lua sim/ccrom tools/luals/library/cc163.lua
```
