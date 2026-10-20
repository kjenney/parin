# Vendored Files

- `raylib`: v5.5 (https://github.com/raysan5/raylib)
    - `linux_x86_64/libraylib.a`: rebuilt from the 5.5 source with one backported patch from
      raylib master — `InitWindow` now checks the result of `InitPlatform()` and bails out
      early. Without it, a failed window creation (e.g. no display when running headless)
      segfaults on the first OpenGL call.

They should use VS2019 (16.x) for Windows.
