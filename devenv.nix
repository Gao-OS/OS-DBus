{ pkgs, lib, ... }:

{
  # Elixir / Erlang
  languages.elixir = {
    enable = true;
    package = pkgs.elixir_1_17;
  };

  languages.erlang = {
    enable = true;
    package = pkgs.erlang_27;
  };

  # Node.js for Phoenix assets
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_22;
  };

  # System packages for D-Bus interop testing
  packages = with pkgs; [
    dbus          # dbus-send, dbus-monitor, dbus-daemon
    systemdMinimal # busctl
    glib          # gdbus
    glib.dev      # GLib/GIO headers for C fixture compilation
    pkg-config    # for fixture compilation
    gcc           # C compiler for fixture
    socat         # unix socket debugging
    inotify-tools # Phoenix live reload
  ];

  # Environment variables
  env = {
    ERL_AFLAGS = "-kernel shell_history enabled";
    MIX_ENV = "dev";
  };

  # Process management
  processes = {
    phoenix.exec = "mix phx.server";
  };

  # Scripts
  scripts = {
    test-all.exec = "mix test";
    test-compliance.exec = "mix test --only compliance";
    test-interop.exec = "mix test --only interop";
    bus-start.exec = "mix run --no-halt";
    fmt.exec = "mix format";
    lint.exec = "mix credo --strict";
  };

  enterShell = ''
    echo "🚌 gao_dbus development environment"
    echo "  mix test       — run all tests"
    echo "  bus-start      — start the bus daemon"
    echo "  mix phx.server — start web monitor"
    echo ""
    mix deps.get --quiet 2>/dev/null || true
  '';
}
