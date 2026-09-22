# Why this file exists. A Gearflow worker builds this repo in a slot on a machine that has
# nix and no mise, so the toolchain pin has to be readable by nix as well. This file and
# `elixir/mise.toml` name the SAME pair — Erlang 28 and Elixir 1.19 — and they must move
# together: a slot that compiles under one and not the other is a red build nobody can
# reproduce.
#
# There is no Postgres here and there must not be. Symphony stores its history in SQLite,
# in a file `mix` creates on demand, so a slot of this repo allocates no database port and
# starts no service. The whole environment is a compiler.
{ pkgs, ... }:

{
  # The slot's `.env` is rendered by the provisioner (or copied on a laptop), and Symphony
  # reads its Linear credentials from the environment. An absent or empty key is the
  # documented "that integration is off" state, which is what a build slot wants.
  dotenv.enable = true;

  packages = [
    pkgs.git
    # exqlite (through ecto_sqlite3) normally downloads a precompiled SQLite NIF. When it
    # cannot — a new architecture, or a machine that may not reach the release host —
    # elixir_make builds the NIF from source, and that path needs make.
    pkgs.gnumake
  ];

  # `erlang_28` + `elixir_1_19` are nixpkgs attribute names: nix pins the OTP major and the
  # Elixir major.minor, so the patch behind `elixir_1_19` moves with the nixpkgs revision in
  # `devenv.lock`. That is the same granularity gf_platform pins at, and mix.exs asks only
  # for `~> 1.19`.
  languages.elixir = {
    enable = true;
    package = pkgs.beam.packages.erlang_28.elixir_1_19;
  };
}
